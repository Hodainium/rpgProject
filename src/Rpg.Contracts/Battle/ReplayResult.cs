using System.Text.Json.Serialization;

namespace Rpg.Contracts.Battle;

/// <summary>Output of the headless replay runner.</summary>
/// <param name="SchemaVersion">Currently 1.</param>
/// <param name="ErrorCode">2002 when Rejected (see <see cref="ReplayErrors"/>), otherwise null.</param>
/// <param name="Error">"ReplayMismatch" when Rejected, otherwise null.</param>
/// <param name="Mismatch">The first mismatch the replay detected when Rejected, otherwise null.</param>
/// <param name="Outcome">What the verifier's own simulation reached.</param>
/// <param name="EngineVersion">Godot version string of the runner, e.g. "4.7.2.stable.mono.official".</param>
/// <param name="Facts">Spec settlement-outbox 3.1: what the replay learned from content (encounter, bosses, party). Null
/// from a runner that predates it; omitted from the JSON when null, so older goldens read and write unchanged.</param>
public sealed record ReplayResult(
    int SchemaVersion,
    string BattleId,
    ReplayVerdict Verdict,
    int? ErrorCode,
    string? Error,
    ReplayMismatch? Mismatch,
    BattleOutcome Outcome,
    int Turns,
    string FinalStateHash,
    string EngineVersion,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] BattleFacts? Facts = null);

/// <param name="Turn">The simulated turn at which the replay detected the mismatch (not necessarily where the log
/// diverged: a legal tamper can surface turns later; spec atomic-battles).</param>
public sealed record ReplayMismatch(MismatchReason Reason, int Turn, string Detail);

/// <summary>The error contract from the root CLAUDE.md: a replay mismatch is a verdict, always code 2002.</summary>
public static class ReplayErrors
{
    public const int ReplayMismatchCode = 2002;
    public const string ReplayMismatchName = "ReplayMismatch";
}

public enum ReplayVerdict { Verified, Rejected }

/// <summary>
/// Ongoing appears only in a rejected ReplayResult, when the replay stopped at a mismatch before the battle ended.
/// </summary>
public enum BattleOutcome { Victory, Defeat, TurnLimit, Ongoing }

public enum MismatchReason
{
    /// <summary>The next entry's turn isn't the simulated turn of the next party action.</summary>
    TurnMismatch,
    /// <summary>The entry's actor isn't the unit whose turn it is.</summary>
    ActorMismatch,
    /// <summary>Not granted to that unit, or it can't activate (cost, cooldown, tags).</summary>
    IllegalAbility,
    /// <summary>Missing, dead, wrong side, or not allowed for the ability's targeting.</summary>
    InvalidTarget,
    /// <summary>A party unit needs to act but the log has no entries left.</summary>
    LogExhausted,
    /// <summary>The battle ended with entries left in the log.</summary>
    TrailingActions,
    /// <summary>The claimed outcome differs from the simulated outcome.</summary>
    OutcomeMismatch,
    /// <summary>The claimed final hash differs from the simulated one.</summary>
    FinalHashMismatch,
    /// <summary>The simulation hit the 1000-turn limit.</summary>
    TurnLimitExceeded,
    /// <summary>Spec run-verify 3.1: the runner refused the request itself (unknown content id, bad schema version, unknown
    /// field). Exit code 3; a Rejected verdict at once, never retried (closes battle-verify 8.1).</summary>
    MalformedRequest,
}
