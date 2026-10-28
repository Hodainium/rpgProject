using System.Text.Json;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Infrastructure;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.Runs;
using StackExchange.Redis;

namespace Rpg.GameServerApi.Battle;

/// <summary>
/// Cache-aside for battle sessions (spec server-authority 3.6): <c>battle:session:{runId}:{seq}</c> holds the
/// <c>BattleSessionResponse</c> and the run's owner, 30 min. Filled by reads only; a session doesn't change in 2b
/// (slice 3's verdict write deletes it). Any Redis error is counted and treated as a miss.
/// </summary>
public sealed class BattleSessionCache(RedisConnection redis, RpgMetrics metrics, ILogger<BattleSessionCache> logger)
{
    public static string Key(Guid runId, int seq) => $"battle:session:{runId:D}:{seq}";

    public async Task<StoredBattle?> GetAsync(Guid runId, int seq)
    {
        try
        {
            var value = await redis.Database().StringGetAsync(Key(runId, seq));
            return value.IsNullOrEmpty ? null : JsonSerializer.Deserialize<StoredBattle>(value.ToString(), RpgJson.Options);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("get");
            logger.LogDebug("Redis get of a battle session failed: {Message}", ex.Message);
            return null;
        }
    }

    public async Task SetAsync(Guid runId, int seq, StoredBattle battle)
    {
        try
        {
            await redis.Database().StringSetAsync(Key(runId, seq), JsonSerializer.Serialize(battle, RpgJson.Options),
                RunSummaryCache.Ttl);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("set");
            logger.LogDebug("Redis set of a battle session failed: {Message}", ex.Message);
        }
    }
}
