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

    /// <summary>Spec settlement-outbox 3.5: the cached wallet; the worker deletes it after a settlement commits.</summary>
    public static string WalletKey(Guid playerId) => $"wallet:{playerId:D}";
}
