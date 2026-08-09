using Npgsql;
using NpgsqlTypes;

namespace Backlog.Web.Data;

/// <summary>
/// Every query the app makes. The SQL here is deliberately thin: the real logic
/// lives in db/install.sql as views and functions, so this reads custom.v_game,
/// custom.v_unit and custom.v_game_tiers rather than restating their joins.
///
/// Keep it that way. If a query here starts re-deriving something a view already
/// computes -- blocking, the finished roll-up, tier boundaries -- the two
/// definitions will drift.
/// </summary>
public sealed class BacklogRepository(NpgsqlDataSource db)
{
    // --- reading ------------------------------------------------------------

    /// <summary>
    /// Everything, split into ranked / unranked / finished. Finished games are
    /// returned too so the UI can offer to un-finish one.
    /// </summary>
    public async Task<Board> GetBoardAsync(CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand(
            """
            SELECT id, game_name, hours_average, priority,
                   series, series_slot, series_total, blocked_by, tags,
                   finished, parts, parts_finished, next_up
            FROM custom.v_game
            ORDER BY priority, game_name
            """);

        await using var reader = await cmd.ExecuteReaderAsync(ct);

        List<Game> ranked = [], unranked = [], done = [];
        while (await reader.ReadAsync(ct))
        {
            var priority = reader.IsDBNull(3) ? (int?)null : reader.GetInt32(3);
            var finished = reader.GetBoolean(9);
            var game = new Game(
                reader.GetInt32(0),
                reader.GetString(1),
                reader.IsDBNull(2) ? null : reader.GetDecimal(2),
                priority,
                reader.IsDBNull(4) ? null : reader.GetString(4),
                reader.IsDBNull(5) ? null : reader.GetInt32(5),
                // count(*), so bigint on the wire.
                reader.IsDBNull(6) ? null : reader.GetInt64(6),
                reader.IsDBNull(7) ? null : reader.GetString(7),
                reader.GetFieldValue<string[]>(8),
                finished,
                reader.GetInt64(10),
                reader.GetInt64(11),
                reader.IsDBNull(12) ? null : reader.GetString(12));

            (finished ? done : priority is null ? unranked : ranked).Add(game);
        }

        return new Board(ranked, unranked, done);
    }

    /// <summary>Every game, finished included -- the series editor needs them.</summary>
    public async Task<List<PickGame>> GetAllGamesAsync(CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand(
            """
            SELECT id, game_name, finished, series, series_slot
            FROM custom.v_game
            ORDER BY game_name
            """);

        await using var reader = await cmd.ExecuteReaderAsync(ct);

        List<PickGame> games = [];
        while (await reader.ReadAsync(ct))
        {
            games.Add(new PickGame(
                reader.GetInt32(0),
                reader.GetString(1),
                reader.GetBoolean(2),
                reader.IsDBNull(3) ? null : reader.GetString(3),
                reader.IsDBNull(4) ? null : reader.GetInt32(4)));
        }

        return games;
    }

    public async Task<List<Part>> GetPartsAsync(int gameId, CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand(
            """
            SELECT p.id, p.part_name, p.part_position, u.hours, p.finished, u.playable, u.blocked_by
            FROM custom.game_part p
            JOIN custom.v_unit u ON u.part_id = p.id
            WHERE p.game_id = @id
            ORDER BY p.part_position
            """);
        cmd.Parameters.AddWithValue("id", gameId);

        await using var reader = await cmd.ExecuteReaderAsync(ct);

        List<Part> parts = [];
        while (await reader.ReadAsync(ct))
        {
            parts.Add(new Part(
                reader.GetInt32(0),
                reader.GetString(1),
                reader.GetInt32(2),
                reader.IsDBNull(3) ? null : reader.GetDecimal(3),
                reader.GetBoolean(4),
                reader.GetBoolean(5),
                reader.IsDBNull(6) ? null : reader.GetString(6)));
        }

        return parts;
    }

    /// <summary>
    /// Playable units with their length bucket. NTILE(3) over what you can
    /// actually start, so the boundaries move as you finish things.
    /// </summary>
    public async Task<List<TierRow>> GetTiersAsync(CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand(
            """
            SELECT t.tier, t.tier_name, t.unit_name, t.game_name, t.hours_average, u.priority
            FROM custom.v_game_tiers t
            JOIN custom.v_unit u ON u.game_id = t.game_id
                                AND u.part_id IS NOT DISTINCT FROM t.part_id
            ORDER BY t.tier, t.hours_average
            """);

        await using var reader = await cmd.ExecuteReaderAsync(ct);

        List<TierRow> rows = [];
        while (await reader.ReadAsync(ct))
        {
            rows.Add(new TierRow(
                reader.GetInt32(0),
                reader.GetString(1),
                reader.GetString(2),
                reader.GetString(3),
                reader.IsDBNull(4) ? null : reader.GetDecimal(4),
                reader.IsDBNull(5) ? null : reader.GetInt32(5)));
        }

        return rows;
    }

    /// <summary>
    /// Case-insensitive "contains" search on the name, for checking whether you
    /// already own something before adding it. Backed by the GIN trigram index,
    /// so the leading wildcard does not force a full scan.
    /// </summary>
    public async Task<List<PickGame>> SearchGamesAsync(string query, CancellationToken ct = default)
    {
        query = query.Trim();
        if (query.Length == 0) return [];

        await using var cmd = db.CreateCommand(
            """
            SELECT id, game_name, finished, series, series_slot
            FROM custom.v_game
            WHERE game_name ILIKE '%' || @q || '%'
            ORDER BY game_name
            LIMIT 25
            """);
        cmd.Parameters.AddWithValue("q", query);

        await using var reader = await cmd.ExecuteReaderAsync(ct);

        List<PickGame> hits = [];
        while (await reader.ReadAsync(ct))
        {
            hits.Add(new PickGame(
                reader.GetInt32(0),
                reader.GetString(1),
                reader.GetBoolean(2),
                reader.IsDBNull(3) ? null : reader.GetString(3),
                reader.IsDBNull(4) ? null : reader.GetInt32(4)));
        }

        return hits;
    }

    /// <summary>
    /// Insert a game, returning its id.
    ///
    /// Delegates to custom.game_add rather than writing the INSERT here: that
    /// function knows hours_average is a generated column (naming it raises),
    /// creates any new tags and series, and enforces that series and position
    /// are given together.
    /// </summary>
    public async Task<int> AddGameAsync(
        string name,
        decimal hoursMain, decimal hoursMainExtra, decimal hoursCompletionist,
        string? notes = null, int? priority = null,
        string[]? tags = null, string? series = null, int? seriesPosition = null,
        CancellationToken ct = default)
    {
        name = name.Trim();
        if (name.Length == 0) throw new ArgumentException("Name is empty.", nameof(name));

        await using var cmd = db.CreateCommand(
            """
            SELECT id FROM custom.game_add(
                @name, @main, @extra, @comp, @notes, @priority, @tags, @series, @slot)
            """);

        // Types are declared explicitly rather than inferred: an untyped
        // DBNull gives Postgres nothing to resolve game_add's overload against,
        // and the text[] parameter cannot be inferred from a null at all.
        cmd.Parameters.Add(new NpgsqlParameter("name", NpgsqlDbType.Text) { Value = name });
        cmd.Parameters.Add(new NpgsqlParameter("main", NpgsqlDbType.Numeric) { Value = hoursMain });
        cmd.Parameters.Add(new NpgsqlParameter("extra", NpgsqlDbType.Numeric) { Value = hoursMainExtra });
        cmd.Parameters.Add(new NpgsqlParameter("comp", NpgsqlDbType.Numeric) { Value = hoursCompletionist });
        cmd.Parameters.Add(new NpgsqlParameter("notes", NpgsqlDbType.Text)
            { Value = (object?)notes ?? DBNull.Value });
        cmd.Parameters.Add(new NpgsqlParameter("priority", NpgsqlDbType.Integer)
            { Value = (object?)priority ?? DBNull.Value });
        cmd.Parameters.Add(new NpgsqlParameter("tags", NpgsqlDbType.Array | NpgsqlDbType.Text)
            { Value = tags is { Length: > 0 } ? tags : DBNull.Value });
        cmd.Parameters.Add(new NpgsqlParameter("series", NpgsqlDbType.Text)
            { Value = (object?)series ?? DBNull.Value });
        cmd.Parameters.Add(new NpgsqlParameter("slot", NpgsqlDbType.Integer)
            { Value = (object?)seriesPosition ?? DBNull.Value });

        return (int)(await cmd.ExecuteScalarAsync(ct))!;
    }

    /// <summary>
    /// How the startable pool spreads across length bands -- the shape of the
    /// backlog. Bands, boundaries and the empty-band rows are all decided by
    /// custom.v_game_length_bands; this only reads them, so the chart cannot
    /// disagree with the view about where a band starts.
    /// </summary>
    public async Task<List<LengthBand>> GetLengthBandsAsync(CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand(
            """
            SELECT label, units, band_hours
            FROM custom.v_game_length_bands
            ORDER BY ord
            """);

        await using var reader = await cmd.ExecuteReaderAsync(ct);

        List<LengthBand> bands = [];
        while (await reader.ReadAsync(ct))
        {
            bands.Add(new LengthBand(
                reader.GetString(0),
                // count(*), so bigint on the wire.
                (int)reader.GetInt64(1),
                reader.GetDecimal(2)));
        }

        return bands;
    }

    /// <summary>
    /// The whole rollable pool in one query. The roll screen recounts matches on
    /// every slider move, and that has to stay off the database -- 200-odd rows
    /// filtered in memory beats a round trip per drag event.
    /// </summary>
    public async Task<List<RollUnit>> GetRollPoolAsync(CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand(
            """
            SELECT game_id, part_id, unit_name, game_name, hours, priority, tags
            FROM custom.v_roll_pool
            ORDER BY unit_name
            """);

        await using var reader = await cmd.ExecuteReaderAsync(ct);

        List<RollUnit> units = [];
        while (await reader.ReadAsync(ct))
        {
            units.Add(new RollUnit(
                reader.GetInt32(0),
                reader.IsDBNull(1) ? null : reader.GetInt32(1),
                reader.GetString(2),
                reader.GetString(3),
                reader.GetDecimal(4),
                reader.IsDBNull(5) ? null : reader.GetInt32(5),
                reader.GetFieldValue<string[]>(6)));
        }

        return units;
    }

    /// <summary>
    /// Roll a playable unit whose length falls in [minHours, maxHours] and which
    /// carries every one of <paramref name="tags"/>.
    /// </summary>
    /// <param name="minHours">null leaves the bottom open.</param>
    /// <param name="maxHours">null leaves the top open -- which is what the last
    /// stop on the slider means, since the pool runs past 700 hours.</param>
    /// <returns>null when nothing matched.</returns>
    public async Task<RollResult?> RollRangeAsync(
        decimal? minHours,
        decimal? maxHours,
        IEnumerable<string> tags,
        CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand(
            """
            SELECT start_name, owned_as, start_hours, start_priority, start_tags,
                   series, series_slot, series_total, pool_size,
                   start_game_id, start_part_id
            FROM custom.game_roll_range(@min, @max, @tags)
            """);

        cmd.Parameters.Add(new NpgsqlParameter("min", NpgsqlDbType.Numeric)
            { Value = (object?)minHours ?? DBNull.Value });
        cmd.Parameters.Add(new NpgsqlParameter("max", NpgsqlDbType.Numeric)
            { Value = (object?)maxHours ?? DBNull.Value });

        // An empty array would demand a game carrying no tags at all; the
        // function wants NULL for "do not filter on tags".
        var wanted = tags.ToArray();
        cmd.Parameters.Add(new NpgsqlParameter("tags", NpgsqlDbType.Array | NpgsqlDbType.Text)
            { Value = wanted.Length == 0 ? DBNull.Value : wanted });

        await using var reader = await cmd.ExecuteReaderAsync(ct);

        if (!await reader.ReadAsync(ct)) return null;

        return new RollResult(
            reader.GetString(0),
            reader.GetString(1),
            reader.GetDecimal(2),
            reader.IsDBNull(3) ? null : reader.GetInt32(3),
            reader.GetFieldValue<string[]>(4),
            reader.IsDBNull(5) ? null : reader.GetString(5),
            reader.IsDBNull(6) ? null : reader.GetInt32(6),
            reader.IsDBNull(7) ? null : reader.GetInt64(7),
            reader.GetInt64(8),
            reader.GetInt32(9),
            reader.IsDBNull(10) ? null : reader.GetInt32(10));
    }

    public async Task<List<string>> GetTagsAsync(CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand(
            "SELECT tag_name FROM custom.tag ORDER BY lower(tag_name)");
        await using var reader = await cmd.ExecuteReaderAsync(ct);

        List<string> tags = [];
        while (await reader.ReadAsync(ct)) tags.Add(reader.GetString(0));
        return tags;
    }

    public async Task<List<Series>> GetSeriesAsync(CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand(
            """
            SELECT s.id, s.series_name, g.id, g.game_name, g.series_position, g.finished
            FROM custom.series s
            LEFT JOIN custom.game_completion_times g ON g.series_id = s.id
            ORDER BY lower(s.series_name), g.series_position, g.game_name
            """);

        await using var reader = await cmd.ExecuteReaderAsync(ct);

        List<Series> series = [];
        while (await reader.ReadAsync(ct))
        {
            var id = reader.GetInt32(0);
            if (series.Count == 0 || series[^1].Id != id)
            {
                series.Add(new Series(id, reader.GetString(1), []));
            }

            // LEFT JOIN: a series with no games yet yields one all-null row.
            if (!reader.IsDBNull(2))
            {
                series[^1].Games.Add(new SeriesGame(
                    reader.GetInt32(2),
                    reader.GetString(3),
                    reader.GetInt32(4),
                    reader.GetBoolean(5)));
            }
        }

        return series;
    }

    // --- writing ------------------------------------------------------------

    /// <summary>
    /// Takes the COMPLETE ranked list, in order. Anything absent is unranked and
    /// everything present is renumbered 1..n, so this one call covers reorder,
    /// add and remove.
    ///
    /// Never hand this a filtered subset -- it would unrank everything hidden.
    /// </summary>
    public async Task SetOrderAsync(IReadOnlyList<int> ids, CancellationToken ct = default)
    {
        var array = ids.ToArray();
        if (array.Length != array.Distinct().Count())
        {
            throw new ArgumentException("Duplicate ids in order.", nameof(ids));
        }

        await using var connection = await db.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);

        // Both statements must land together: between them the table would show
        // a ranking that is missing the games being moved.
        //
        // finished = false matters: a finished game is not in the client's
        // ranked list any more, so without this guard the next unrelated
        // reorder would silently clear the rank it had when you finished it.
        await using (var clear = new NpgsqlCommand(
            """
            UPDATE custom.game_completion_times
               SET priority = NULL
             WHERE priority IS NOT NULL
               AND finished = false
               AND id <> ALL (@ids)
            """, connection, transaction))
        {
            clear.Parameters.AddWithValue("ids", array);
            await clear.ExecuteNonQueryAsync(ct);
        }

        await using (var renumber = new NpgsqlCommand(
            """
            UPDATE custom.game_completion_times g
               SET priority = o.rn
              FROM unnest(@ids) WITH ORDINALITY AS o(id, rn)
             WHERE g.id = o.id
               AND g.priority IS DISTINCT FROM o.rn
            """, connection, transaction))
        {
            renumber.Parameters.AddWithValue("ids", array);
            await renumber.ExecuteNonQueryAsync(ct);
        }

        await transaction.CommitAsync(ct);
    }

    /// <summary>
    /// Replace a game's parts with the given list, in order. An empty list
    /// unsplits it. Splitting never adds rows: the purchase stays one row and
    /// the games inside it hang off it.
    /// </summary>
    public async Task ReplacePartsAsync(int gameId, IReadOnlyList<string> names,
                                        CancellationToken ct = default)
    {
        var clean = names.Select(n => n?.Trim() ?? "").Where(n => n.Length > 0).ToArray();
        if (clean.Length == 1)
        {
            throw new ArgumentException("A split needs at least two parts.", nameof(names));
        }

        if (clean.Length != clean.Select(n => n.ToLowerInvariant()).Distinct().Count())
        {
            throw new ArgumentException("Two parts have the same name.", nameof(names));
        }

        await using var connection = await db.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);

        // One statement, no temp table: connections are pooled, and a temp
        // table surviving on a reused connection would break the next request.
        //
        // Data-modifying CTEs all see the same snapshot and each runs exactly
        // once whether or not the main query reads them, so `old` reads the
        // pre-delete rows while `del` still clears them. That is what lets a
        // re-split match survivors by name and keep their progress.
        await using (var replace = new NpgsqlCommand(
            """
            WITH old AS (
                SELECT lower(part_name) AS k, finished AS fin, hours AS hrs
                FROM custom.game_part WHERE game_id = @id
            ),
            del AS (
                DELETE FROM custom.game_part WHERE game_id = @id
            )
            INSERT INTO custom.game_part (game_id, part_position, part_name, hours, finished)
            SELECT @id, o.rn, o.name, k.hrs, coalesce(k.fin, false)
            FROM unnest(@names) WITH ORDINALITY AS o(name, rn)
            LEFT JOIN old k ON k.k = lower(o.name)
            """, connection, transaction))
        {
            replace.Parameters.AddWithValue("id", gameId);
            replace.Parameters.AddWithValue("names", clean);
            await replace.ExecuteNonQueryAsync(ct);
        }

        await SyncParentFinishedAsync(connection, transaction, gameId, ct);
        await transaction.CommitAsync(ct);
    }

    /// <summary>
    /// Mark a whole game finished. On a split game this sets every part, because
    /// the parent's state is the roll-up and setting it alone would be ignored
    /// by every view.
    /// </summary>
    public async Task SetGameFinishedAsync(int gameId, bool finished, CancellationToken ct = default)
    {
        await using var connection = await db.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);

        await using (var parts = new NpgsqlCommand(
            "UPDATE custom.game_part SET finished = @f WHERE game_id = @id", connection, transaction))
        {
            parts.Parameters.AddWithValue("id", gameId);
            parts.Parameters.AddWithValue("f", finished);
            await parts.ExecuteNonQueryAsync(ct);
        }

        await using (var game = new NpgsqlCommand(
            "UPDATE custom.game_completion_times SET finished = @f WHERE id = @id",
            connection, transaction))
        {
            game.Parameters.AddWithValue("id", gameId);
            game.Parameters.AddWithValue("f", finished);
            await game.ExecuteNonQueryAsync(ct);
        }

        await transaction.CommitAsync(ct);
    }

    /// <summary>Mark one part finished, then re-derive the parent flag.</summary>
    public async Task SetPartFinishedAsync(int partId, bool finished, CancellationToken ct = default)
    {
        await using var connection = await db.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);

        await using (var part = new NpgsqlCommand(
            "UPDATE custom.game_part SET finished = @f WHERE id = @id", connection, transaction))
        {
            part.Parameters.AddWithValue("id", partId);
            part.Parameters.AddWithValue("f", finished);
            await part.ExecuteNonQueryAsync(ct);
        }

        await using (var sync = new NpgsqlCommand(
            """
            UPDATE custom.game_completion_times g
               SET finished = (SELECT count(*) = count(*) FILTER (WHERE p.finished)
                               FROM custom.game_part p WHERE p.game_id = g.id)
             WHERE g.id = (SELECT game_id FROM custom.game_part WHERE id = @id)
            """, connection, transaction))
        {
            sync.Parameters.AddWithValue("id", partId);
            await sync.ExecuteNonQueryAsync(ct);
        }

        await transaction.CommitAsync(ct);
    }

    /// <summary>
    /// Attach a tag, creating it if new. custom.tag_id() does the find-or-create
    /// and the case-insensitive matching, so "pc" never becomes a second tag
    /// alongside "PC".
    /// </summary>
    public async Task AddTagAsync(int gameId, string tag, CancellationToken ct = default)
    {
        tag = tag.Trim();
        if (tag.Length == 0) return;

        await using var cmd = db.CreateCommand(
            """
            INSERT INTO custom.game_tag_link (game_id, tag_id)
            VALUES (@id, custom.tag_id(@tag))
            ON CONFLICT DO NOTHING
            """);
        cmd.Parameters.AddWithValue("id", gameId);
        cmd.Parameters.AddWithValue("tag", tag);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    /// <summary>
    /// Detach a tag from one game. The tag row survives -- other games use it.
    /// custom.tag_prune() clears out ones nothing references.
    /// </summary>
    public async Task RemoveTagAsync(int gameId, string tag, CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand(
            """
            DELETE FROM custom.game_tag_link l
            USING custom.tag t
            WHERE l.tag_id = t.id
              AND l.game_id = @id
              AND lower(t.tag_name) = lower(@tag)
            """);
        cmd.Parameters.AddWithValue("id", gameId);
        cmd.Parameters.AddWithValue("tag", tag);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    /// <summary>
    /// Create a series, or hand back the existing one -- matching is
    /// case-insensitive, so "yakuza" selects an existing "Yakuza".
    /// </summary>
    public async Task<Series> CreateSeriesAsync(string name, CancellationToken ct = default)
    {
        name = name.Trim();
        if (name.Length == 0) throw new ArgumentException("Name is empty.", nameof(name));

        // Two statements on purpose. series_id() is VOLATILE and inserts, so
        // folding it into a WHERE against custom.series risks being evaluated
        // per row -- and the row it creates is not visible to the surrounding
        // statement's snapshot anyway.
        await using var connection = await db.OpenConnectionAsync(ct);

        int id;
        await using (var resolve = new NpgsqlCommand("SELECT custom.series_id(@name)", connection))
        {
            resolve.Parameters.AddWithValue("name", name);
            id = (int)(await resolve.ExecuteScalarAsync(ct))!;
        }

        await using var read = new NpgsqlCommand(
            "SELECT series_name FROM custom.series WHERE id = @id", connection);
        read.Parameters.AddWithValue("id", id);
        var stored = (string)(await read.ExecuteScalarAsync(ct))!;

        return new Series(id, stored, []);
    }

    /// <summary>
    /// The complete membership of one series, in order. Same contract as
    /// SetOrderAsync: anything absent is detached, everything present is
    /// renumbered 1..n.
    /// </summary>
    public async Task SetSeriesOrderAsync(int seriesId, IReadOnlyList<int> ids,
                                          CancellationToken ct = default)
    {
        var array = ids.ToArray();
        if (array.Length != array.Distinct().Count())
        {
            throw new ArgumentException("Duplicate ids in order.", nameof(ids));
        }

        await using var connection = await db.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);

        // Both columns clear together -- the table's CHECK requires it.
        await using (var detach = new NpgsqlCommand(
            """
            UPDATE custom.game_completion_times
               SET series_id = NULL, series_position = NULL
             WHERE series_id = @sid
               AND id <> ALL (@ids)
            """, connection, transaction))
        {
            detach.Parameters.AddWithValue("sid", seriesId);
            detach.Parameters.AddWithValue("ids", array);
            await detach.ExecuteNonQueryAsync(ct);
        }

        // A game listed here may currently sit in a different series; this
        // moves it, which is what dropping it into this list means.
        await using (var attach = new NpgsqlCommand(
            """
            UPDATE custom.game_completion_times g
               SET series_id = @sid, series_position = o.rn
              FROM unnest(@ids) WITH ORDINALITY AS o(id, rn)
             WHERE g.id = o.id
               AND (g.series_id       IS DISTINCT FROM @sid
                 OR g.series_position IS DISTINCT FROM o.rn)
            """, connection, transaction))
        {
            attach.Parameters.AddWithValue("sid", seriesId);
            attach.Parameters.AddWithValue("ids", array);
            await attach.ExecuteNonQueryAsync(ct);
        }

        await transaction.CommitAsync(ct);
    }

    /// <summary>
    /// Delete a series. The foreign key is NO ACTION, so its games are detached
    /// first -- in the same transaction, or a failure here would leave them
    /// orphaned from a series that no longer exists.
    /// </summary>
    public async Task DeleteSeriesAsync(int seriesId, CancellationToken ct = default)
    {
        await using var connection = await db.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);

        await using (var detach = new NpgsqlCommand(
            """
            UPDATE custom.game_completion_times
               SET series_id = NULL, series_position = NULL
             WHERE series_id = @sid
            """, connection, transaction))
        {
            detach.Parameters.AddWithValue("sid", seriesId);
            await detach.ExecuteNonQueryAsync(ct);
        }

        await using (var drop = new NpgsqlCommand(
            "DELETE FROM custom.series WHERE id = @sid", connection, transaction))
        {
            drop.Parameters.AddWithValue("sid", seriesId);
            await drop.ExecuteNonQueryAsync(ct);
        }

        await transaction.CommitAsync(ct);
    }

    /// <summary>
    /// Keep the stored parent flag agreeing with its parts, so anything reading
    /// the table directly still sees the truth. A game with no parts is left
    /// alone -- its own flag is the source of truth.
    /// </summary>
    private static async Task SyncParentFinishedAsync(
        NpgsqlConnection connection, System.Data.Common.DbTransaction transaction,
        int gameId, CancellationToken ct)
    {
        await using var sync = new NpgsqlCommand(
            """
            UPDATE custom.game_completion_times g
               SET finished = (SELECT count(*) = count(*) FILTER (WHERE p.finished)
                               FROM custom.game_part p WHERE p.game_id = g.id)
             WHERE g.id = @id
               AND EXISTS (SELECT 1 FROM custom.game_part p WHERE p.game_id = g.id)
            """, connection, (NpgsqlTransaction)transaction);
        sync.Parameters.AddWithValue("id", gameId);
        await sync.ExecuteNonQueryAsync(ct);
    }
}
