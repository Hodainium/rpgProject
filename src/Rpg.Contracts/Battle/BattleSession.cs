namespace Rpg.Contracts.Battle;

/// <summary>GET /api/v1/runs/{runId}/battles/{seq} (spec server-authority 3.1): a battle as uploaded.</summary>
/// <param name="RunSeq">The seq of the run's <c>battle</c> action.</param>
public sealed record BattleSessionResponse(string BattleId, string RunId, int RunSeq, BattleSnapshot Conditions,
    ActionLog ActionLog, string RulesetVersion, BattleSessionStatus Status, DateTimeOffset SubmittedAt);

/// <summary>Slice 3 adds Verified and Rejected.</summary>
public enum BattleSessionStatus { Submitted }
