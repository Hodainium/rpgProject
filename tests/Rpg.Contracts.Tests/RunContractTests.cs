using System.Reflection;
using System.Text.Json;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;

namespace Rpg.Contracts.Tests;

/// <summary>
/// Spec server-authority 6, contract tests: golden JSON for every Part A record (exact camelCase shape, byte for byte,
/// and round trip), and the API error codes never colliding with the 2002 replay verdict.
/// </summary>
public class RunContractTests
{
    private const string RunId = "019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b";
    private const string Ruleset = "4.7.2.stable.mono+0123456789abcdef";
    private static readonly DateTimeOffset Started = new(2026, 10, 27, 12, 0, 0, TimeSpan.Zero);

    public static TheoryData<string, object> Goldens() => new()
    {
        { "run-start-request.json", new RunStartRequest(Ruleset, "descent", ["warrior", "cleric", "ranger"]) },
        { "run-start-response.json", new RunStartResponse(RunId, 0, "8070450532247928832", Started) },
        { "floor-seed-request.json", new FloorSeedRequest() },
        { "floor-seed-response.json", new FloorSeedResponse(RunId, 3, "1234567890123456789") },
        {
            "run-summary.json", new RunSummaryResponse(RunId, RunStatus.Abandoned, 3, 0, Ruleset, Started,
                new DateTimeOffset(2026, 10, 27, 12, 45, 30, TimeSpan.Zero))
        },
    };

    [Theory]
    [MemberData(nameof(Goldens))]
    public void RunRecord_MatchesGoldenVector_ByteForByte(string file, object record)
    {
        Assert.Equal(ReadGolden(file), JsonSerializer.Serialize(record, record.GetType(), RpgJson.Options));
    }

    [Theory]
    [MemberData(nameof(Goldens))]
    public void RunRecord_GoldenVector_RoundTrips(string file, object record)
    {
        var text = ReadGolden(file);

        var parsed = JsonSerializer.Deserialize(text, record.GetType(), RpgJson.Options)!;

        Assert.Equal(text, JsonSerializer.Serialize(parsed, record.GetType(), RpgJson.Options));
    }

    [Fact]
    public void FloorSeeds_AreDecimalStrings_ThatParseAsNonNegativeInt64()
    {
        var response = JsonSerializer.Deserialize<RunStartResponse>(ReadGolden("run-start-response.json"),
            RpgJson.Options)!;

        Assert.True(long.TryParse(response.FloorSeed, out var seed) && seed >= 0);
    }

    [Fact]
    public void ApiErrors_AreDistinct_AndNeverTheReplayVerdict()
    {
        var codes = typeof(ApiErrors).GetFields(BindingFlags.Public | BindingFlags.Static)
            .Where(field => field.IsLiteral)
            .Select(field => (int)field.GetRawConstantValue()!)
            .ToList();

        Assert.Equal(11, codes.Count);
        Assert.Equal(codes.Count, codes.Distinct().Count());
        Assert.DoesNotContain(ReplayErrors.ReplayMismatchCode, codes);
    }

    private static string ReadGolden(string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "golden", name));
}
