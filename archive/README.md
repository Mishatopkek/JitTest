# archive

## `legacy-ui.html`

The original hand-written backlog UI — 1,388 lines of vanilla JS and CSS that
lived at `JitTest/wwwroot/index.html` and talked to 14 minimal-API endpoints in
`JitTest/Program.cs`.

Replaced by `Backlog.Web` (Blazor Server + MudBlazor). Kept here only because it
was never committed to git, so deleting it would have destroyed it outright.

**It does not run.** Its backend went with the rewrite. To resurrect it you would
need those endpoints back; the SQL now lives in
`Backlog.Web/Data/BacklogRepository.cs`, unchanged.

Delete this folder once you are happy with the new app.
