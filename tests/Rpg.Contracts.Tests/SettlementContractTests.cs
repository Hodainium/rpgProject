using System.Text.Json;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Economy;
using Rpg.Contracts.Events;
using Rpg.Contracts.Serialization;

namespace Rpg.Contracts.Tests;

/// <summary>Spec settlement-outbox 6: golden JSON for the event envelope, its payloads, the facts and the wallet.</summary>
public class SettlementContractTests
{
    private const string RunId = "019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b";
    private const string Ruleset = "4.7.2.stable.mono+0123456789abcdef";
    private const string FinalHash = "c49f208156b68a88c33a52bec13928b9b8184bd261dfb3a6828a1dd57bc0fc3d";
    private static readonly Guid Player = Guid.Parse("019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a01");
    private static readonly Guid EventId = Guid.Parse("019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a10");
    private static readonly DateTimeOffset At = new(2026, 10, 27, 12, 3, 9, TimeSpan.Zero);
    private static readonly BattleFacts Facts = new("encounter.lich", ["enemy.lich"], ["warrior", "cleric"]);

    private static readonly RewardRuleResponse Rule = new("boss", "enemy.lich", "gems", 25, 3, At, "designer");

    public static TheoryData<string, object> Goldens() => new()
    {
        {
            "event-battle-verified.json",
            new DomainEvent<BattleVerifiedPayload>(EventId, EventTypes.BattleVerified, 1, Player, Guid.Parse(RunId), At,
                Ruleset, new BattleVerifiedPayload($"{RunId}/f4/c12", 9, BattleOutcome.Victory, 27, FinalHash, "encounter.lich"))
        },
        {
            "event-battle-rejected.json",
            new DomainEvent<BattleRejectedPayload>(EventId, EventTypes.BattleRejected, 1, Player, Guid.Parse(RunId), At,
                Ruleset, new BattleRejectedPayload($"{RunId}/f4/c12", 9, ReplayErrors.ReplayMismatchCode,
                    MismatchReason.FinalHashMismatch))
        },
        {
            "event-reward-granted.json",
            new DomainEvent<RewardGrantedPayload>(EventId, EventTypes.RewardGranted, 1, Player, Guid.Parse(RunId), At,
                Ruleset, new RewardGrantedPayload("completion_mark", $"{RunId}/f4/c12", "warrior", "enemy.lich", "gems", 10, 30, 2))
        },
        { "battle-facts.json", Facts },
        { "reward-rule-request.json", new RewardRuleRequest(RewardSourceKinds.Boss, "enemy.lich", "gems", 25) },
        { "reward-rule-response.json", Rule },
        { "reward-rule-list-response.json", new RewardRuleListResponse([Rule]) },
        { "reward-rule-changed.json", new RewardRuleChangedPayload("boss", "enemy.lich", "gems", 25, 3, 10, "designer") },
        {
            "wallet-response.json",
            new WalletResponse(30, 3, [new LedgerEntryDto("gems", 10, "completion_mark", $"{RunId}/f4/c12", At, 2)])
        },
        {
            "battle-verdict-verified-facts.json",
            new BattleVerdict(ReplayVerdict.Verified, null, null, null, BattleOutcome.Victory, 27, FinalHash, Ruleset,
                "4.7.2.stable.mono.official.ed1daf0bf", At, Facts)
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
    public void ALedgerRowFromBeforeSlice4c_HasNoRuleVersion()
    {
        var parsed = JsonSerializer.Deserialize<LedgerEntryDto>(
            """{"currency":"gems","delta":10,"reason":"completion_mark","at":"2026-10-27T12:03:09+00:00"}""", RpgJson.Options)!;

        Assert.Null(parsed.RuleVersion);
    }

    [Fact]
    public void Verdict_WithoutFacts_WritesNoFactsField_AndOldJsonStillReads()
    {
        var old = ReadGolden("battle-verdict-verified.json");  // the slice 3 golden, unchanged

        var parsed = JsonSerializer.Deserialize<BattleVerdict>(old, RpgJson.Options)!;

        Assert.Null(parsed.Facts);
        Assert.Equal(old, JsonSerializer.Serialize(parsed, RpgJson.Options));  // additive: old goldens do not change
        Assert.DoesNotContain("facts", old);
    }

    [Fact]
    public void ReplayResult_FromAnOlderRunner_HasNoFacts()
    {
        var text = File.ReadAllText(Path.Combine(RepoRoot(), "client-godot", "tests", "fixtures", "golden", "run-v2-seed-7.result.json"));

        var result = JsonSerializer.Deserialize<ReplayResult>(text, RpgJson.Options)!;

        Assert.Null(result.Facts);
    }

    [Fact]
    public void EventTypes_AndTopics_AreAFixedSet()
    {
        Assert.Equal(["BattleVerified", "BattleRejected", "RewardGranted", "RewardRuleChanged"],
            new[] { EventTypes.BattleVerified, EventTypes.BattleRejected, EventTypes.RewardGranted, EventTypes.RewardRuleChanged });
        Assert.Equal(["rpg.battle.events", "rpg.economy.events"], new[] { EventTopics.Battle, EventTopics.Economy });
    }

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
