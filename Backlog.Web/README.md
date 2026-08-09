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

The chart at the top counts the startable pool **hour by hour, from 0 to 200**: x is
length, y is how many games sit within two hours either side of it. It reads
`custom.v_game_length_bands`, so the band edges and the smoothing live in that view
and never in C#.

**The curve is smoothed, not interpolated.** Each point is the view's centred
five-hour rolling sum of the raw one-hour counts. Raw counts at this resolution
average well under one game per hour and jump between 0 and 10 — sampling noise
rather than shape — so the window makes it legible without inventing anything:
every input is a real count, and the window is a fixed five hours wide everywhere,
so points are comparable right across the axis. Markers are off; with 200 points
they were a bead curtain, and the tooltip and table still carry the numbers.

**Every plotted band is exactly one hour wide, including through the sparse tail.**
Widening bands past 60h — the obvious way to fill the tail — would have made bin
width read as signal: a five-hour band collects five times the games of a one-hour
band at the same density, so the tail would rise merely for being coarser. An
earlier version of this chart had widening bands and showed a peak at `20–30h` that
does not exist. Smoothing is what buys legibility instead, so the width never
changes.

**200 hours is the cap and it costs exactly one unit** — the 718h entry, which is
itself an artefact of averaging in a 2000h completionist figure. It appears in the
table as `200+`, and the caption names it. The open-ended band is not plotted, since
it is 500+ hours wide and so not a comparable reading.

Axis ticks name **every twentieth hour**; the rest are blank strings. MudBlazor
still spaces the points evenly, so a blank removes text, never a reading.

`YAxisTicks` is what moves the y-axis — `MaxNumYAxisTicks` alone did nothing. Left
to itself MudBlazor picked an interval of 20 for a range reaching 9 and squeezed the
curve into the bottom half of the plot.

The **table view** lists every hour that actually holds a game (~67 of the 201
bands) with both the raw count and the smoothed figure plotted at it, plus the
`200+` row. Empty hours are omitted: their reading is "none", which the curve
already shows, and 201 mostly-blank rows are not a table anyone reads.

**Edge effect worth knowing:** the first and last two bands see a clipped window, so
they read slightly low. At the left that covers 0–2h, which holds a handful of games.

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
