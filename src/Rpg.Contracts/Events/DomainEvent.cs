using Rpg.Contracts.Battle;

namespace Rpg.Contracts.Events;

/// <summary>
/// The envelope of every event on Redpanda (spec settlement-outbox 3.1). The envelope never changes shape; payloads are
/// versioned by <paramref name="SchemaVersion"/>. Consumers dedupe on <paramref name="EventId"/> (the outbox row id) and
/// order by <paramref name="OccurredAt"/>, never by arrival.
/// </summary>
/// <param name="EventId">The outbox row id.</param>
/// <param name="Type">One of <see cref="EventTypes"/>.</param>
/// <param name="OccurredAt">The commit time, not the publish time.</param>
public sealed record DomainEvent<TPayload>(
    Guid EventId,
    string Type,
    int SchemaVersion,
    Guid PlayerId,
    Guid? RunId,
    DateTimeOffset OccurredAt,
    string RulesetVersion,
    TPayload Payload);

public static class EventTypes
{
    public const string BattleVerified = "BattleVerified";
    public const string BattleRejected = "BattleRejected";
    public const string RewardGranted = "RewardGranted";
}

/// <summary>Redpanda topic names (data only).</summary>
public static class EventTopics
{
    public const string Battle = "rpg.battle.events";
    public const string Economy = "rpg.economy.events";
}

public sealed record BattleVerifiedPayload(string BattleId, int RunSeq, BattleOutcome Outcome, int Turns,
    string FinalStateHash, string? EncounterId);

/// <param name="ErrorCode">Always 2002.</param>
public sealed record BattleRejectedPayload(string BattleId, int RunSeq, int ErrorCode, MismatchReason? Reason);

/// <param name="Source">"completion_mark".</param>
/// <param name="Currency">"gems".</param>
public sealed record RewardGrantedPayload(string Source, string BattleId, string CharacterId, string BossId,
    string Currency, int Amount, int BalanceAfter);
