using System.Reflection;
using System.Text.Json;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Events;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;

namespace Rpg.Contracts.Tests;

/// <summary>
/// Spec run-verify 6, contract tests: the exact JSON of every new record, that the members added to existing records are
/// optional (old JSON still reads, defaults stay off the wire), and the names the Godot side must emit (pinned).
/// </summary>
public class RunVerifyContractTests
{
    private const string RunId = "019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b";
    private const string Ruleset = "4.7.2.stable.mono+0123456789abcdef";
    private static readonly DateTimeOffset At = new(2026, 11, 8, 12, 0, 0, TimeSpan.Zero);

    private static string Json(object value) => JsonSerializer.Serialize(value, value.GetType(), RpgJson.Options);

    private static T Read<T>(string json) => JsonSerializer.Deserialize<T>(json, RpgJson.Options)!;

    // ---- members added to existing records are optional -------------------------------------------------------------

    [Fact]
    public void TheNewMembers_StayOffTheWire_WhenDefault_SoOldJsonIsUnchanged()
    {
        Assert.Equal("""{"lastSeq":3}""", Json(new RunActionAck(3)));
        Assert.Equal("""{"actions":[]}""", Json(new RunActionBatch([])));
        Assert.Equal("""{"afterSeq":4}""", Json(new FloorSeedRequest(4)));
        Assert.DoesNotContain("epoch", Json(new RunSummaryResponse(RunId, RunStatus.Active, 0, 0, Ruleset, At, null)));
        Assert.DoesNotContain("verifiedSeq", Json(new RunSummaryResponse(RunId, RunStatus.Active, 0, 0, Ruleset, At, null)));
    }

    [Fact]
    public void TheNewMembers_AreWritten_WhenSet_AndOldJsonReadsAsZero()
    {
        Assert.Equal("""{"lastSeq":9,"epoch":2,"verifiedSeq":7}""", Json(new RunActionAck(9, 2, 7)));
        Assert.Equal("""{"afterSeq":4,"epoch":1}""", Json(new FloorSeedRequest(4, 1)));
        Assert.Equal((0, 0), (Read<RunActionAck>("""{"lastSeq":3}""").Epoch, Read<RunActionAck>("""{"lastSeq":3}""").VerifiedSeq));
        Assert.Equal(0, Read<RunActionBatch>("""{"actions":[]}""").Epoch);
        Assert.Equal(0, Read<FloorSeedRequest>("{}").Epoch);
        Assert.Equal(3, Read<RunActionBatch>("""{"actions":[],"epoch":3}""").Epoch);
    }

    [Fact]
    public void ALedgerRow_ShowsItsStatus_OnlyWhenNotReleased()
    {
        var released = new Rpg.Contracts.Economy.LedgerEntryDto("gems", 10, "completion_mark", "b1", At);
        var pending = released with { Status = "pending" };

        Assert.DoesNotContain("status", Json(released));
        Assert.Contains("\"status\":\"pending\"", Json(pending));
    }

    // ---- the new records, byte for byte -----------------------------------------------------------------------------

    [Fact]
    public void VerifyStepJob_Json_IsPinned()
    {
        var job = new VerifyStepJob(Guid.Parse(RunId), 2, 7, Ruleset, At);

        var json = Json(job);

        Assert.Equal($$"""{"runId":"{{RunId}}","epoch":2,"stepNo":7,"rulesetVersion":"{{Ruleset}}","createdAt":"2026-11-08T12:00:00+00:00"}""", json);
        Assert.Equal(job, Read<VerifyStepJob>(json));
    }

    [Fact]
    public void AGenesisStepRequest_HasNoSnapshotNoHashAndNoActions()
    {
        var request = new StepRequest(1, RunId, "descent", ["warrior"], new Dictionary<int, string> { [0] = "11" }, 0, 1,
            StepKind.Genesis, null, null, [], null);

        var json = Json(request);

        Assert.Equal($$"""{"schemaVersion":1,"runId":"{{RunId}}","runStructureId":"descent","characterIds":["warrior"],"floorSeeds":{"0":"11"},"fromSeq":0,"toSeq":1,"kind":"Genesis","startSnapshot":null,"startStateHash":null,"actions":[],"endRunHash":null}""", json);
        var parsed = Read<StepRequest>(json);
        Assert.Equal((StepKind.Genesis, null, null), (parsed.Kind, parsed.StartSnapshot, parsed.StartStateHash));
        Assert.Equal("11", parsed.FloorSeeds[0]);
    }

    [Fact]
    public void ARejectedStepVerdict_Json_IsPinned_AndRoundTrips()
    {
        var verdict = new StepVerdict(ReplayVerdict.Rejected, ReplayErrors.ReplayMismatchCode, ReplayErrors.ReplayMismatchName,
            new StepMismatch(StepMismatchReason.StateHashMismatch, 12, "claimed a, replayed b"), "s", "", null, [], null, Ruleset,
            "4.7.2.stable.mono.official", At);

        var json = Json(verdict);

        Assert.Equal($$"""{"status":"Rejected","errorCode":2002,"error":"ReplayMismatch","mismatch":{"reason":"StateHashMismatch","seq":12,"detail":"claimed a, replayed b"},"startHash":"s","endHash":"","battles":[],"verifierRulesetVersion":"{{Ruleset}}","engineVersion":"4.7.2.stable.mono.official","verifiedAt":"2026-11-08T12:00:00+00:00"}""", json);
        Assert.Equal(json, Json(Read<StepVerdict>(json)));   // records holding lists compare by reference, so compare the JSON
    }

    [Fact]
    public void AGenesisVerdict_CarriesTheRebuiltSnapshot_AndAFloorDigestIsOpaque()
    {
        var snapshot = JsonDocument.Parse("""{"schemaVersion":1,"party":[]}""").RootElement.Clone();
        var digest = JsonDocument.Parse("""{"floor":3,"floorHash":"abc","anything":[1,2]}""").RootElement.Clone();
        var verdict = new StepVerdict(ReplayVerdict.Verified, null, null, null, "", "g", snapshot, [], digest, Ruleset, "e", At);

        var parsed = Read<StepVerdict>(Json(verdict));

        Assert.Equal("""{"schemaVersion":1,"party":[]}""", parsed.EndSnapshot!.Value.GetRawText());
        Assert.Equal(3, parsed.FloorDigest!.Value.GetProperty("floor").GetInt32());   // the server reads "floor" and nothing else
    }

    [Fact]
    public void FloorDigestResponse_AndTheStepListing_ArePinned()
    {
        Assert.Equal($$$"""{"runId":"{{{RunId}}}","floor":2,"verifiedAt":"2026-11-08T12:00:00+00:00","digest":{"floorHash":"abc"}}""",
            Json(new FloorDigestResponse(RunId, 2, At, JsonDocument.Parse("""{"floorHash":"abc"}""").RootElement.Clone())));
        Assert.Equal("""{"epoch":0,"stepNo":3,"fromSeq":5,"toSeq":9,"kind":"Battle","status":"Rejected","reason":"ActionRefused"}""",
            Json(new RunStepDto(0, 3, 5, 9, StepKind.Battle, StepStatus.Rejected, "ActionRefused")));
    }

    [Fact]
    public void TheNewEventPayloads_ArePinned()
    {
        Assert.Equal($$"""{"runId":"{{RunId}}","floor":1,"endSeq":14,"epoch":0}""", Json(new FloorVerifiedPayload(RunId, 1, 14, 0)));
        Assert.Equal($$"""{"runId":"{{RunId}}","status":"Won","steps":21,"floors":10}""", Json(new RunVerifiedPayload(RunId, RunStatus.Won, 21, 10)));
        Assert.Equal($$"""{"runId":"{{RunId}}","epoch":1,"rollbackToSeq":9,"rejectedStepNo":4,"reason":"LinkBroken","voidedActions":6,"voidedBattles":1,"terminal":false}""",
            Json(new RunRolledBackPayload(RunId, 1, 9, 4, StepMismatchReason.LinkBroken, 6, 1, false)));
        Assert.Equal($$"""{"runId":"{{RunId}}","kind":"StateMismatch","reason":"StateHashMismatch","seq":12}""",
            Json(new AntiCheatAlertPayload(RunId, "StateMismatch", "StateHashMismatch", 12)));
        Assert.Equal("""{"battleId":"b1","characterId":"warrior","challengeId":"boss/lich","cycleKey":"once","amount":10,"ruleVersion":1}""",
            Json(new RewardPendingPayload("b1", "warrior", "boss/lich", "once", 10, 1)));
        Assert.Equal("""{"battleId":"b1","characterId":"warrior","challengeId":"boss/lich","cycleKey":"once","amount":10,"reason":"LinkBroken"}""",
            Json(new RewardVoidedPayload("b1", "warrior", "boss/lich", "once", 10, "LinkBroken")));
    }

    // ---- names the Godot side must emit, and the codes clients switch on --------------------------------------------

    [Fact]
    public void StepMismatchReasons_StepKinds_AndStatuses_ArePinned()
    {
        Assert.Equal(
            ["MalformedRequest", "SnapshotHashMismatch", "ForeignSeed", "WrongSetup", "ActionRefused", "ConditionsMismatch",
             "BattleMismatch", "StateHashMismatch", "NotWon", "GenesisMismatch", "LinkBroken"],
            Enum.GetNames<StepMismatchReason>());
        Assert.Equal(["Genesis", "Segment", "Battle", "End"], Enum.GetNames<StepKind>());
        Assert.Equal(["Pending", "Verified", "Rejected", "Voided"], Enum.GetNames<StepStatus>());
    }

    [Fact]
    public void TheNewApiErrors_AreThe1107And1108ClientsSwitchOn()
    {
        Assert.Equal((1107, 1108), (ApiErrors.PreviousFloorUnverified, ApiErrors.RunRolledBack));
        var codes = typeof(ApiErrors).GetFields(BindingFlags.Public | BindingFlags.Static)
            .Where(field => field.IsLiteral).Select(field => (int)field.GetRawConstantValue()!).ToList();
        Assert.DoesNotContain(ReplayErrors.ReplayMismatchCode, codes);
    }

    [Fact]
    public void TheSegmentTopology_IsPinned()
    {
        Assert.Equal(("verify.segment", "verify.segment.dlq", "segment", "dead.segment"),
            (VerifyTopology.SegmentQueue, VerifyTopology.SegmentDeadLetterQueue, VerifyTopology.SegmentRoutingKey,
             VerifyTopology.SegmentDeadRoutingKey));
        Assert.Equal([5, 30, 120], VerifyTopology.SegmentRetryTiers.Select(t => (int)t.Delay.TotalSeconds));
        Assert.All(VerifyTopology.SegmentRetryTiers, t => Assert.StartsWith("verify.segment.retry.", t.Queue));
        Assert.Equal("rpg.run.events", EventTopics.Run);
        Assert.Equal("rpg.security.events", EventTopics.Security);
    }
}
