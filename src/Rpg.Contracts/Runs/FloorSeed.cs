namespace Rpg.Contracts.Runs;

/// <summary>POST /api/v1/runs/{runId}/floors/{floor}. AfterSeq (Part B): the client's last seq on the floor it's leaving.</summary>
/// <param name="Epoch">Spec run-verify 3.1: the epoch the client last saw; stale = 409 1108. Omitted when 0.</param>
public sealed record FloorSeedRequest(int? AfterSeq = null,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingDefault)] int Epoch = 0);

/// <summary>200. The same (runId, floor) always returns the same seed, so a retried request is free.</summary>
public sealed record FloorSeedResponse(string RunId, int Floor, string FloorSeed);
