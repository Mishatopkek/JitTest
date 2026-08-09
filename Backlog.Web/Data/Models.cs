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

/// <summary>
/// One unit you could start right now, from custom.v_roll_pool. The roll screen
/// holds the whole pool so it can count matches as the sliders move without
/// going back to the database on every drag event.
/// </summary>
public sealed record RollUnit(
    int GameId,
    int? PartId,
    string UnitName,
    string OwnedAs,
    decimal Hours,
    int? Priority,
    string[] Tags)
{
    /// <summary>True when this unit is one game inside a collection you own.</summary>
    public bool IsPart => PartId is not null;
}

/// <summary>
/// What custom.game_roll_range() landed on. No "redirected" field, unlike
/// game_roll(): the range pool is playable units only, so there is never an
/// unfinished predecessor to be sent back to.
/// </summary>
public sealed record RollResult(
    string StartName,
    string OwnedAs,
    decimal Hours,
    int? Priority,
    string[] Tags,
    string? Series,
    int? SeriesSlot,
    long? SeriesTotal,
    long PoolSize,
    int GameId,
    int? PartId)
{
    public bool IsPart => PartId is not null;
}
