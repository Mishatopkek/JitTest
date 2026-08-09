namespace Backlog.Web.Data;

/// <summary>
/// Per-circuit view preferences. Scoped, so each browser tab gets its own.
/// </summary>
public sealed class UiState
{
    /// <summary>
    /// Whether to show how long a game takes.
    ///
    /// Off by default, on purpose. Seeing "2h" next to a title tells you what
    /// you are in for before you start it, and that is exactly the thing worth
    /// not knowing -- picking from a size bucket is a deliberate choice, but the
    /// precise length inside that bucket should stay a surprise.
    ///
    /// The numbers are still there when you want them, behind the toggle in the
    /// app bar.
    /// </summary>
    public bool ShowHours { get; private set; }

    public event Action? Changed;

    public void ToggleHours()
    {
        ShowHours = !ShowHours;
        Changed?.Invoke();
    }
}
