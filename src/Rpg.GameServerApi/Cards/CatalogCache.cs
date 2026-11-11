using System.Text.Json;
using Npgsql;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Infrastructure;
using Rpg.GameServerApi.Observability;
using StackExchange.Redis;

namespace Rpg.GameServerApi.Cards;

/// <summary>
/// Cache-aside for the two catalog reads (spec card-collection 3.3): <c>catalog:cards</c> and <c>catalog:packs</c>, 1 h. Writers
/// delete; any Redis error is a counted miss. Never ownership, never currency, and never read when a price is charged.
/// <para>
/// Review fixes (2026-11-09). A refill cannot bring back a catalog an admin just replaced: a reader takes the catalog
/// generation (<see cref="GenerationAsync"/>) before it reads Postgres, and <see cref="SetAsync{T}"/> writes only while the
/// generation is unchanged; a catalog writer bumps it before deleting the keys. And the keys are scoped by the Postgres
/// database they cache, so two databases sharing one Redis (the tests) never serve each other's catalog. Callers name the
/// keys by <see cref="CardsKey"/> and <see cref="PacksKey"/>; the scoping is done here.
/// </para>
/// </summary>
public sealed class CatalogCache(RedisConnection redis, NpgsqlDataSource dataSource, RpgMetrics metrics, ILogger<CatalogCache> logger)
{
    public const string CardsKey = "catalog:cards";
    public const string PacksKey = "catalog:packs";
    public static readonly TimeSpan Ttl = TimeSpan.FromHours(1);

    private const string SetIfGenerationScript = """
        local current = redis.call('GET', KEYS[2]) or '0'
        if current ~= ARGV[3] then return 0 end
        redis.call('SET', KEYS[1], ARGV[1], 'PX', ARGV[2])
        return 1
        """;

    private readonly string _scope = new NpgsqlConnectionStringBuilder(dataSource.ConnectionString).Database ?? "";

    /// <summary>The Redis key for a catalog key name (the two names above), scoped by database; other keys pass through.</summary>
    public string Scoped(string key) => key is CardsKey or PacksKey ? $"{key}:{_scope}" : key;

    private string GenerationKey => $"catalog:gen:{_scope}";

    public async Task<T?> GetAsync<T>(string key) where T : class
    {
        try
        {
            var value = await redis.Database().StringGetAsync(Scoped(key));
            return value.IsNullOrEmpty ? null : JsonSerializer.Deserialize<T>(value.ToString(), RpgJson.Options);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex) || ex is JsonException)
        {
            metrics.CacheError("get");
            logger.LogDebug("Redis get of {Key} failed: {Message}", key, ex.Message);
            return null;
        }
    }

    /// <summary>The catalog generation now (take it before reading Postgres), or null on a Redis error (then nothing is cached).</summary>
    public async Task<string?> GenerationAsync()
    {
        try
        {
            var value = await redis.Database().StringGetAsync(GenerationKey);
            return value.IsNullOrEmpty ? "0" : value.ToString();
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("get");
            logger.LogDebug("Redis get of the catalog generation failed: {Message}", ex.Message);
            return null;
        }
    }

    /// <summary>Caches the value if the catalog generation is still <paramref name="generation"/> (no writer since the read).</summary>
    public async Task SetAsync<T>(string key, T value, string? generation)
    {
        if (generation is null)
        {
            return;
        }

        try
        {
            await redis.Database().ScriptEvaluateAsync(SetIfGenerationScript, [Scoped(key), GenerationKey],
                [JsonSerializer.Serialize(value, RpgJson.Options), (long)Ttl.TotalMilliseconds, generation]);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("set");
            logger.LogDebug("Redis set of {Key} failed: {Message}", key, ex.Message);
        }
    }

    /// <summary>Deletes keys after a write committed. A catalog key bumps the generation first, so no reader that read the
    /// old catalog can cache it afterwards.</summary>
    public async Task InvalidateAsync(params string[] keys)
    {
        try
        {
            if (keys.Any(k => k is CardsKey or PacksKey))
            {
                await redis.Database().StringIncrementAsync(GenerationKey);
            }

            await redis.Database().KeyDeleteAsync([.. keys.Select(k => (RedisKey)Scoped(k))]);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("delete");
            logger.LogDebug("Redis delete of catalog keys failed: {Message}", ex.Message);
        }
    }
}
