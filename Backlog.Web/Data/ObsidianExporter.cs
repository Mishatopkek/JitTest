using System.Text;
using System.Text.RegularExpressions;

namespace Backlog.Web.Data;

public sealed record ObsidianExportResult(
    bool DryRun,
    IReadOnlyList<string> Created,
    IReadOnlyList<string> Updated,
    int SkippedExisting);

public sealed partial class ObsidianExporter(BacklogRepository repository, IConfiguration config)
{
    public async Task<ObsidianExportResult> ExportAsync(
        bool dryRun,
        CancellationToken ct = default,
        string? vaultPath = null)
    {
        var vault = string.IsNullOrWhiteSpace(vaultPath) ? config["Obsidian:VaultPath"] : vaultPath.Trim();
        if (string.IsNullOrWhiteSpace(vault))
        {
            throw new InvalidOperationException("The vault path isn't set");
        }

        if (!Directory.Exists(vault))
        {
            throw new InvalidOperationException("The vault path doesn't exist on the server");
        }

        var folder = Path.Combine(vault, config["Obsidian:Folder"] ?? "Main");
        var games = await repository.GetAllGamesAsync(ct);

        if (!dryRun)
        {
            Directory.CreateDirectory(folder);
        }

        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        Dictionary<int, string> names = [];

        foreach (var game in games.OrderBy(g => g.Id))
        {
            var name = FileName(game.Name, game.Id);
            if (!used.Add(name))
            {
                name = $"{name} ({game.Id})";
                used.Add(name);
            }

            names[game.Id] = name;
        }

        List<string> created = [];
        List<string> updated = [];
        var skipped = 0;

        foreach (var game in games.OrderBy(g => g.Id))
        {
            var name = names[game.Id];
            var path = Path.Combine(folder, name + ".md");
            var relations = RelationLines(game, games, names);

            // In a note that already exists only the keys named in OwnedKey are rewritten.
            // Every other line is written back as it was.
            if (File.Exists(path))
            {
                if (TryUpdateRelations(path, relations, dryRun))
                {
                    updated.Add(name);
                }
                else
                {
                    skipped++;
                }

                continue;
            }

            if (!dryRun && !TryCreate(path, Stub(game, name, relations)))
            {
                skipped++;
                continue;
            }

            created.Add(name);
        }

        foreach (var series in games.Where(g => g.Series is not null).Select(g => g.Series!).Distinct().Order())
        {
            var name = SeriesNote(series);
            var path = Path.Combine(folder, name + ".md");
            if (File.Exists(path))
            {
                continue;
            }

            if (!dryRun && !TryCreate(path, $"---\nimported: true\ntitle: {Quote(series)}\n---\n"))
            {
                continue;
            }

            created.Add(name);
        }

        return new ObsidianExportResult(dryRun, created, updated, skipped);
    }

    private static List<string> RelationLines(PickGame game, List<PickGame> games, Dictionary<int, string> names)
    {
        if (game.Series is null)
        {
            return [];
        }

        List<string> lines = [$"series: \"[[{SeriesNote(game.Series)}]]\""];
        if (game.Position is not { } position)
        {
            return lines;
        }

        lines.Add($"series_position: {position}");

        // Games tied on a slot unblock together, so a tie counts as one step
        var inSeries = games.Where(g => g.Series == game.Series && g.Position is not null).ToList();
        AddLinks(lines, "previous", inSeries.Where(g => g.Position < position), g => -g.Position!.Value, names);
        AddLinks(lines, "next", inSeries.Where(g => g.Position > position), g => g.Position!.Value, names);
        return lines;
    }

    private static void AddLinks(
        List<string> lines,
        string key,
        IEnumerable<PickGame> candidates,
        Func<PickGame, int> nearestFirst,
        Dictionary<int, string> names)
    {
        var all = candidates.ToList();
        var nearest = all.OrderBy(nearestFirst).FirstOrDefault();
        if (nearest is null)
        {
            return;
        }

        lines.Add($"{key}:");
        foreach (var game in all.Where(g => g.Position == nearest.Position).OrderBy(g => g.Id))
        {
            lines.Add($"  - \"[[{names[game.Id]}]]\"");
        }
    }

    private static bool TryUpdateRelations(string path, List<string> relations, bool dryRun)
    {
        try
        {
            var bytes = File.ReadAllBytes(path);
            var hasBom = bytes is [0xEF, 0xBB, 0xBF, ..];
            var offset = hasBom ? 3 : 0;
            var text = Encoding.UTF8.GetString(bytes, offset, bytes.Length - offset);
            var changed = ApplyRelations(text, relations);
            if (changed == text)
            {
                return false;
            }

            if (!dryRun)
            {
                var temp = path + ".tmp";
                var body = new UTF8Encoding(false).GetBytes(changed);
                File.WriteAllBytes(temp, hasBom ? [0xEF, 0xBB, 0xBF, .. body] : body);
                File.Move(temp, path, overwrite: true);
            }

            return true;
        }
        catch (IOException)
        {
            return false;
        }
    }

    private static string ApplyRelations(string text, List<string> relations)
    {
        var crlf = text.Contains("\r\n");
        var lineEnd = crlf ? "\r\n" : "\n";
        var lines = text.Split('\n').ToList();

        var close = -1;
        if (lines[0].TrimEnd('\r') == "---")
        {
            close = lines.FindIndex(1, l => l.TrimEnd('\r') == "---");
        }

        if (close < 0)
        {
            if (relations.Count == 0)
            {
                return text;
            }

            return "---" + lineEnd + string.Concat(relations.Select(l => l + lineEnd)) + "---" + lineEnd + text;
        }

        List<string> rebuilt = [lines[0]];
        var skipping = false;
        for (var i = 1; i < close; i++)
        {
            var line = lines[i];
            if (OwnedKey().IsMatch(line))
            {
                skipping = true;
                continue;
            }

            // The rest of an owned list: indented, or a flat "- item"
            if (skipping && (line.StartsWith(' ') || line.StartsWith('\t') || line.StartsWith("- ")))
            {
                continue;
            }

            skipping = false;
            rebuilt.Add(line);
        }

        rebuilt.AddRange(relations.Select(l => crlf ? l + "\r" : l));
        rebuilt.AddRange(lines.Skip(close));
        return string.Join('\n', rebuilt);
    }

    private static bool TryCreate(string path, string content)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
            stream.Write(new UTF8Encoding(false).GetBytes(content));
            return true;
        }
        catch (IOException) when (File.Exists(path))
        {
            return false;
        }
    }

    private static string Stub(PickGame game, string fileName, List<string> relations)
    {
        var title = Quote(game.Name);
        var sb = new StringBuilder();
        sb.Append("---\n");
        sb.Append("imported: true\n");
        sb.Append("basedOn: \"[[Game]]\"\n");
        sb.Append($"game_id: {game.Id}\n");
        sb.Append($"title: {title}\n");
        if (fileName != game.Name)
        {
            sb.Append($"aliases:\n  - {title}\n");
        }

        foreach (var line in relations)
        {
            sb.Append(line).Append('\n');
        }

        sb.Append("---\n");
        return sb.ToString();
    }

    private static string SeriesNote(string series) => FileName(series, 0);

    private static string Quote(string value) =>
        "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    // Windows forbids \ / : * ? " < > | and Obsidian links also break on # ^ [ ]
    private static string FileName(string title, int id)
    {
        var name = title.Replace(":", " -");
        name = Dropped().Replace(name, "");
        name = Separators().Replace(name, "-");
        name = Spaces().Replace(name, " ").Trim().TrimEnd('.', ' ');
        return name.Length == 0 ? $"game {id}" : name;
    }

    [GeneratedRegex("^(series|series_position|previous|next):")]
    private static partial Regex OwnedKey();

    [GeneratedRegex("""[\p{C}?"*<>#^\[\]]""")]
    private static partial Regex Dropped();

    [GeneratedRegex(@"[\\/|]")]
    private static partial Regex Separators();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Spaces();
}
