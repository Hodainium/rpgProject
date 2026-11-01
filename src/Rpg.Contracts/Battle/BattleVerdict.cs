namespace Rpg.Contracts.Battle;

/// <summary>
/// The verifier's verdict on one battle (spec battle-verify 3.1): built from the runner's <see cref="ReplayResult"/>
/// plus the worker's ruleset version and the commit time. A rejection is a verdict with <c>ErrorCode</c> 2002, never an
/// HTTP error.
/// </summary>
/// <param name="Status">Verified or Rejected.</param>
/// <param name="ErrorCode">2002 when Rejected, otherwise null.</param>
/// <param name="Error">"ReplayMismatch" when Rejected, otherwise null.</param>
/// <param name="Mismatch">The first mismatch the replay detected when Rejected, otherwise null.</param>
/// <param name="Outcome">What the verifier's own simulation reached.</param>
public sealed record BattleVerdict(
    ReplayVerdict Status,
    int? ErrorCode,
    string? Error,
    ReplayMismatch? Mismatch,
    BattleOutcome Outcome,
    int Turns,
    string FinalStateHash,
    string VerifierRulesetVersion,
    string EngineVersion,
    DateTimeOffset VerifiedAt);
