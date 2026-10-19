namespace Rpg.Contracts.Battle;

/// <summary>Produced by the client's ActionRecorder. Only party decisions; enemy turns are re-derived by the replay.</summary>
/// <param name="SchemaVersion">Currently 1.</param>
/// <param name="ClaimedFinalHash">Lowercase hex SHA-256 of the final state (state hash v1).</param>
public sealed record ActionLog(
    int SchemaVersion,
    IReadOnlyList<ActionEntry> Actions,
    BattleOutcome ClaimedOutcome,
    string ClaimedFinalHash);

/// <param name="Turn">Global turn index (1-based) at which this party unit acted.</param>
/// <param name="Actor">Unit id assigned by the battle, "P1".."P4".</param>
/// <param name="Ability">The BattleAbility's ability tag.</param>
/// <param name="Target">Primary target unit id ("E1", "P2"), or null for SELF / ALL_* abilities.</param>
/// <param name="Checkpoint">State hash at the end of this turn.</param>
public sealed record ActionEntry(int Turn, string Actor, string Ability, string? Target, string Checkpoint);

/// <summary>Input of the headless replay runner (slice 3 hands this to the verifier).</summary>
public sealed record ReplayRequest(BattleSnapshot Snapshot, ActionLog ActionLog);
