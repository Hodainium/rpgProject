using Rpg.Contracts.Battle;

namespace Rpg.Verification;

/// <summary>The retry policy and the Redis key formats the API and the verifier worker agree on (spec battle-verify 3.3, 3.4).</summary>
public static class VerifyPolicy
{
    /// <summary>The tier for the n-th failed attempt (1-based): 5 s, 30 s, then 120 s for attempt 3 and later.</summary>
    public static RetryTier TierForAttempt(int attempt) =>
        VerifyTopology.RetryTiers[Math.Clamp(attempt, 1, VerifyTopology.RetryTiers.Count) - 1];

    public static string SessionKey(Guid runId, int seq) => $"battle:session:{runId:D}:{seq}";

    public static string VerdictKey(Guid runId, int seq) => $"battle:verdict:{runId:D}:{seq}";

    /// <summary>
    /// Review fix: a rollback voided this battle (spec run-verify 2.4). Set with the deletion of its session and verdict keys
    /// and kept for <see cref="VoidedTtl"/>, it stops a reader that loaded the voided row from Postgres just before the
    /// rollback from caching it again afterwards (the cache refill writes only while no tombstone exists).
    /// </summary>
    public static string VoidedKey(Guid runId, int seq) => $"battle:voided:{runId:D}:{seq}";

    /// <summary>How long a tombstone lasts: far longer than one API read of a battle takes.</summary>
    public static readonly TimeSpan VoidedTtl = TimeSpan.FromMinutes(2);

    /// <summary>Spec settlement-outbox 3.5: the cached wallet; the worker deletes it after a settlement commits.</summary>
    public static string WalletKey(Guid playerId) => $"wallet:{playerId:D}";
}
