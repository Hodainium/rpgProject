using System.Text.Json;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Infrastructure;
using Rpg.GameServerApi.Observability;

namespace Rpg.GameServerApi.Cards;

/// <summary>
/// Cache-aside for the two catalog reads (spec card-collection 3.3): <c>catalog:cards</c> and <c>catalog:packs</c>, 1 h. Writers
/// delete; any Redis error is a counted miss. Never ownership, never currency, and never read when a price is charged.
/// </summary>
public sealed class CatalogCache(RedisConnection redis, RpgMetrics metrics, ILogger<CatalogCache> logger)
{
    public const string CardsKey = "catalog:cards";
    public const string PacksKey = "catalog:packs";
    public static readonly TimeSpan Ttl = TimeSpan.FromHours(1);

    public async Task<T?> GetAsync<T>(string key) where T : class
    {
        try
        {
            var value = await redis.Database().StringGetAsync(key);
            return value.IsNullOrEmpty ? null : JsonSerializer.Deserialize<T>(value.ToString(), RpgJson.Options);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex) || ex is JsonException)
        {
            metrics.CacheError("get");
            logger.LogDebug("Redis get of {Key} failed: {Message}", key, ex.Message);
            return null;
        }
    }

    public async Task SetAsync<T>(string key, T value)
    {
        try
        {
            await redis.Database().StringSetAsync(key, JsonSerializer.Serialize(value, RpgJson.Options), Ttl);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("set");
            logger.LogDebug("Redis set of {Key} failed: {Message}", key, ex.Message);
        }
    }

    public async Task InvalidateAsync(params string[] keys)
    {
        try
        {
            await redis.Database().KeyDeleteAsync([.. keys.Select(k => (StackExchange.Redis.RedisKey)k)]);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("delete");
            logger.LogDebug("Redis delete of catalog keys failed: {Message}", ex.Message);
        }
    }
}
