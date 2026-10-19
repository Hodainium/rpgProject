using System.Text.Json;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Serialization;

namespace Rpg.Contracts.Tests;

/// <summary>
/// Cross-language check (spec combat-replay-core, "C#"): the golden request and result files written by the Godot
/// replay runner deserialize into the Rpg.Contracts.Battle records and re-serialize byte for byte, so GDScript and C#
/// agree on every field name, field order, enum spelling and null.
/// </summary>
public class BattleGoldenTests
{
    private static readonly string GoldenDir = Path.Combine(RepoRoot(), "client-godot", "tests", "fixtures", "golden");

    public static TheoryData<string> Requests() => Files(name => !name.EndsWith(".result.json"));

    public static TheoryData<string> Results() => Files(name => name.EndsWith(".result.json"));

    [Theory]
    [MemberData(nameof(Requests))]
    public void GoldenRequest_RoundTripsByteForByte(string file)
    {
        var text = File.ReadAllText(Path.Combine(GoldenDir, file));

        var request = JsonSerializer.Deserialize<ReplayRequest>(text, RpgJson.Options)!;

        Assert.Equal(text, JsonSerializer.Serialize(request, RpgJson.Options));
        Assert.True(long.TryParse(request.Snapshot.Seed, out _), "seed is an int64 decimal string");
    }

    [Theory]
    [MemberData(nameof(Results))]
    public void GoldenResult_RoundTripsByteForByte_AndRejectionsCarry2002(string file)
    {
        var text = File.ReadAllText(Path.Combine(GoldenDir, file));

        var result = JsonSerializer.Deserialize<ReplayResult>(text, RpgJson.Options)!;

        Assert.Equal(text, JsonSerializer.Serialize(result, RpgJson.Options));
        if (result.Verdict == ReplayVerdict.Rejected)
        {
            Assert.Equal(ReplayErrors.ReplayMismatchCode, result.ErrorCode);
            Assert.Equal(ReplayErrors.ReplayMismatchName, result.Error);
            Assert.NotNull(result.Mismatch);
        }
        else
        {
            Assert.Null(result.ErrorCode);
            Assert.Null(result.Mismatch);
        }
    }

    [Fact]
    public void GoldenSet_IsComplete()
    {
        Assert.Equal(4, Requests().Count);
        Assert.Equal(4, Results().Count);
    }

    private static TheoryData<string> Files(Func<string, bool> filter)
    {
        var data = new TheoryData<string>();
        foreach (var path in Directory.GetFiles(GoldenDir, "*.json").Order(StringComparer.Ordinal))
        {
            var name = Path.GetFileName(path);
            if (filter(name))
            {
                data.Add(name);
            }
        }

        return data;
    }

    private static string RepoRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory != null && !File.Exists(Path.Combine(directory.FullName, "Rpg.slnx")))
        {
            directory = directory.Parent;
        }

        return directory?.FullName ?? throw new InvalidOperationException("Rpg.slnx not found above the test output.");
    }
}
