using System.Text.Json.Serialization;

namespace Rpg.Contracts.Battle;

/// <summary>Produced by the client's ActionRecorder. Only party decisions; enemy turns are re-derived by the replay.
/// A battle is verified as one unit (spec atomic-battles): entries carry no per-action state hash.</summary>
/// <param name="SchemaVersion">Currently 2 (v2 dropped the per-entry checkpoint; the verifier reads v2 only).</param>
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
/// <param name="Extra">True for a One More action (spec item-pass 3.2: the actor broke a unit and acts again);
/// omitted otherwise, so logs without one are unchanged.</param>
/// <param name="Interrupt">True for a party ult cast out of turn (spec ult-interrupts): <c>Turn</c> is then the turn of
/// its window, <c>Actor</c> the caster and <c>Target</c> the target actually used. Omitted otherwise.</param>
public sealed record ActionEntry(
    int Turn,
    string Actor,
    string Ability,
    string? Target,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? Extra = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? Interrupt = null);

/// <summary>Input of the headless replay runner (slice 3 hands this to the verifier).</summary>
public sealed record ReplayRequest(BattleSnapshot Snapshot, ActionLog ActionLog);
