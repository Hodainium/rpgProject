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

    /// <summary>A rollback voided these battles: tombstones first, then their session and verdict keys go (review fix).</summary>
    public async Task VoidAsync(Guid runId, IReadOnlyCollection<int> seqs)
    {
        try
        {
            foreach (var seq in seqs)
            {
                await redis.Database().StringSetAsync(VerifyPolicy.VoidedKey(runId, seq), "1", VerifyPolicy.VoidedTtl);
            }

            await redis.Database().KeyDeleteAsync(seqs.SelectMany(seq => new RedisKey[] { VerdictKey(runId, seq), Key(runId, seq) }).ToArray());
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("delete");
            logger.LogDebug("Redis void of battle sessions failed: {Message}", ex.Message);
        }
    }

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

    /// <summary>
    /// The refill, in one atomic step (review fix): nothing is written while the battle's tombstone exists (a rollback voided
    /// it after this reader loaded it from Postgres), nor a Submitted copy once the verdict is cached.
    /// </summary>
    private const string RefillScript = """
        if redis.call('EXISTS', KEYS[2]) == 1 then return 0 end
        if ARGV[3] == '1' and redis.call('EXISTS', KEYS[3]) == 1 then return 0 end
        redis.call('SET', KEYS[1], ARGV[1], 'PX', ARGV[2])
        return 1
        """;

    public async Task SetAsync(Guid runId, int seq, StoredBattle battle)
    {
        try
        {
            var submitted = battle.Session.Status == BattleSessionStatus.Submitted;
            await redis.Database().ScriptEvaluateAsync(RefillScript,
                [submitted ? Key(runId, seq) : VerdictKey(runId, seq), VerifyPolicy.VoidedKey(runId, seq), VerdictKey(runId, seq)],
                [JsonSerializer.Serialize(battle, RpgJson.Options),
                    (long)(submitted ? SubmittedTtl : RunSummaryCache.Ttl).TotalMilliseconds, submitted ? "1" : "0"]);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("set");
            logger.LogDebug("Redis set of a battle session failed: {Message}", ex.Message);
        }
    }
}
