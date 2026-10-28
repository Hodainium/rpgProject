namespace Rpg.Contracts.Runs;

/// <summary>GET /api/v1/runs/{runId} and GET /api/v1/runs/current (204 when the player has no active run).</summary>
public sealed record RunSummaryResponse(string RunId, RunStatus Status, int CurrentFloor, int LastSeq,
    string RulesetVersion, DateTimeOffset StartedAt, DateTimeOffset? EndedAt);

/// <summary>Rejected arrives with slice 4a; Verifying with Part B's run end.</summary>
public enum RunStatus { Active, Verifying, Won, Lost, Abandoned, Rejected }
