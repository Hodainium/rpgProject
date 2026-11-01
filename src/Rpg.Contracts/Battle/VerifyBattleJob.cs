namespace Rpg.Contracts.Battle;

/// <summary>
/// RabbitMQ message on <see cref="VerifyTopology.Queue"/> (spec battle-verify 3.1). Small on purpose: the worker reads
/// the conditions and the action log from Postgres.
/// </summary>
public sealed record VerifyBattleJob(string BattleId, Guid RunId, int RunSeq, string RulesetVersion,
    DateTimeOffset SubmittedAt);

/// <summary>
/// Wire names shared by the API (publisher, sweeper) and the verifier worker (spec battle-verify 3.3): exchange, queue,
/// header names and the retry tiers as data. Behaviour (which tier, the Redis keys) is <c>Rpg.Verification.VerifyPolicy</c>.
/// </summary>
public static class VerifyTopology
{
    public const string Exchange = "rpg.verify";
    public const string DeadLetterExchange = "rpg.verify.dlx";
    public const string RoutingKey = "battle";
    public const string DeadRoutingKey = "dead";

    public const string Queue = "verify.battle";
    public const string DeadLetterQueue = "verify.battle.dlq";

    /// <summary>The retry queues, shortest delay first; each one's message TTL is its delay.</summary>
    public static readonly IReadOnlyList<RetryTier> RetryTiers =
    [
        new("verify.battle.retry.5s", "retry.5s", TimeSpan.FromSeconds(5)),
        new("verify.battle.retry.30s", "retry.30s", TimeSpan.FromSeconds(30)),
        new("verify.battle.retry.120s", "retry.120s", TimeSpan.FromSeconds(120)),
    ];

    /// <summary>Header: how many runner errors this job has had (int, default 0).</summary>
    public const string AttemptHeader = "x-attempt";

    /// <summary>Header on dead-lettered messages: why (ruleset, poison, attempts).</summary>
    public const string ReasonHeader = "x-reason";

}

/// <param name="Queue">Queue name.</param>
/// <param name="RoutingKey">Binding key on <see cref="VerifyTopology.Exchange"/>.</param>
/// <param name="Delay">Message TTL of the queue.</param>
public sealed record RetryTier(string Queue, string RoutingKey, TimeSpan Delay);
