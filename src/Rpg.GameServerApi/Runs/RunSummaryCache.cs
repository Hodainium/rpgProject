using System.Text.Json;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Infrastructure;
using Rpg.GameServerApi.Observability;
using StackExchange.Redis;

namespace Rpg.GameServerApi.Runs;

/// <summary>
/// Cache-aside read model for runs (spec server-authority 3.6, scenario 4). Writers commit to Postgres and then
/// <b>delete</b> the keys (never set them, so a slow writer can't leave a stale copy); readers fill them. Any Redis
/// error is counted and treated as a miss: correctness never depends on Redis.
/// <list type="bullet">
/// <item><c>run:summary:{runId}</c>: the run's summary and owner, 30 min.</item>
/// <item><c>run:current:{playerId}</c>: the player's Active or Verifying run id, 30 min.</item>
/// </list>
/// </summary>
public sealed class RunSummaryCache(RedisConnection redis, RpgMetrics metrics, ILogger<RunSummaryCache> logger)
{
    public static readonly TimeSpan Ttl = TimeSpan.FromMinutes(30);

    public static string SummaryKey(Guid runId) => $"run:summary:{runId:D}";

    public static string CurrentKey(Guid playerId) => $"run:current:{playerId:D}";

    public async Task<StoredRun?> GetSummaryAsync(Guid runId)
    {
        var value = await GetAsync(SummaryKey(runId));
        return value.IsNullOrEmpty ? null : JsonSerializer.Deserialize<StoredRun>(value.ToString(), RpgJson.Options);
    }

    public Task SetSummaryAsync(StoredRun run) =>
        SetAsync(SummaryKey(Guid.Parse(run.Summary.RunId)), JsonSerializer.Serialize(run, RpgJson.Options));

    public async Task<Guid?> GetCurrentAsync(Guid playerId)
    {
        var value = await GetAsync(CurrentKey(playerId));
        return Guid.TryParse(value.ToString(), out var runId) ? runId : null;
    }

    public Task SetCurrentAsync(Guid playerId, Guid runId) => SetAsync(CurrentKey(playerId), runId.ToString("D"));

    /// <summary>The write path's delete: failures are logged and counted, never thrown.</summary>
    public async Task InvalidateAsync(params string[] keys)
    {
        try
        {
            await Database().KeyDeleteAsync(keys.Select(key => (RedisKey)key).ToArray());
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("delete");
            logger.LogWarning("Redis delete of {Keys} failed: {Message}", string.Join(", ", keys), ex.Message);
        }
    }

    private async Task<RedisValue> GetAsync(string key)
    {
        try
        {
            return await Database().StringGetAsync(key);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("get");
            logger.LogDebug("Redis get of {Key} failed: {Message}", key, ex.Message);
            return RedisValue.Null;
        }
    }

    private async Task SetAsync(string key, string value)
    {
        try
        {
            await Database().StringSetAsync(key, value, Ttl);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("set");
            logger.LogDebug("Redis set of {Key} failed: {Message}", key, ex.Message);
        }
    }

    private IDatabase Database() => redis.Database();
}
