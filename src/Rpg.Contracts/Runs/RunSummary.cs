namespace Rpg.Contracts.Runs;

/// <summary>GET /api/v1/runs/{runId} and GET /api/v1/runs/current (204 when the player has no active run).</summary>
public sealed record RunSummaryResponse(string RunId, RunStatus Status, int CurrentFloor, int LastSeq,
    string RulesetVersion, DateTimeOffset StartedAt, DateTimeOffset? EndedAt,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingDefault)] int Epoch = 0,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingDefault)] int VerifiedSeq = 0);   // spec run-verify 3.1

/// <summary>Rejected: a run the verifier ended (spec run-verify 2.4); Verifying with Part B's run end.</summary>
public enum RunStatus { Active, Verifying, Won, Lost, Abandoned, Rejected }
