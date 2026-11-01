using System.Text.Json;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Infrastructure;
using Rpg.Contracts.Battle;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.Runs;
using Rpg.Verification;
using StackExchange.Redis;

namespace Rpg.GameServerApi.Battle;

/// <summary>
/// Cache-aside for battle sessions (spec server-authority 3.6, battle-verify 3.4): <c>battle:session:{runId}:{seq}</c>
/// holds a Submitted session and the run's owner for 10 s (so polling sees a verdict soon after it lands);
/// <c>battle:verdict:{runId}:{seq}</c> holds a Verified or Rejected one for 30 min. Reads fill both; the verifier worker
/// fills the verdict key and deletes the session key after its commit. Any Redis error is counted and treated as a miss.
/// </summary>
public sealed class BattleSessionCache(RedisConnection redis, RpgMetrics metrics, ILogger<BattleSessionCache> logger)
{
    public static readonly TimeSpan SubmittedTtl = TimeSpan.FromSeconds(10);

    public static string Key(Guid runId, int seq) => VerifyPolicy.SessionKey(runId, seq);

    public static string VerdictKey(Guid runId, int seq) => VerifyPolicy.VerdictKey(runId, seq);

    /// <summary>The cached battle (verdict key first), and which key answered.</summary>
    public async Task<(StoredBattle? Battle, string Source)> GetAsync(Guid runId, int seq)
    {
        try
        {
            // Both keys in one round trip; the verdict wins when both exist.
            var values = await redis.Database().StringGetAsync([VerdictKey(runId, seq), Key(runId, seq)]);
            if (!values[0].IsNullOrEmpty)
            {
                return (JsonSerializer.Deserialize<StoredBattle>(values[0].ToString(), RpgJson.Options), "redis_verdict");
            }

            return values[1].IsNullOrEmpty
                ? (null, "")
                : (JsonSerializer.Deserialize<StoredBattle>(values[1].ToString(), RpgJson.Options), "redis");
        }
        catch (Exception ex) when (RedisConnection.IsError(ex) || ex is JsonException)
        {
            // An entry written by another build (the worker is deployed separately) or a corrupt one is a miss: Postgres
            // answers, and the next fill replaces the entry.
            metrics.CacheError("get");
            logger.LogDebug("Redis get of a battle session failed: {Message}", ex.Message);
            return (null, "");
        }
    }

    public async Task SetAsync(Guid runId, int seq, StoredBattle battle)
    {
        try
        {
            var submitted = battle.Session.Status == BattleSessionStatus.Submitted;
            if (submitted && await redis.Database().KeyExistsAsync(VerdictKey(runId, seq)))
            {
                return;  // the verdict landed while this reader held a Submitted copy: do not bring it back
            }

            await redis.Database().StringSetAsync(submitted ? Key(runId, seq) : VerdictKey(runId, seq),
                JsonSerializer.Serialize(battle, RpgJson.Options), submitted ? SubmittedTtl : RunSummaryCache.Ttl);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("set");
            logger.LogDebug("Redis set of a battle session failed: {Message}", ex.Message);
        }
    }
}
