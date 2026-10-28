using System.Text.Json;

namespace Rpg.Contracts.Runs;

/// <summary>
/// GET /api/v1/runs/{runId}/resume (spec server-authority 2.4): every issued floor seed, the latest checkpoint
/// snapshot (seq ≤ lastSeq) and the accepted actions after it, which the client replays locally. Before any
/// checkpoint is stored, <c>CheckpointSeq</c> is 0, <c>Snapshot</c> is JSON null and the tail is everything stored.
/// </summary>
public sealed record RunResumeResponse(string RunId, RunStatus Status, IReadOnlyList<FloorSeedResponse> FloorSeeds,
    int CheckpointSeq, JsonElement Snapshot, IReadOnlyList<RunActionRequest> Tail);
