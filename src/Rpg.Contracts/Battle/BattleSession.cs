namespace Rpg.Contracts.Battle;

/// <summary>GET /api/v1/runs/{runId}/battles/{seq} (spec server-authority 3.1, battle-verify 3.1): a battle as uploaded.</summary>
/// <param name="RunSeq">The seq of the run's <c>battle</c> action.</param>
/// <param name="Verdict">Null while the status is <see cref="BattleSessionStatus.Submitted"/>.</param>
public sealed record BattleSessionResponse(string BattleId, string RunId, int RunSeq, BattleSnapshot Conditions,
    ActionLog ActionLog, string RulesetVersion, BattleSessionStatus Status, DateTimeOffset SubmittedAt,
    BattleVerdict? Verdict = null);

/// <summary>Submitted until the verifier commits a verdict (slice 3); then Verified or Rejected, never back.</summary>
public enum BattleSessionStatus { Submitted, Verified, Rejected }
