using System.Text.Json;
using System.Text.Json.Serialization;
using Rpg.Contracts.Battle;

namespace Rpg.Contracts.Runs;

// Spec run-verify 3.1. Wire shapes only: the server never interprets a snapshot, a floor digest or a step's actions.

/// <summary>
/// RabbitMQ message on <see cref="VerifyTopology.SegmentQueue"/>. Small on purpose: the worker reads the step, the run and
/// the claimed log from Postgres.
/// </summary>
public sealed record VerifyStepJob(Guid RunId, int Epoch, int StepNo, string RulesetVersion, DateTimeOffset CreatedAt);

/// <summary>A genesis step is made at run start (step 0); a battle step ends at a <c>battle</c> action; <c>end</c> at the win.</summary>
public enum StepKind { Genesis, Segment, Battle, End }

public enum StepStatus { Pending, Verified, Rejected, Voided }

/// <summary>What <c>step_main.tscn</c> reads (<c>--in</c>). Built by the worker from Postgres, never from the client.</summary>
/// <param name="FloorSeeds">The server's seeds (floor to decimal string), never the client's.</param>
/// <param name="StartSnapshot">Null for a genesis step (the job rebuilds the start).</param>
/// <param name="EndRunHash">The <c>RunEndRequest.RunHash</c> for an <c>end</c> step.</param>
public sealed record StepRequest(int SchemaVersion, string RunId, string RunStructureId,
    IReadOnlyList<string> CharacterIds, IReadOnlyDictionary<int, string> FloorSeeds, int FromSeq, int ToSeq,
    StepKind Kind, JsonElement? StartSnapshot, string? StartStateHash, IReadOnlyList<RunActionRequest> Actions,
    string? EndRunHash);

public enum StepMismatchReason
{
    /// <summary>The runner refused the request itself (exit 3).</summary>
    MalformedRequest,
    /// <summary>The restored start snapshot's hash is not the one claimed at <c>from_seq</c>.</summary>
    SnapshotHashMismatch,
    /// <summary>The snapshot's floor seeds are not the server's.</summary>
    ForeignSeed,
    /// <summary>The snapshot's run id, structure or party is not the run's.</summary>
    WrongSetup,
    /// <summary>The run refused an action (illegal, not in stock, no key, not adjacent …).</summary>
    ActionRefused,
    /// <summary>A battle's claimed conditions are not what the run state produces.</summary>
    ConditionsMismatch,
    /// <summary>A battle's replayed outcome or final hash differs from the claim.</summary>
    BattleMismatch,
    /// <summary>A claimed state hash differs from the replayed one.</summary>
    StateHashMismatch,
    /// <summary>An <c>end</c> that is not a win, or whose run hash differs.</summary>
    NotWon,
    /// <summary>Set by the aggregator: the client's seq 1 hash is not the server's anchor.</summary>
    GenesisMismatch,
    /// <summary>Set by the aggregator: a step's verified end is not the next step's start.</summary>
    LinkBroken,
}

public sealed record StepMismatch(StepMismatchReason Reason, int Seq, string Detail);

/// <summary>
/// <c>step_main</c>'s result and the stored verdict. The same error contract as battles: Rejected is 2002, never an
/// HTTP status.
/// </summary>
/// <param name="EndSnapshot">The rebuilt start state, genesis steps only.</param>
/// <param name="Battles">One replay result per battle the step contains (outcome, final hash, facts).</param>
/// <param name="FloorDigest">The floor read model, when the step entered a floor (opaque JSON owned by GDScript).</param>
public sealed record StepVerdict(ReplayVerdict Status, int? ErrorCode, string? Error, StepMismatch? Mismatch,
    string StartHash, string EndHash,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] JsonElement? EndSnapshot,
    IReadOnlyList<ReplayResult> Battles,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] JsonElement? FloorDigest,
    string VerifierRulesetVersion, string EngineVersion, DateTimeOffset VerifiedAt);

/// <summary>
/// GET /api/v1/runs/{runId}/floors/{floor}: the read model of a floor whose entering step is verified. <c>VerifiedAt</c> is
/// when the floor's whole log became verified (it leaves the floor), null while the player is still on it.
/// </summary>
public sealed record FloorDigestResponse(string RunId, int Floor, DateTimeOffset? VerifiedAt, JsonElement Digest);

/// <summary>GET /api/v1/runs/{runId}/steps (Development): the steps and their state, for tests and e2e.</summary>
public sealed record RunStepDto(int Epoch, int StepNo, int FromSeq, int ToSeq, StepKind Kind, StepStatus Status,
    string? Reason);
