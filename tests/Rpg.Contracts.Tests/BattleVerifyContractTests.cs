using System.Text.Json;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Battle;
using Rpg.Verification;
using Rpg.Contracts.Serialization;

namespace Rpg.Contracts.Tests;

/// <summary>Spec battle-verify 6: golden JSON for the job and the verdicts, and the verdict built from a Godot result.</summary>
public class BattleVerifyContractTests
{
    private const string RunId = "019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b";
    private const string Ruleset = "4.7.2.stable.mono+0123456789abcdef";
    private const string Engine = "4.7.2.stable.mono.official.ed1daf0bf";
    private const string FinalHash = "c49f208156b68a88c33a52bec13928b9b8184bd261dfb3a6828a1dd57bc0fc3d";
    private static readonly DateTimeOffset Played = new(2026, 10, 27, 12, 3, 4, TimeSpan.Zero);
    private static readonly DateTimeOffset Verified = new(2026, 10, 27, 12, 3, 9, TimeSpan.Zero);

    public static TheoryData<string, object> Goldens() => new()
    {
        { "verify-battle-job.json", new VerifyBattleJob($"{RunId}/f0/c12", Guid.Parse(RunId), 9, Ruleset, Played) },
        {
            "battle-verdict-verified.json",
            new BattleVerdict(ReplayVerdict.Verified, null, null, null, BattleOutcome.Victory, 27, FinalHash, Ruleset,
                Engine, Verified)
        },
        {
            "battle-verdict-rejected.json",
            new BattleVerdict(ReplayVerdict.Rejected, ReplayErrors.ReplayMismatchCode, ReplayErrors.ReplayMismatchName,
                new ReplayMismatch(MismatchReason.FinalHashMismatch, 27, "claimed de85, simulated c49f"),
                BattleOutcome.Victory, 27, FinalHash, Ruleset, Engine, Verified)
        },
    };

    [Theory]
    [MemberData(nameof(Goldens))]
    public void Record_MatchesGoldenVector_ByteForByte(string file, object record) =>
        Assert.Equal(ReadGolden(file), JsonSerializer.Serialize(record, record.GetType(), RpgJson.Options));

    [Theory]
    [MemberData(nameof(Goldens))]
    public void Record_GoldenVector_RoundTrips(string file, object record)
    {
        var text = ReadGolden(file);

        var parsed = JsonSerializer.Deserialize(text, record.GetType(), RpgJson.Options)!;

        Assert.Equal(text, JsonSerializer.Serialize(parsed, record.GetType(), RpgJson.Options));
    }

    [Fact]
    public void BattleSession_WithoutVerdict_ReadsOldJson()
    {
        var request = ReadGodotRequest("run-v2-seed-7.json");
        var old = new BattleSessionResponse("b", RunId, 9, request.Snapshot, request.ActionLog, Ruleset,
            BattleSessionStatus.Submitted, Played);
        var text = JsonSerializer.Serialize(old, RpgJson.Options).Replace(",\"verdict\":null", "");

        var parsed = JsonSerializer.Deserialize<BattleSessionResponse>(text, RpgJson.Options)!;

        Assert.DoesNotContain("verdict", text);
        Assert.Null(parsed.Verdict);
        Assert.Equal(BattleSessionStatus.Submitted, parsed.Status);
    }

    [Fact]
    public void BattleSession_WithVerdict_RoundTrips()
    {
        var request = ReadGodotRequest("run-v2-seed-7.json");
        var verdict = JsonSerializer.Deserialize<BattleVerdict>(ReadGolden("battle-verdict-rejected.json"),
            RpgJson.Options);
        var session = new BattleSessionResponse("b", RunId, 9, request.Snapshot, request.ActionLog, Ruleset,
            BattleSessionStatus.Rejected, Played, verdict);

        var text = JsonSerializer.Serialize(session, RpgJson.Options);

        Assert.Contains("\"status\":\"Rejected\"", text);
        Assert.Contains("\"errorCode\":2002", text);
        Assert.Equal(text, JsonSerializer.Serialize(
            JsonSerializer.Deserialize<BattleSessionResponse>(text, RpgJson.Options), RpgJson.Options));
    }

    [Theory]
    [InlineData("run-v2-seed-7.result.json", ReplayVerdict.Verified)]
    [InlineData("squad-seed-42-tampered-final.result.json", ReplayVerdict.Rejected)]
    public void Verdict_BuiltFromGodotResult_KeepsTheReplayFields(string file, ReplayVerdict expected)
    {
        var result = JsonSerializer.Deserialize<ReplayResult>(
            File.ReadAllText(Path.Combine(RepoRoot(), "client-godot", "tests", "fixtures", "golden", file)),
            RpgJson.Options)!;

        var verdict = new BattleVerdict(result.Verdict, result.ErrorCode, result.Error, result.Mismatch,
            result.Outcome, result.Turns, result.FinalStateHash, Ruleset, result.EngineVersion, Verified);

        Assert.Equal(expected, verdict.Status);
        Assert.Equal(expected == ReplayVerdict.Rejected ? ReplayErrors.ReplayMismatchCode : null, verdict.ErrorCode);
        Assert.Equal(result.FinalStateHash, verdict.FinalStateHash);
    }

    [Fact]
    public void RetryTiers_ChooseTheDelayByAttempt()
    {
        Assert.Equal(TimeSpan.FromSeconds(5), VerifyPolicy.TierForAttempt(1).Delay);
        Assert.Equal(TimeSpan.FromSeconds(30), VerifyPolicy.TierForAttempt(2).Delay);
        Assert.Equal(TimeSpan.FromSeconds(120), VerifyPolicy.TierForAttempt(3).Delay);
        Assert.Equal(TimeSpan.FromSeconds(120), VerifyPolicy.TierForAttempt(5).Delay);
        Assert.Equal(TimeSpan.FromSeconds(5), VerifyPolicy.TierForAttempt(0).Delay);
    }

    [Fact]
    public void ErrorCode2002_IsNotAnApiErrorCode()
    {
        var codes = typeof(ApiErrors).GetFields().Select(f => (int)f.GetRawConstantValue()!);

        Assert.DoesNotContain(ReplayErrors.ReplayMismatchCode, codes);
    }

    private static ReplayRequest ReadGodotRequest(string file) =>
        JsonSerializer.Deserialize<ReplayRequest>(
            File.ReadAllText(Path.Combine(RepoRoot(), "client-godot", "tests", "fixtures", "golden", file)),
            RpgJson.Options)!;

    private static string ReadGolden(string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "golden", name));

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Rpg.slnx")))
        {
            dir = dir.Parent;
        }

        return dir?.FullName ?? throw new InvalidOperationException("Rpg.slnx not found above the test output.");
    }
}
