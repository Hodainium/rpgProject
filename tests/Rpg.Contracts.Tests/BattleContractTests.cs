using System.Text.Json;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Serialization;

namespace Rpg.Contracts.Tests;

/// <summary>
/// Wire shape of the battle contracts (spec combat-replay-core, section 3.2): field names, enum spelling, the seed as a
/// string and the 2002 error contract. The Godot-produced golden files are cross-checked in BattleGoldenTests.
/// </summary>
public class BattleContractTests
{
    private static readonly ReplayRequest SampleRequest = new(
        new BattleSnapshot(1, "b-1", "9223372036854775807", "fixture.encounter.duel",
            [new PartyMemberSnapshot(1, "fixture.unit.striker", 1)]),
        new ActionLog(1,
            [new ActionEntry(1, "P1", "Fixture.Ability.Strike", "E1", "ab12"),
             new ActionEntry(3, "P1", "Fixture.Ability.Guard", null, "cd34")],
            BattleOutcome.Victory,
            "ef56"));

    private const string SampleRequestJson =
        """{"snapshot":{"schemaVersion":1,"battleId":"b-1","seed":"9223372036854775807","encounterId":"fixture.encounter.duel","party":[{"slot":1,"unitDefId":"fixture.unit.striker","level":1}]},"actionLog":{"schemaVersion":1,"actions":[{"turn":1,"actor":"P1","ability":"Fixture.Ability.Strike","target":"E1","checkpoint":"ab12"},{"turn":3,"actor":"P1","ability":"Fixture.Ability.Guard","target":null,"checkpoint":"cd34"}],"claimedOutcome":"Victory","claimedFinalHash":"ef56"}}""";

    [Fact]
    public void ReplayRequest_SerializesToTheSpecShape()
    {
        Assert.Equal(SampleRequestJson, JsonSerializer.Serialize(SampleRequest, RpgJson.Options));
    }

    [Fact]
    public void ReplayRequest_RoundTrips_WithSeedAsString()
    {
        var parsed = JsonSerializer.Deserialize<ReplayRequest>(SampleRequestJson, RpgJson.Options)!;

        Assert.Equal("9223372036854775807", parsed.Snapshot.Seed);
        Assert.Null(parsed.ActionLog.Actions[1].Target);
        Assert.Equal(SampleRequestJson, JsonSerializer.Serialize(parsed, RpgJson.Options));
    }

    [Fact]
    public void SnapshotV1_OmitsEveryV2Field()
    {
        var json = JsonSerializer.Serialize(SampleRequest.Snapshot, RpgJson.Options);

        Assert.Equal(
            """{"schemaVersion":1,"battleId":"b-1","seed":"9223372036854775807","encounterId":"fixture.encounter.duel","party":[{"slot":1,"unitDefId":"fixture.unit.striker","level":1}]}""",
            json);
    }

    [Fact]
    public void SnapshotV2_SerializesToTheSpecShape_AndRoundTrips()
    {
        var snapshot = new BattleSnapshot(2, "run-1/f0/c40", "42", "fixture.encounter.duel",
            [new PartyMemberSnapshot(1, "fixture.character.striker", 1, Hp: 0, Mp: 5000, Energy: 2000,
                Skills: ["Fixture.Ability.Heal"], EquipmentIds: ["fixture.equipment.blade"],
                Items: ["fixture.item.whetstone"], UseSlots: [new UseSlotSnapshot("fixture.item.revive", false)])],
            Enemies: [new EnemySnapshot(1, "fixture.enemy.brute", "fixture.encounter.duel#1", null)],
            ScalingId: "fixture.scaling.a",
            Depth: 1);
        const string expected =
            """{"schemaVersion":2,"battleId":"run-1/f0/c40","seed":"42","encounterId":"fixture.encounter.duel","party":[{"slot":1,"unitDefId":"fixture.character.striker","level":1,"hp":0,"mp":5000,"energy":2000,"skills":["Fixture.Ability.Heal"],"equipmentIds":["fixture.equipment.blade"],"items":["fixture.item.whetstone"],"useSlots":[{"itemId":"fixture.item.revive","ready":false}]}],"enemies":[{"slot":1,"unitDefId":"fixture.enemy.brute","loadoutRef":"fixture.encounter.duel#1","variantId":null}],"scalingId":"fixture.scaling.a","depth":1}""";

        Assert.Equal(expected, JsonSerializer.Serialize(snapshot, RpgJson.Options));
        var parsed = JsonSerializer.Deserialize<BattleSnapshot>(expected, RpgJson.Options)!;
        Assert.Equal(0, parsed.Party[0].Hp);
        Assert.Equal(expected, JsonSerializer.Serialize(parsed, RpgJson.Options));
    }

    [Fact]
    public void ActionEntry_WritesExtraOnlyForOneMore()
    {
        var oneMore = new ActionEntry(4, "P1", "Fixture.Ability.Strike", "E2", "ab12", Extra: true);
        const string expected =
            """{"turn":4,"actor":"P1","ability":"Fixture.Ability.Strike","target":"E2","checkpoint":"ab12","extra":true}""";

        Assert.Equal(expected, JsonSerializer.Serialize(oneMore, RpgJson.Options));
        Assert.True(JsonSerializer.Deserialize<ActionEntry>(expected, RpgJson.Options)!.Extra);
        Assert.DoesNotContain("extra", JsonSerializer.Serialize(SampleRequest.ActionLog, RpgJson.Options));
    }

    [Fact]
    public void ActionEntry_WritesInterruptOnlyForOutOfTurnUlts()
    {
        var ult = new ActionEntry(3, "P1", "Fixture.Ability.UltNova", null, "ab12", Interrupt: true);
        const string expected =
            """{"turn":3,"actor":"P1","ability":"Fixture.Ability.UltNova","target":null,"checkpoint":"ab12","interrupt":true}""";

        Assert.Equal(expected, JsonSerializer.Serialize(ult, RpgJson.Options));
        var parsed = JsonSerializer.Deserialize<ActionEntry>(expected, RpgJson.Options)!;
        Assert.True(parsed.Interrupt);
        Assert.Null(parsed.Extra);
        Assert.Equal(expected, JsonSerializer.Serialize(parsed, RpgJson.Options));
        Assert.DoesNotContain("interrupt", JsonSerializer.Serialize(SampleRequest.ActionLog, RpgJson.Options));
    }

    [Fact]
    public void SnapshotV1Json_BindsWithV2FieldsNull()
    {
        var parsed = JsonSerializer.Deserialize<ReplayRequest>(SampleRequestJson, RpgJson.Options)!;

        Assert.Null(parsed.Snapshot.Enemies);
        Assert.Null(parsed.Snapshot.Depth);
        Assert.Null(parsed.Snapshot.Party[0].Hp);
        Assert.Null(parsed.Snapshot.Party[0].Items);
        Assert.Null(parsed.Snapshot.Party[0].UseSlots);
    }

    [Fact]
    public void RejectedResult_CarriesErrorCode2002_AndReasonAsString()
    {
        var result = new ReplayResult(1, "b-1", ReplayVerdict.Rejected, ReplayErrors.ReplayMismatchCode,
            ReplayErrors.ReplayMismatchName, new ReplayMismatch(MismatchReason.CheckpointMismatch, 7, "detail"),
            BattleOutcome.Victory, 12, "ab12", "4.7.2.stable.mono.official");

        Assert.Equal(
            """{"schemaVersion":1,"battleId":"b-1","verdict":"Rejected","errorCode":2002,"error":"ReplayMismatch","mismatch":{"reason":"CheckpointMismatch","turn":7,"detail":"detail"},"outcome":"Victory","turns":12,"finalStateHash":"ab12","engineVersion":"4.7.2.stable.mono.official"}""",
            JsonSerializer.Serialize(result, RpgJson.Options));
    }

    [Fact]
    public void VerifiedResult_WritesNullsExplicitly()
    {
        var result = new ReplayResult(1, "b-1", ReplayVerdict.Verified, null, null, null, BattleOutcome.Defeat, 3,
            "ab12", "4.7.2.stable.mono.official");

        var json = JsonSerializer.Serialize(result, RpgJson.Options);

        Assert.Contains("\"errorCode\":null,\"error\":null,\"mismatch\":null", json);
    }
}
