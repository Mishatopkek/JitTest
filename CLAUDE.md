# CLAUDE.md

Two unrelated projects share this repo.

- **`Backlog.Web`** — Blazor Server + MudBlazor UI over a personal video-game
  backlog in Postgres. This is the project that gets worked on.
- **`JitTest`** — two endpoints (`/problem`, `/noproblem`) demonstrating that a
  non-`volatile` loop flag behaves differently under x86 and ARM memory models.
  Unrelated to games. **Do not add anything to it.**

## Commands

```bash
dotnet build                                    # whole solution
dotnet run --project Backlog.Web                # http://localhost:5064
dotnet run --project JitTest                    # http://localhost:5087
dotnet msbuild JitTest/JitTest.csproj -t:Compile # compile only, when the app holds a file lock
```

There are no tests. Verify by running the app and checking the database.

`JitTest` carries a pre-existing `NU1903` warning from `Microsoft.AspNetCore.OpenApi`.
It predates this work — do not "fix" it as a side quest.

## Database

PostgreSQL 16, schema `custom`. **Host, port, database and user are in
`CLAUDE.local.md`, which is gitignored** — this repo may go public, so no
committed file names them. The connection string itself lives in user secrets
under `ConnectionStrings:Games`. Never commit either, never print either.

**`db/install.sql` is the source of truth for all logic.** It is idempotent;
re-run it after any edit. `db/quick.sql` is the daily driver, `db/queries.sql`
the long tail.

The C# layer is deliberately thin: `Backlog.Web/Data/BacklogRepository.cs`
reads `custom.v_game`, `custom.v_unit` and `custom.v_game_tiers`. **If a query
in C# starts re-deriving something a view already computes — blocking, the
finished roll-up, tier boundaries — that is a bug.** Put it in the view.

Key objects:

| Object | What |
|---|---|
| `v_game_unit` / `v_unit` | one row per *playable unit*; the grain everything else works at |
| `v_game` | one row per owned game, with tags, series slot, blocking, parts |
| `v_roll_pool` | units you can start right now, with tags **and their short/medium/long tier**; the one definition of the rollable pool |
| `v_game_tiers` | thin projection of `v_roll_pool` — the `NTILE(3)` itself lives there now |
| `v_game_length_bands` | `v_roll_pool` counted into equal 1-hour bands to 200 + a `200+` tail, with a smoothed column — the distribution `/sizes` plots |
| `game_roll()` | rolls by bucket; redirects to a series head |
| `game_roll_range()` | rolls by an hours range **or** a tier, plus tags; no redirect needed — see rule 10 |
| `game_add()` | inserts; knows `hours_average` is generated |

## Domain rules that are easy to break

These were each found the hard way. Breaking one silently corrupts data or lies
to the user.

1. **The order PUT takes the complete ranked list.** The server unranks anything
   absent. Never hand `SetOrderAsync` a filtered subset.
2. **Reordering is disabled while a filter is active.** `IndexInZone` is an index
   into the *rendered* list. `AllowReorder="false"` does not stop a row being
   draggable, so the drop handler must refuse independently.
3. **While filtered, show the real `priority`**, not the visible index.
4. **A split game's `finished` is derived** from its parts. Setting the parent
   sets every part; setting a part re-derives the parent.
5. **Splitting never creates rows.** A collection you bought once stays one row
   in `game_completion_times`; the games inside it live in `game_part`.
6. **Blocking spans both parts and series** — `v_unit` computes it. Render
   `blocked_by`; never re-derive it.
7. **Tag filtering is AND**, matching `game_by_tag()`, `game_roll()` and
   `game_roll_range()`.
8. **Finishing a ranked game freezes its priority.** The `finished = false`
   guard in the unrank statement must stay.
9. **`hours_average` is a generated column.** Naming it in an INSERT raises.
10. **`v_roll_pool` is playable units only, and that is load-bearing.**
    "Playable" already excludes anything queued behind an unfinished
    predecessor, which is *why* `game_roll_range()` needs no series redirect —
    the range and the tags therefore hold for the game you are handed. Widen
    that view to unplayable units and the range starts lying. (`game_roll()`
    still carries a redirect, but it joins the same playable pool, so in
    practice that branch is unreachable; it is left alone rather than changed
    underneath its callers.)

## UI conventions

**Lengths are hidden by default** (`UiState.ShowHours`). Seeing "2h" next to a
title spoils the surprise of rolling for something. Do not add an hours figure
to any view without checking that flag. `/sizes` and `/roll` also sort by *name*
while hidden, because a list ordered by length leaks length even with the
numbers stripped.

The exception is a length the user *typed*: `/roll`'s range readout ("3h – 4h")
is their own input echoed back, not a fact about any game, so it shows either
way. The drawn game's actual hours stay behind the flag.

**`/roll`'s pool count is computed in memory, on purpose.** The page loads
`v_roll_pool` once and filters ~200 rows per slider move. The slider fires on
every pixel of a drag, so a query per event would be a round trip per pixel.
Tags are pre-lowercased at load for the same reason.

**`/roll` has two filters and they are mutually exclusive.** The hours slider and
the short/medium/long chips are alternatives, not a filter you narrow twice:
picking a size ignores the thumbs, and touching a thumb clears the size. Honouring
both would silently intersect them, and "short AND 40–60h" reads as a bug. The
tier goes to `game_roll_range` **as a tier**, never converted to hour bounds —
`NTILE` boundaries move as you finish things, so a converted range would drift
from what `v_game_tiers` says. `Matches()` on the page mirrors that precedence; if
the two disagree, the count beside the button is a lie.

**Charts come from `MudChart`, and aggregates come from the database.**
Conventions the `/sizes` chart follows, and any new one should:

- **One series → one colour and no legend.** The heading names the series. Never
  shade a mark by its own value — its length or height already encodes it.
- **Colours are `var(--mud-palette-*)`**, passed straight into `ChartPalette`,
  which MudBlazor emits into the SVG. So a chart follows the theme and dark mode
  without the page knowing which is active.
- **No value printed on every point.** The hover tooltip and a table view carry
  exact numbers; ten stamped numbers are noise.
- **Every chart has a table twin.** A tooltip must never be the only way to read
  a value.
- Aggregate charts are **not** gated behind `ShowHours`: they name no game, so
  they cannot spoil a title. Anything naming a game still is.
- Axis options live on the per-type options class (`LineChartOptions`,
  `BarChartOptions`), not on the base `ChartOptions`. Skip `XAxisTitle` —
  MudBlazor renders it *above* the plot, where it reads as a second heading.
- On a line chart, `InterpolationOption.Straight` and never a spline: a spline
  invents curvature between measured points and can bow below the baseline,
  drawing a negative count. Keep `ShowDataMarkers` on so the measured points stay
  visible, and `YAxisRequireZeroPoint` so a count axis starts at zero.
- **Histogram bands must be equal width, and the plot must only show equal-width
  bands.** A band twice as wide collects twice the games at the same density, so
  unequal widths make bin width read as signal — that bug had `/sizes` showing a
  peak at `20–30h` that does not exist. The open-ended tail band is the same trap at
  the end of the axis, so the chart plots only fixed-width bands and names the tail's
  count in the caption instead.
- **Smooth a sparse distribution with a rolling window, never by widening bands or
  splining.** `v_game_length_bands.smoothed_units` is a centred five-band rolling
  sum, so every plotted value is a real count and the window is the same width right
  across the axis. Widening the bands in the tail would reintroduce the bin-width
  bug; a spline would invent values between them.
- `YAxisTicks` is the knob that controls tick spacing; `MaxNumYAxisTicks` alone did
  nothing. Without it MudBlazor picked an interval of 20 for a range reaching 9 and
  squashed the curve into the bottom half of the plot.
- With many points, blank out most `ChartLabels` rather than shrinking them —
  MudBlazor still spaces the points evenly, so a blank removes text, not a reading.
- **There is no log axis, and faking one does not work.** MudBlazor picks "nice"
  tick values in whatever space the data arrives in, so plotting `log10(hours)`
  and inverting the labels via `YAxisToStringFunc` produced a tick at ~19 and a
  label of 10^19 hours. There is no hook to place ticks, so any hours axis is
  linear — which matters because one game at 718h flattens the other 192. Cap
  `MaxNumYAxisTicks`; without it a 718h range draws forty gridlines.
- **Synthetic mouse events do not reliably drive MudBlazor chart tooltips**, the
  same way they do not drive its drag. Verify hover with a real pointer, or lean
  on the table twin.

**Interactivity is global**, set on `<Routes>` and `<HeadOutlet>` in
`App.razor`. Per-page `@rendermode` leaves the layout static and its buttons
dead.

**`MudDropContainer.Items` must be one stable list instance**, mutated in place.
A freshly built list each render desynchronises its reorder bookkeeping and rows
render jumbled.

**Do not hand-write CSS.** The point of MudBlazor here is that styling comes
from the library. Two exceptions, both deliberate:

- the pre-hydration block in `wwwroot/app.css`, which must be plain CSS because
  it runs before any C# does; its colours are duplicated from
  `MainLayout.Theme` on purpose.
- `Components/Shared/RangeSlider.razor.css`, because MudBlazor 9.8 has no
  two-thumb slider (`MudSlider` is single-value, `MudRangeInput` is two *text*
  fields) and a native `<input type=range>` has one thumb by spec, so the track
  has to be drawn by hand. Its colours come from `--mud-palette-*` variables,
  never literals, so themes and dark mode follow without that file knowing.

`MainLayout.razor.css` and `ReconnectModal.razor.css` are **not** precedents for
app styling — they style `#blazor-error-ui` and `#components-reconnect-modal`,
Blazor template DOM that MudBlazor does not own.

## Working style

- **Verify against the real database**, not by reasoning. Use the Rider SQL MCP
  tools. Wrap experiments in `BEGIN; … ROLLBACK;`.
- **This is live personal data** — 236 games, hand-ranked. Never leave test rows
  behind; delete them and confirm the counts.
- **Check the rendered page, not just the DOM.** Three separate bugs here were
  invisible in markup and obvious in a screenshot. jsdom has no layout or colour.
- Synthetic `DragEvent`s do not drive MudBlazor. Use real CDP mouse drags.
