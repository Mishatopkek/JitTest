# db

Saved queries for `custom.game_completion_times`. The host and database this
points at are in `CLAUDE.local.md`, which is gitignored.

| File | What it is | How often you run it |
|---|---|---|
| `install.sql` | Extensions, index, views, functions | Once, then after every edit to it |
| `quick.sql` | The handful you actually run | Daily |
| `queries.sql` | One-liner per task, everything else | When you need the long tail |

## Setup

1. Open `install.sql` in Rider.
2. Toolbar dropdowns: the Postgres data source, and the backlog database.
3. Execute the whole file (green arrow, or `Ctrl+Enter` with nothing selected).
4. Open `queries.sql`, put the caret on a statement, `Ctrl+Enter`.

`install.sql` is idempotent — re-running it drops and recreates only the `v_game_*` views and `game_*` functions. It never touches table data.

## What replaced what

| Old console query | Now |
|---|---|
| `SELECT ... WHERE game_name ILIKE '%' \|\| 'a' \|\| '%'` | `custom.game_search('a')` |
| — (new) | `custom.v_game` / `custom.game_info('a')` — one row, everything about a game |
| `INSERT ... RETURNING *` | `custom.game_add('name', 1, 2, 3, '')` |
| Random Long / Medium / Short (3 near-identical CTEs) | `custom.game_random('long'\|'medium'\|'short'\|omitted)` |
| `ORDER BY hours_average DESC` | `custom.v_game_by_length` |
| `SELECT avg(hours_average)` | `custom.v_game_stats` (also count, min, max, backlog hours) |
| — (new) | `custom.v_game_tier_stats` — averages per length third |
| Normalized-name duplicate group-by | `custom.v_game_dupes` |
| `similarity(...) > 0.7` self-join | `custom.v_game_similar` |
| `CREATE EXTENSION pg_trgm` | `install.sql`, one-time |
| — (new) | `custom.game_tag_add` / `game_by_tag` — many tags per game |
| — (new) | `custom.series_order` — play order inside a series |

## Two behavior changes, on purpose

**Duplicate normalization was broken.** The original was:

```sql
LOWER(REGEXP_REPLACE(game_name, '[^a-z0-9]', '', 'g'))
```

`REGEXP_REPLACE` runs before `LOWER`, and regex character classes are case-sensitive — so every capital letter matched the negated class `[^a-z0-9]` and was deleted. `'Mass Effect'` normalized to `'asffect'`. `v_game_dupes` lowercases first, then strips.

**Tiering now skips `hours_average IS NULL`.** `NTILE` sorts NULLs last, so any game without a recorded length was being filed as "long". `v_game_tiers` excludes them, which means `game_random()` will never return one. To restore the old behavior, delete the `AND hours_average IS NOT NULL` line from `v_game_tiers` in `install.sql` and re-run it. `v_game_stats.missing_hours` tells you how many rows this affects.

## Play order

`priority` is a nullable `integer` on the table. `1` is next up, `2` after that. `NULL` means unranked — which is every row until you number it.

| Want | Call |
|---|---|
| What do I play next | `SELECT * FROM custom.v_game_next;` |
| The ranked list | `SELECT * FROM custom.v_game_priority;` |
| Not yet numbered | `SELECT * FROM custom.v_game_unranked;` |
| Set a number | `custom.game_prioritize('Yakuza 0', 1)` |
| Squeeze in at a spot | `custom.game_prioritize_at('Elden Ring', 2)` |
| Remove from ranking | `custom.game_unprioritize('Elden Ring')` |
| Close gaps and ties | `custom.game_renumber()` |

Name matching is case-insensitive: exact first, then substring. It **raises instead of guessing** when a name hits more than one game — `custom.game_id('The')` lists all 32 matches rather than silently ranking the wrong one.

**Priorities are not unique, on purpose.** A unique constraint would make "put this at 3" fail until you had renumbered everything below it by hand. Ties are legal; `game_prioritize_at` shifts rows down for you when you want insertion semantics, and `game_renumber()` compacts to a gapless `1..n` whenever you want it tidy.

## The whole card

`custom.v_game` is one row per game with everything on it. Anything you would
otherwise assemble by hand from three tables is already there.

| Column | |
|---|---|
| `priority` | position in your play order, `NULL` when unranked |
| `tags` | `text[]`, `{}` when untagged |
| `series`, `series_slot`, `series_total` | which series, and "#2 of 5" |
| `blocked_by` | the unfinished game standing in the way, else `NULL` |
| `playable` | unfinished and nothing ahead of it |
| `hours_average`, `finished`, `notes` | straight off the table |

```sql
SELECT * FROM custom.game_info('yakuza');            -- name search, same columns
SELECT * FROM custom.v_game WHERE tags @> ARRAY['VR'];
SELECT * FROM custom.v_game WHERE playable ORDER BY priority NULLS LAST;
```

`series_total` counts finished entries too — "#2 of 5" only means anything if
the 5 is the whole series.

`game_search()` was left alone rather than widened. It returns `SETOF` the
table, so it declares no column types and survives any change to the table;
`game_info()` has to name its columns, so it is a second function rather than a
breaking change to the first. `SELECT id, game_name, finished, notes FROM
custom.game_search('a')` still works exactly as before.

## Splitting: the games inside a game

Mass Effect Legendary Edition is one purchase and three games. Adding three
rows would be a lie about what you own. Keeping one row means you cannot finish
ME1 and have ME2 come up next.

So the collection stays **exactly one row** in `game_completion_times`, and the
games inside it live in `custom.game_part`.

```sql
SELECT * FROM custom.game_split('Mass Effect Legendary Edition',
                                'Mass Effect', 'Mass Effect 2', 'Mass Effect 3');
SELECT * FROM custom.part_finish('Mass Effect Legendary Edition', 'Mass Effect');
SELECT custom.game_unsplit('Mass Effect Legendary Edition');
```

### Units

A game with no parts is one **unit**. A game with N parts is N units and does
not appear as itself. `custom.v_game_unit` and `custom.v_unit` are that grain,
and blocking, rolling and tiering all run over it.

A unit is blocked by any earlier unfinished unit, where earlier means:

- inside the same collection, a lower `part_position` — so ME2 waits for ME1
  **even when the collection is in no series at all**; or
- inside the same series, a lower `(series_position, part_position)` — so the
  chain runs straight through collections and standalone purchases alike.

That second rule is what makes Andromeda work:

```sql
SELECT custom.series_order('Mass Effect',
                           'Mass Effect Legendary Edition', 'Mass Effect Andromeda');
```

gives the order ME1 → ME2 → ME3 → Andromeda, out of two owned rows.

The same shape handles Ace Attorney: each trilogy or collection you own is one
row split into its cases, and `series_order` puts the collections in whatever
sequence you want. Ghost Trick is by the same director but is not an Ace
Attorney game — leave it out of that chain.

### Consequences worth knowing

**Part hours are a guess.** A part with no `hours` of its own gets an even share
of the parent's — Legendary Edition's 109h becomes 3 × 36.33h. Set
`game_part.hours` when you know better.

**Tiering moved to units.** `v_game_tiers` and `v_game_tier_stats` now rank what
you sit down to play, so a split collection is three medium games rather than
one long one. It is also restricted to *playable* units, so a game you cannot
start yet no longer shifts the boundaries of a bucket you are choosing from.
Tier boundaries will have moved.

**A split game's `finished` is derived**, not stored — it is true when every
part is. `game_finish` and `part_finish` keep the stored flag in step so
anything reading the table directly still sees the truth, but the parts are the
source of truth.

**`part_finish` matches exact-first.** `'Mass Effect'` means part 1, not all
three parts whose names contain that text. An ambiguous substring raises and
lists the candidates.

**Finishing a ranked game freezes its priority** rather than clearing it. The
game leaves the drag list, so without that guard the next unrelated drag would
silently wipe the rank it had. Un-finish it and the rank comes back.

## Tags

A game has many tags and a tag has many games, so tags are two tables —
`custom.tag` and `custom.game_tag_link` — not a `text[]` column. The cost is a
join. The benefit is that `custom.tag_rename('handheld', 'Handheld')` fixes
every game at once, and a typo shows up as its own row in `v_tag_stats` instead
of hiding inside 176 arrays.

| Want | Call |
|---|---|
| Tag a game | `custom.game_tag_add('Yakuza 0', 'PC', 'long')` |
| Untag | `custom.game_tag_remove('Yakuza 0', 'long')` |
| Games with ALL of these | `custom.game_by_tag('PC', 'co-op')` |
| Games with ANY of these | `custom.game_by_any_tag('VR', 'Handheld')` |
| Everything, tags in one column | `SELECT * FROM custom.v_game_tags;` |
| Which tags exist, how big | `SELECT * FROM custom.v_tag_stats;` |
| Fix a tag everywhere | `custom.tag_rename('Handhled', 'Handheld')` |
| Drop tags nothing uses | `SELECT * FROM custom.tag_prune();` |

Matching is case-insensitive and the tables enforce it: a unique index on
`lower(tag_name)` means `pc` and `PC` cannot both exist. Whichever casing you
typed first is the one that sticks.

The tables are named `custom.tag` / `custom.game_tag_link` rather than
`custom.game_tag`, because a table also defines a composite type — and a table
named `game_tag` would make the expression `game_tag(x)` ambiguous between a
function call and field selection.

## Series

A game belongs to at most one series, so this is two columns on the existing
table — `series_id` and `series_position` — plus a `custom.series` lookup table
for the names.

| Want | Call |
|---|---|
| Record a series in order | `custom.series_order('Yakuza', 'Yakuza 0', 'Yakuza Kiwami', 'Yakuza 2')` |
| Place one game | `custom.game_series_set('Persona 5', 'Persona', 5)` |
| Remove one game | `custom.game_series_clear('Persona 5')` |
| The whole picture | `SELECT * FROM custom.v_game_series;` |
| What I may start now | `SELECT * FROM custom.v_game_playable;` |
| Why is X never offered | `SELECT * FROM custom.v_game_blocked;` |
| Ranking that fights series order | `SELECT * FROM custom.v_game_priority_conflicts;` |
| Series I have not recorded yet | `SELECT * FROM custom.v_game_series_candidates;` |

**`game_random()` now draws from `v_game_playable`**, which hides any game that
still has an unfinished predecessor in its series. That is the whole point: it
can no longer hand you the third Yakuza while the first two sit unplayed.
`v_game_next` is gated the same way.

### Two rolls: `game_roll` vs `game_random`

`custom.game_roll(size, tags)` **redirects**. It draws from every unfinished
game and, when the draw lands mid-series, hands you that series' first
unfinished entry instead. It returns both, so you can see what happened:

| Column | Meaning |
|---|---|
| `start_name` | what to actually play |
| `start_priority` | its position in your play order, `NULL` when unranked |
| `start_tags` | its tags |
| `series`, `series_slot`, `series_total` | where it sits in its chain, "#2 of 5" |
| `drawn_name` | what the dice said |
| `redirected` | true when those differ |

`custom.game_random(size, tags)` **excludes**. Mid-series games are never in the
pool at all, and it returns a plain table row.

Two consequences decide which you want:

1. **Weighting.** To `game_random`, a six-game series is one entry in the pool.
   To `game_roll` it is six, so long series come up six times as often. That is
   the honest answer if you think of a series as six games you still have to get
   through, and the wrong one if you think of it as one slot in a shortlist.

2. **The filters apply to the draw, not to the result.** Roll `'long'`, land on
   Yakuza 5, get sent to Yakuza 0 — which may well be a medium. Ask for
   `ARRAY['VR']` and the entry that matched VR is not necessarily the one you
   are told to start.

So: `game_roll` when the series matters more than the filter, `game_random` when
the filter has to hold for the game you actually play.

Neither can offer a game with no recorded hours — the tiering drops those.
`v_game_stats.missing_hours` counts them.

### A third roll: `game_roll_range`, by hours instead of bucket

`custom.game_roll_range(min, max, tags)` answers the question the three buckets
cannot: *"I have four hours tonight."* Three `NTILE` thirds only ever mean
"shortish / middling / longish", and because they are thirds of a pool that
shrinks as you finish things, "short" is not a stable promise about length.

```sql
SELECT * FROM custom.game_roll_range(2, 6);                     -- inclusive both ends
SELECT * FROM custom.game_roll_range(20, NULL);                 -- 20h and up
SELECT * FROM custom.game_roll_range(NULL, 4, ARRAY['Handheld']);
```

Either bound may be `NULL` for "open that side". That matters at the top: the
pool runs past 700 hours, so any literal upper stop on the `/roll` slider would
quietly exclude the longest game — the last detent sends `NULL` instead.

It returns one extra column over `game_roll`: `pool_size`, the number of units
that matched *before* the draw, so you can tell "1 of 30" from "1 of 1". When
nothing matches it returns **no rows at all** rather than an empty pick.

**It does not redirect, and does not need to.** It draws from `v_roll_pool`,
which is playable units only — and "playable" already excludes anything queued
behind an unfinished predecessor, so there is never a series head to be sent
back to. That is what makes the range trustworthy: unlike `game_roll`, the hours
and the tags hold for the game you are actually told to start.

`v_roll_pool` is the single definition of that pool. `v_game_tiers` is built on
top of it rather than restating its `WHERE` clause, so the buckets can never
bucket a different set of games than the roll draws from, and the live count on
`/roll` counts the same rows.

By the same token `game_roll`'s own redirect branch is, in practice,
unreachable — it joins `v_game_tiers`, which is also playable-only. It is left
in place rather than changed underneath existing callers.

Nothing else is gated. Tier boundaries in `v_game_tiers` and `v_game_tier_stats`
are still computed over the full unfinished backlog, so recording a series does
not silently move what counts as "short".

**To unblock a game you are never going to play the predecessor of, mark the
predecessor `finished`.** The gate looks at nothing else, and that is
deliberate — one flag, one meaning, no second "skipped" column to keep in sync.

Positions are not required to be dense or unique; only their relative order is
read. Numbering a six-game series 10, 20, 30 leaves room to slot in a prequel
later without renumbering. A tie means both entries unblock together, which is
the right answer for a bundle like "Soul Reaver 1 & 2 Remastered".

`series_id` and `series_position` are both-or-neither, enforced by a CHECK. The
foreign key is plain `NO ACTION` on purpose: `ON DELETE SET NULL` would clear
`series_id` and leave a stale position behind, violating that CHECK. Deleting a
series that still has games fails loudly instead — detach them first with
`game_series_clear()`.

**`hours_average` is a generated column** — `GENERATED ALWAYS AS (round((hours_main + hours_main_extra + hours_completionist) / 3.0, 2)) STORED`. Never name it in an INSERT; Postgres rejects that with `cannot insert a non-DEFAULT value into column "hours_average"`. `game_add` omits it.

**NocoDB does not track this table.** Its metadata tables share the database (`public.nc_models_v2`), but they only cover `Gifted Games`, `Game` and `GameChapter` in the "Getting Started" base. `custom.game_completion_times` is not modelled there, so nothing needs syncing — and the table will not appear in the NocoDB UI unless you add the `custom` schema as a data source yourself.

### The web UI

`Backlog.Web` — Blazor Server + MudBlazor. See `Backlog.Web/README.md`.

```
dotnet user-secrets set "ConnectionStrings:Games" "Host=<host>;Port=<port>;Database=<database>;Username=<user>;Password=<password>" --project Backlog.Web
dotnet run --project Backlog.Web
```

Then <http://localhost:5064>. Drag to reorder, tick to finish, chips to filter by
tag, plus a series editor, a size browser and `/roll`.

`JitTest` no longer has anything to do with games — it is back to being the two
endpoints it started as, demonstrating `volatile` under different memory models.
The old hand-written UI is parked in `archive/legacy-ui.html` and does not run.

The client always PUTs the **complete** ranked list. The server unranks anything absent from that array and renumbers everything present to `1..n` in one transaction, so the UI never needs a separate renumber call and priorities cannot drift into gaps.

Each row also shows its tags and its series slot. Hover a row and click `+tag`
to add one (the input autocompletes from tags you already use); click the `×` on
a chip to remove it. A row badged <code>after …</code> is blocked by an earlier
unfinished game in its series — you can still rank it, but `game_random()` will
skip it. The search box matches names, tags and series names.

A tag bar sits above the lists. Click chips to filter every list — ranked,
unranked and finished — by tag. Chips are **ANDed**, matching `game_by_tag()`
and `game_roll()`: picking `PC` and `co-op` means both, not either. Each chip
carries the count of what selecting it would leave, so a chip that narrows to
nothing says `0` before you click it. The text box filters by name, tag or
series on top of that.

**Dragging is off while a filter is on**, and the list says so. This is not
fussiness: `dragend` rebuilds the order from the rows present in the DOM, so
reordering a partial list would PUT only the visible ids and unrank everything
the filter was hiding. The rows are made non-draggable, and the save handler
refuses independently in case that flag is ever bypassed.

While filtered, the number on each row is the game's **real** priority, not its
position in the visible subset — otherwise games ranked 3, 7 and 10 would read
1, 2, 3.

Every row has a checkbox: tick to mark finished. On a split collection it sets
every part at once; click the title instead to expand the parts and tick them
one at a time. Finished games move to their own section at the bottom, where
unticking puts them back.

**split** opens an editor: one row per game inside the collection, in play
order. Drag the rows to reorder, `✕` to drop one, **+ add a game** or `Enter`
for a new row below the caret, `Backspace` on an empty row to delete it. A row
whose name matches a part you have already finished is badged **finished** — the
mark survives as long as the name does.

Clearing every row undoes the split, and asks first, naming how many parts and
how much progress that costs. Duplicate names are refused, because the
keep-progress match is by name.

The editor always fetches the current parts before opening, so it is never blank
for a game that has them. It used to read from a cache filled only for
*expanded* rows — editing a collapsed split showed an empty box, and confirming
read as "no parts" and wiped the split.

#### The distribution chart on /sizes

`custom.v_game_length_bands` counts the startable pool into **equal 5-hour bands
from 0 to 60, plus one open-ended `60+`** — 13 points — and `/sizes` plots it as a
line with a marker per band. It answers what three equal thirds cannot: whether
what's left is mostly quick hits or mostly monsters. Thirds are always a third
each.

```sql
SELECT label, from_hours, to_hours, units, band_hours
FROM custom.v_game_length_bands ORDER BY ord;
```

**Why a band at all, rather than plotting raw hours?** Because a count needs an
interval. Hours are effectively continuous here: 193 units hold 150 distinct
values and 117 of those belong to a single game, so tallying at raw values gives
150 spikes of height 1. The band is what turns "one game at 18.33h" into "29 games
between 10h and 15h". (If you want the raw numbers with no bands at all, the chart
has to stop counting and plot each game's length instead — a different question.)

**Why equal width.** The first version used bands that widened to the right (2h at
the left, 20h at the right) so every band stayed populated. It lied. A 10-hour band
collects about twice the games of a 5-hour one at the same density, so `20–30h`
showed 38 and read as the peak of the collection — when at uniform width the real
peak is `5–10h` with 33. Bin width was being read as signal. With uniform steps a
taller point simply means more games, and the slope between two points is a real
rate.

Both numbers come from the data rather than taste:

- **5 hours**, because at that width every band holds at least one game and most
  hold four or more. At 2h steps four bands come out empty and the average drops to
  6 per band — that is sampling noise, not shape.
- **Cap at 60**, because past it the pool runs 0–2 games per 5h step: eight points
  all saying "nothing out here", two of them empty. The tail collapses into `60+`
  instead.

Two more things about the view:

- **Bands are half-open, `[lo, hi)`**, so nothing is double-counted and a game
  sitting exactly on a boundary lands in the upper band. `sum(units)` equals
  `count(*)` from `v_roll_pool` exactly.
- **The join is a LEFT JOIN** so an empty band still returns its row. Dropping it
  would close the gap on the chart's x-axis and misdescribe the distribution.

The `60+` point is the one that is *not* a fixed width, so the step up into it is a
change of band width and not a spike in the data. It is labelled `60+` for that
reason.

Built on `v_roll_pool`, like `v_game_tiers`, so the chart cannot describe a
different set of games than the roll draws from.

#### Roll tab

`/roll` is the range roll with a UI on it. One track with two thumbs sets the
bounds, the tag chips narrow it further (ANDed, as everywhere else), and the count
next to the button updates as you drag.

The thumbs run over **indexes into a fixed list of detents**
(`0,1,2,…,20,30,40,60,100,150,200,∞`), not over hours directly. The playable pool
has a median of ~18h, 90% of it under 60h, and one 718h outlier: an evenly spaced
hour scale would spend nine tenths of the track on games that are not there. The
last detent is "no maximum", which is how that outlier stays reachable; the lower
thumb is clamped one stop short of it, a minimum of infinity being meaningless.
Dragging one thumb past the other pushes it.

MudBlazor 9.8 has no dual-thumb slider, so the control is hand-built in
`Backlog.Web/Components/Shared/RangeSlider.razor` — two native range inputs over
a shared rail. One consequence: clicking the bare track does nothing, because the
inputs' own tracks are pointer-transparent and only the thumbs are hit targets.

The count is computed **in memory**, not by querying per drag event — the page
loads `v_roll_pool` once when it opens. Each tag chip shows what the pool would
be if that chip were also on, so a dead-end combination reads `0` before you
commit to it. Only the draw itself goes to the database, via
`game_roll_range()`.

The chosen range is always visible even when lengths are hidden: it is what you
just typed, not a fact about any game. The **drawn game's** hours stay behind the
timer toggle, and the pool listing sorts by name while hidden — same reasoning as
`/sizes`.

If the pool has emptied since the page loaded (something finished in another
tab), the roll comes back with nothing, says so, and reloads the pool rather than
showing a stale count.

#### Series tab

Series are editable in the UI too, on the **Series** tab. Type a name and press
Enter to create one (matching is case-insensitive, so typing `yakuza` when
`Yakuza` exists selects it rather than making a second series). Pick a series to
open it, search to add games, drag to set play order, `✕` to release a game.

The game picker searches **every** game, finished ones included — a series is a
chain of what you have played and what you have not, and marking an entry
finished is what unblocks the next one, so hiding finished games would hide the
thing you came for. Finished entries show struck through.

Adding a game already in another series moves it; the picker says so on the row
before you click.

`PUT /api/series/{id}/order` takes the complete membership in order, exactly
like `PUT /api/games/order`: absent games are detached, present ones renumbered
`1..n`. One endpoint covers add, reorder and remove.

Deleting a series releases its games rather than deleting them — the foreign key
is `NO ACTION`, so the endpoint detaches them in the same transaction as the
delete.

`custom.series_order()` is still the fastest path for a series you can type from
memory. The tab is better when you are hunting for which of 176 titles belong
together.

## Troubleshooting

**`ERROR: function similarity(character varying, character varying) does not exist`**

Not a type problem — `varchar` coerces to `text` for free. `similarity()` is not *visible*. Two causes:

- **Wrong database.** Extensions are per-database. The data source's jdbc-url points at `postgres`, but the table is in the backlog database. `CREATE EXTENSION pg_trgm` run against `postgres` leaves the backlog database without it. `install.sql` now aborts with a clear message if the database dropdown is wrong — it probes for `custom.game_completion_times` rather than comparing the database name.
- **`search_path`.** Rider derives it from the schema dropdown; picking `custom` drops `public` and hides the extension. Both scripts now `SET search_path TO custom, public;` at the top.

Diagnose with the block at the bottom of `queries.sql`. Expect the backlog database, a path containing `public`, and one `pg_trgm` row.

Rider will keep underlining `similarity`, `v_game_*`, and `game_*` as unresolved until you run `install.sql` and then right-click the data source → **Refresh**. Those are stale-cache warnings, not errors.

## Rider extras

**Live template for ad-hoc inserts.** Settings → Editor → Live Templates → SQL → `+`. Abbreviation `gci`, applicable in SQL:

```sql
INSERT INTO custom.game_completion_times
    (game_name, hours_main, hours_main_extra, hours_completionist, notes)
VALUES ('$NAME$', $MAIN$, $EXTRA$, $COMP$, '$NOTES$')
RETURNING *;
```

Type `gci` + Tab, then Tab between fields. Use this when you want the raw statement; use `game_add()` when you just want the row in.

**Bookmarks.** `F11` on a line in `queries.sql`, `Shift+F11` to jump to any of them.

**Why not the console.** `consoles/db/<uuid>/console.sql` lives in your Rider config directory, is not in git, and is per-machine. These files are in the repo.

## Notes

- Functions return `SETOF custom.game_completion_times`, so no column types are declared anywhere. Adding or retyping a table column will not break them. Pick columns at the call site: `SELECT id, game_name FROM custom.game_search('x');`
- `v_game_similar` is an O(n²) self-join. Fine for a personal list; if it gets slow, raise the `0.7` threshold or switch the `WHERE` to the indexed `%` operator (which uses `pg_trgm.similarity_threshold`, default `0.3`).
- The GIN trigram index also speeds up `ILIKE '%...%'`, which otherwise always scans the whole table.
