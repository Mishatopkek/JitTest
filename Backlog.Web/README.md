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
| `/sizes` | Distribution of what's left by length, plus the short / medium / long buckets, grouped and filterable |
| `/add` | Add a game. The name box searches your collection by `contains` as you type |

### `/sizes`

The chart at the top counts the startable pool **hour by hour**: x is length, y is
how many games are that long, one marker per hour up to 60. It reads
`custom.v_game_length_bands`, so the band edges live in that view and never in C#.

**Every plotted band is exactly one hour wide**, which is what makes the chart
honest — a band twice as wide collects twice the games at the same density, so
unequal widths make bin width read as signal. An earlier version had bands widening
to the right and showed a peak at `20–30h` that does not exist.

At this resolution the curve is spiky and touches zero in about a dozen places.
That is the true shape, not noise in the drawing: an empty point means no game is
that long.

**The open-ended `60+` band is deliberately left off the chart.** It is 658 hours
wide against neighbours of one, so it collects ~20 games where the tallest real
hour holds 9 — a spike caused by its width, not by the data, and tall enough to
squash everything else. The caption names its count and the table lists it, so
nothing is hidden, only moved. Bands are capped at 60 because past there the pool
runs 0–1 games per hour; extending to 100 would add forty points, forty-three of
them empty.

Axis ticks name **every fifth hour**; the rest are blank strings. Sixty labels
overprint into a smear, and MudBlazor still spaces the points evenly — the blanks
remove text, never a reading.

`YAxisTicks = 2` matters: left alone MudBlazor picks an interval of 20 for a range
that only reaches 9, squeezing the curve into the bottom half of the plot.
`MaxNumYAxisTicks` on its own did not shift it.

The **table view** below carries all 61 bands including `60+`, so every value is
readable without hover.

Conventions it follows, and that any chart added here should:

- **One series, so one colour and no legend** — the heading names it. A mark is
  never shaded by its own value; its height already encodes that, and spending
  colour on it would say nothing new. These bands *are* an ordered scale, so a
  light-to-dark ramp would be defensible, but MudBlazor's `ChartPalette` indexes
  by series rather than by point, and per-point shading would mean hand-drawing
  the chart.
- **The colour is `var(--mud-palette-primary)`** handed to `ChartPalette`, which
  MudBlazor writes into the SVG — so the chart follows the theme and dark mode
  with nothing hardcoded and no second code path.
- **Straight segments, never a spline.** `InterpolationOption.Straight`, with
  `ClampToZero` behind it. A spline invents curvature between two bands and can
  bow below the baseline, which would draw a negative number of games.
- **`YAxisRequireZeroPoint`.** A count axis has to start at zero, or the hump
  around 20–30h reads as a cliff.
- **No number printed at each point.** Ten of them are noise. Hover gives the
  exact count, and "Show as a table" lists every value, so the tooltip is never
  the only way to read one.
- **Not hidden behind the hours toggle.** The chart names no game, so it cannot
  tell you how long any particular title is — it describes the collection, same as
  the bucket counts underneath it. Anything that names a game still obeys the flag.

Three MudBlazor specifics worth knowing before touching it: axis options are on
`LineChartOptions` (the base `ChartOptions` has only palette/legend/tooltips);
`XAxisTitle` renders *above* the plot where it reads as a second heading, hence
the plain caption under the chart instead; and `ChartSeries<T>.Data` takes a
`ChartData<T>`, not an array, with labels passed as `ChartLabels`.

MudBlazor draws a 5px hit circle over each 3px marker, so the hover target is
already larger than the mark. Note that **synthetic mouse events do not reliably
drive those tooltips** — the same limitation as its drag handling — so verify
hover with a real pointer.

### `/roll`

One track with two thumbs sets the minimum and maximum length, the tag chips
narrow it further, and the number beside the button is how many games currently
fit — recomputed as you drag.

**Or pick a size instead.** `short` / `medium` / `long` chips sit under the slider
and filter by the same `NTILE(3)` thirds the database uses, so they hit exactly the
rows `v_game_tiers` says they should. The two are **alternatives, not a filter you
narrow twice**: picking a size makes the thumbs irrelevant (the readout says
"medium third" rather than pretending the range is doing the work), and touching a
thumb clears the size. Honouring both would quietly intersect them, and "short AND
40–60h" is a contradiction that reads as a bug.

The tier is handed to `game_roll_range` **as a tier**, never converted into hour
bounds. `NTILE` boundaries move as you finish things and are rounded for display,
so a converted range would drift from the tier it claims to be. `Matches()` on the
page mirrors the same precedence, which is what keeps the live count equal to what
the roll actually draws from. Size chips carry their count with the current tags
applied, so a dead end reads `0` before you click it.

The thumbs move over **indexes into a fixed list of detents**
(`0,1,2,…,20,30,40,60,100,150,200,∞`) rather than over hours. The playable pool
runs from half an hour to 718, with a median around 18 and 90% under 60, so
evenly spaced hours would bury almost every game in the leftmost sliver of the
track. The top detent means "no maximum", which is the only way the 718h outlier
stays reachable at all — and dragging the *lower* thumb onto it is clamped one
stop short, because a minimum of infinity is meaningless.

Dragging one thumb past the other pushes it rather than refusing to move.

The control is `Components/Shared/RangeSlider.razor`, and it is the one piece of
hand-written app CSS here — see the note in `CLAUDE.md`. MudBlazor 9.8 has no
dual-thumb slider (`MudSlider` is single-value, `MudRangeInput` is two *text*
fields) and a native range input has one thumb by spec, so it is two range inputs
over a shared rail, their own tracks made transparent and pointer-transparent so
only the thumbs are grabbable. Consequences worth knowing:

- **Clicking the bare track does nothing** — the thumbs are the only hit targets.
  Grab a thumb, or focus one and use the arrow keys.
- When both thumbs sit on the same pixel, the one with room to travel gets the
  higher `z-index`, so a collapsed range can always be pulled back open. Without
  that rule the buried thumb is unreachable and the range sticks at zero width.
- Thumb and fill colours are `--mud-palette-*` variables, so the theme and dark
  mode carry over. Nothing in that file hardcodes a colour.

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
