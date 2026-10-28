using System.Text.Json;
using Rpg.Contracts.Auth;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Presence;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;

namespace Rpg.Contracts.Tests;

/// <summary>
/// Spec server-authority 6, contract tests for Part B: golden JSON for every new record (exact camelCase shape, byte
/// for byte, and round trip); a battle action's conditions bind the Godot v2 battle golden.
/// </summary>
public class RunAuthorityContractTests
{
    private const string RunId = "019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b";
    private const string Ruleset = "4.7.2.stable.mono+0123456789abcdef";
    private static readonly DateTimeOffset Played = new(2026, 10, 27, 12, 3, 4, TimeSpan.Zero);

    private static JsonElement Snapshot => JsonDocument.Parse("""{"schemaVersion":1,"floor":0}""").RootElement;

    private static BattleSubmission Battle()
    {
        var request = ReadV2Battle();
        return new BattleSubmission($"{RunId}/f0/c12", request.Snapshot with { BattleId = $"{RunId}/f0/c12" },
            request.ActionLog);
    }

    public static TheoryData<string, object> Goldens() => new()
    {
        {
            "run-action-batch.json", new RunActionBatch([
                new RunActionRequest(1, new RunAction(RunActionTypes.StartRun, 0, CoinsAfter: 0), "aa01", Played,
                    Snapshot),
                new RunActionRequest(2, new RunAction("enter_room", 0, Cell: 13, Unlock: "key", CoinsAfter: 5,
                    Offers: [new ItemOffer(0, "item.lucky_coin", 15, OfferSource.Shop),
                             new ItemOffer(1, "equipment.iron_helm", 0, OfferSource.Treasure, ItemKind.Equipment)]),
                    "aa02", Played),
                new RunActionRequest(3, new RunAction("buy", 0, Cell: 13, Placement: 0, ItemId: "item.lucky_coin",
                    Kind: ItemKind.Item, CharacterId: "warrior", Price: 15, CoinsAfter: 0), "aa03", Played),
            ])
        },
        { "run-action-ack.json", new RunActionAck(42) },
        { "run-end-request.json", new RunEndRequest(43, RunEndStatus.Won, "bb43", Snapshot) },
        { "run-end-response.json", new RunEndResponse(RunId, RunStatus.Verifying) },
        {
            "run-resume.json", new RunResumeResponse(RunId, RunStatus.Active,
                [new FloorSeedResponse(RunId, 0, "8070450532247928832"), new FloorSeedResponse(RunId, 1, "42")],
                5, Snapshot,
                [new RunActionRequest(6, new RunAction("choose", 1, Cell: 3, Page: 0, Choice: 1, CoinsAfter: 7),
                    "aa06", Played)])
        },
        { "presence-request.json", new PresenceRequest(PresenceActivity.Battle) },
        { "dev-token-request.json", new DevTokenRequest("alice") },
        {
            "dev-token-response.json", new DevTokenResponse("eyJhbGciOiJIUzI1NiJ9.e30.sig",
                new DateTimeOffset(2026, 10, 28, 0, 0, 0, TimeSpan.Zero), "8f0e7c2a-1b3d-8e4f-9a5b-6c7d8e9f0a1b")
        },
    };

    [Theory]
    [MemberData(nameof(Goldens))]
    public void PartBRecord_MatchesGoldenVector_ByteForByte(string file, object record)
    {
        Assert.Equal(ReadGolden(file), JsonSerializer.Serialize(record, record.GetType(), RpgJson.Options));
    }

    [Theory]
    [MemberData(nameof(Goldens))]
    public void PartBRecord_GoldenVector_RoundTrips(string file, object record)
    {
        var text = ReadGolden(file);

        var parsed = JsonSerializer.Deserialize(text, record.GetType(), RpgJson.Options)!;

        Assert.Equal(text, JsonSerializer.Serialize(parsed, record.GetType(), RpgJson.Options));
    }

    [Fact]
    public void BattleAction_ConditionsBindTheV2Golden_AndRoundTrip()
    {
        var action = new RunActionRequest(9, new RunAction(RunActionTypes.Battle, 0, Cell: 12, Battle: Battle()),
            "aa09", Played, Snapshot);

        var text = JsonSerializer.Serialize(action, RpgJson.Options);
        var parsed = JsonSerializer.Deserialize<RunActionRequest>(text, RpgJson.Options)!;

        Assert.Equal(text, JsonSerializer.Serialize(parsed, RpgJson.Options));
        Assert.Equal(2, parsed.Action.Battle!.Conditions.SchemaVersion);
        Assert.Equal(ReadV2Battle().Snapshot.Seed, parsed.Action.Battle.Conditions.Seed);
    }

    [Fact]
    public void BattleSession_RoundTrips()
    {
        var battle = Battle();
        var session = new BattleSessionResponse(battle.BattleId, RunId, 9, battle.Conditions, battle.ActionLog, Ruleset,
            BattleSessionStatus.Submitted, Played);

        var text = JsonSerializer.Serialize(session, RpgJson.Options);

        Assert.Equal(text, JsonSerializer.Serialize(
            JsonSerializer.Deserialize<BattleSessionResponse>(text, RpgJson.Options), RpgJson.Options));
        Assert.Contains("\"status\":\"Submitted\"", text);
    }

    [Fact]
    public void RunAction_OmitsUnusedFields()
    {
        var text = JsonSerializer.Serialize(new RunAction("next_floor", 2), RpgJson.Options);

        Assert.Equal("""{"type":"next_floor","floor":2}""", text);
    }

    [Fact]
    public void ActionTypes_IncludeEveryCheckpointType()
    {
        Assert.All(RunActionTypes.Checkpoints, type => Assert.Contains(type, RunActionTypes.All));
        Assert.Equal(RunActionTypes.All.Count, RunActionTypes.All.Distinct().Count());
    }

    private static ReplayRequest ReadV2Battle() =>
        JsonSerializer.Deserialize<ReplayRequest>(File.ReadAllText(Path.Combine(RepoRoot(), "client-godot", "tests",
            "fixtures", "golden", "run-v2-seed-7.json")), RpgJson.Options)!;

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
