# Backlog.Web

Blazor Server + [MudBlazor](https://mudblazor.com) UI over
`custom.game_completion_times`. Replaces the hand-written HTML/CSS/JS page that
used to live inside `JitTest`.

## Run it

```
dotnet user-secrets set "ConnectionStrings:Games" "Host=<host>;Port=<port>;Database=<database>;Username=<user>;Password=<password>" --project Backlog.Web
dotnet run --project Backlog.Web
```

The real values for this checkout are in `CLAUDE.local.md`, which is gitignored.

Then <http://localhost:5064>. The app refuses to start without the connection
string rather than booting into a half-working state.

`db/install.sql` must have been run at least once — every query here reads the
views and functions it defines.

## Pages

| Route | What |
|---|---|
| `/` | Play order: ranked list with drag-reorder, tag filter, finished toggles, tags, splitting |
| `/roll` | Roll for something to play within an hours range and a tag filter, with a live pool count |
| `/series` | Series editor: create, drag to order, add games, delete |
| `/sizes` | The short / medium / long buckets, grouped and filterable. New — the old UI had no equivalent |
| `/add` | Add a game. The name box searches your collection by `contains` as you type |

### `/roll`

Two sliders set a minimum and maximum length, the tag chips narrow it further,
and the number beside the button is how many games currently fit — recomputed as
you drag.

The sliders move over **indexes into a fixed list of detents**
(`0,1,2,…,20,30,40,60,100,150,200,∞`) rather than over hours. The playable pool
runs from half an hour to 718, with a median around 18 and 90% under 60, so
evenly spaced hours would bury almost every game in the leftmost sliver of the
track. The top detent means "no maximum", which is the only way the 718h outlier
stays reachable at all. MudBlazor 9 has no two-thumb range slider, hence two
sliders that shove each other instead of refusing to cross.

The count is computed **in memory**: `GetRollPoolAsync` loads `custom.v_roll_pool`
once when the page opens, and each slider move filters that list. The slider
fires on every pixel of a drag, so querying per event would be a round trip per
pixel. Tags are lowercased once at load for the same reason. Only the draw itself
goes to the database, through `custom.game_roll_range()`.

Each tag chip shows what the pool *would* be with that chip also on, so a
combination that narrows to nothing reads `0` before you click it.

The pool is playable units only, which is why the range is trustworthy: a game
queued behind an unfinished predecessor is not in it, so nothing has to be
redirected afterwards and the range you asked for holds for the game you are
handed. A split collection appears as its playable part, badged with what it is
inside.

### `/add`

The name field is a search box, not just an input: it queries
`custom.v_game` with `ILIKE '%name%'` on every keystroke (debounced) and lists
what already matches, so a game you entered years ago under a slightly different
title surfaces *before* you add it twice. An exact case-insensitive match raises
a warning banner.

Insert goes through `custom.game_add`, not a hand-written INSERT — that function
knows `hours_average` is a generated column (naming it raises), creates new tags
and series on the fly, and enforces that series and position are given together.

The three hour figures are required because they are `NOT NULL` on the table.
The average is never entered; Postgres computes it.

## Where the logic lives

Almost nowhere here. `Backlog.Web/Data/BacklogRepository.cs` is thin SQL over
`custom.v_game`, `custom.v_unit`, `custom.v_roll_pool` and
`custom.v_game_tiers`; the blocking rules, the finished roll-up, the tier
boundaries and what counts as rollable are all computed in `db/install.sql`.

**Keep it that way.** If a query here starts re-deriving something a view
already computes, the two definitions will drift.

## Lengths are hidden by default

Seeing "2h" next to a title tells you what you are in for before you start it,
and that removes the point of rolling for something. Picking a size *bucket* is
a deliberate choice; the precise length inside that bucket should stay a
surprise.

So `UiState.ShowHours` is off by default and nothing prints an hours figure —
not the part rows, not the size cards, not the grid, not the game `/roll` hands
you. The timer icon in the app bar reveals them when you actually want the
number.

Hiding the column is not sufficient on its own: `/sizes` and `/roll`'s pool
listing sort by **name** while hidden, because a list ordered by length still
reads as a ranking of length even with the numbers stripped. They switch to
sorting by hours only once revealed.

The one thing that shows either way is `/roll`'s range readout ("3h – 4h"). That
is the bound *you* just dragged, not a fact about any game — echoing your own
input back gives nothing away. Narrowing the range to a single detent and rolling
does tell you roughly how long the result is, but that is the same deliberate
trade as picking a size bucket.

## Things that look like details but are not

**The whole app is interactive, set once in `App.razor`** on `<Routes>` and
`<HeadOutlet>`. Per-page `@rendermode` leaves the *layout* static, so the app bar
renders without handlers and the theme toggle silently does nothing.

**`MudDropContainer.Items` must be one stable list instance**, mutated in place.
Handing it a freshly built list on every render desynchronises the per-item
reorder bookkeeping and rows appear in a jumbled order. `Home.razor` keeps
`_shownRanked` for the page's lifetime and calls `Refresh()` after changing it.

**Reordering is disabled while filtered.** `MudItemDropInfo.IndexInZone` is an
index into the *rendered* list, so a filtered drop computes a wrong global order
— and the save sends the complete list, which would unrank everything hidden.
`AllowReorder` is bound to `!Filtering`, and `OnRankedDropped` refuses
independently, because `AllowReorder=false` does not stop the row being
draggable.

**While filtered, rows show their real `priority`**, not their visible index.

**Parts are always loaded before the split dialog opens.** The old UI cached
them only for expanded rows, so editing a collapsed split opened an empty editor
— which read as "no parts" and wiped the split. `GameRow.OnParametersSetAsync`
fetches them unconditionally.

**The theme follows the OS until you touch the toggle**, then stops. Without
that latch the system-dark-mode watcher pushes its value back and the toggle
appears dead.
