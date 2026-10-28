namespace Rpg.Contracts.Runs;

/// <summary>POST /api/v1/runs/{runId}/floors/{floor}. AfterSeq (Part B): the client's last seq on the floor it's leaving.</summary>
public sealed record FloorSeedRequest(int? AfterSeq = null);

/// <summary>200. The same (runId, floor) always returns the same seed, so a retried request is free.</summary>
public sealed record FloorSeedResponse(string RunId, int Floor, string FloorSeed);
