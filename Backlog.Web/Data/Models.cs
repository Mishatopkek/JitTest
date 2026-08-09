namespace Backlog.Web.Data;

/// <summary>
/// One owned row of custom.game_completion_times, as assembled by custom.v_game.
/// </summary>
/// <param name="Parts">Number of games inside this purchase, 0 when it is not split.</param>
/// <param name="NextUp">The part you may start next, null when the whole thing is blocked or done.</param>
/// <param name="BlockedBy">
/// Set only when NOTHING in this game is startable. A split game whose part 1 is
/// available is playable even though parts 2 and 3 are not, so this stays null.
/// </param>
public sealed record Game(
    int Id,
    string Name,
    decimal? Hours,
    int? Priority,
    string? Series,
    int? SeriesPosition,
    long? SeriesTotal,
    string? BlockedBy,
    string[] Tags,
    bool Finished,
    long Parts,
    long PartsFinished,
    string? NextUp)
{
    public bool IsSplit => Parts > 0;
}

/// <summary>One game inside a split purchase.</summary>
public sealed record Part(
    int Id,
    string Name,
    int Position,
    decimal? Hours,
    bool Finished,
    bool Playable,
    string? BlockedBy);

public sealed record Series(int Id, string Name, List<SeriesGame> Games);

public sealed record SeriesGame(int Id, string Name, int Position, bool Finished);

/// <summary>Every game, finished included, for the pickers.</summary>
public sealed record PickGame(int Id, string Name, bool Finished, string? Series, int? Position);

/// <summary>A playable unit with its length bucket, from custom.v_game_tiers.</summary>
public sealed record TierRow(
    int Tier,
    string TierName,
    string UnitName,
    string OwnedAs,
    decimal? Hours,
    int? Priority)
{
    /// <summary>True when this unit is a part, i.e. the purchase holds more than it.</summary>
    public bool IsPart => !string.Equals(UnitName, OwnedAs, StringComparison.Ordinal);
}

/// <summary>The three piles the play-order screen works in.</summary>
public sealed record Board(List<Game> Ranked, List<Game> Unranked, List<Game> Done);
