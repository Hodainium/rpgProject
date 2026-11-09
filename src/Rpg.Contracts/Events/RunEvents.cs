using System.Text.Json.Serialization;
using Rpg.Contracts.Runs;

namespace Rpg.Contracts.Events;

// Spec run-verify 3.1. Payloads of DomainEvent<T>; topic rpg.run.events with the player id as key unless noted.

/// <summary>A floor's log is verified up to the <c>next_floor</c> that left it.</summary>
public sealed record FloorVerifiedPayload(string RunId, int Floor, int EndSeq, int Epoch);

/// <summary>A won run whose every step and link is verified.</summary>
public sealed record RunVerifiedPayload(string RunId, RunStatus Status, int Steps, int Floors);

/// <summary>
/// The verifier rolled a run back (or ended it: <paramref name="Terminal"/>). <paramref name="RejectedStepNo"/> is the
/// step that failed (-1 when the start itself disagreed with the anchor).
/// </summary>
public sealed record RunRolledBackPayload(string RunId, int Epoch, int RollbackToSeq, int RejectedStepNo,
    StepMismatchReason Reason, int VoidedActions, int VoidedBattles, bool Terminal);

/// <summary>Security topic <c>rpg.security.events</c>. <paramref name="Kind"/> is a small fixed set (the reason's category).</summary>
public sealed record AntiCheatAlertPayload(string RunId, string Kind, string Reason, int Seq);

/// <summary>Economy topic: gems written as pending; they reach the wallet only when released (then <c>RewardGranted</c>).</summary>
public sealed record RewardPendingPayload(string BattleId, string CharacterId, string ChallengeId, string CycleKey,
    int Amount, int RuleVersion);

/// <summary>Economy topic: pending gems voided by a rollback; the completion mark is freed.</summary>
public sealed record RewardVoidedPayload(string BattleId, string CharacterId, string ChallengeId, string CycleKey,
    int Amount, string Reason);
