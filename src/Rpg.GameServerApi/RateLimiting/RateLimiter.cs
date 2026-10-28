using System.Globalization;
using Microsoft.Extensions.Options;
using Rpg.Contracts.Api.V1;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Infrastructure;
using Rpg.GameServerApi.Observability;
using StackExchange.Redis;

namespace Rpg.GameServerApi.RateLimiting;

/// <summary>One token bucket: <c>Capacity</c> requests at once, refilled at <c>RefillPerSecond</c>.</summary>
public sealed class BucketOptions
{
    public double Capacity { get; set; }
    public double RefillPerSecond { get; set; }
}

/// <summary>Configuration section <c>RateLimit</c> (spec server-authority 3.6). Buckets: actions, runs, floors.</summary>
public sealed class RateLimitOptions
{
    public const string Section = "RateLimit";
    public const string Actions = "actions";
    public const string Runs = "runs";
    public const string Floors = "floors";

    /// <summary>Per bucket; a bucket not configured uses <see cref="Default"/>.</summary>
    public Dictionary<string, BucketOptions> Buckets { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public BucketOptions For(string bucket) => Buckets.GetValueOrDefault(bucket) ?? Default(bucket);

    /// <summary>Upload requests (not actions), run starts, stairs.</summary>
    public static BucketOptions Default(string bucket) => bucket switch
    {
        Actions => new BucketOptions { Capacity = 60, RefillPerSecond = 10 },
        Runs => new BucketOptions { Capacity = 5, RefillPerSecond = 0.1 },
        _ => new BucketOptions { Capacity = 20, RefillPerSecond = 1 },
    };
}

/// <summary>
/// Per-player token buckets in Redis: <c>ratelimit:{playerId}:{bucket}</c>, a hash {tokens, updatedAt}, refilled and
/// taken in one Lua script on Redis's clock (atomic across server instances), expiring after 10 idle minutes.
/// Redis down → <b>fails open</b>: the request passes and <c>rpg_cache_errors_total{operation="ratelimit"}</c> counts it.
/// </summary>
public sealed class RateLimiter(RedisConnection redis, IOptions<RateLimitOptions> options, RpgMetrics metrics,
    ILogger<RateLimiter> logger)
{
    public static readonly TimeSpan IdleTtl = TimeSpan.FromMinutes(10);

    // KEYS[1] bucket; ARGV[1] capacity; ARGV[2] refill per ms; ARGV[3] idle ttl ms. Returns {allowed, retryAfterMs}.
    private static readonly LuaScript TakeScript = LuaScript.Prepare("""
        local t = redis.call('TIME')
        local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
        local capacity = tonumber(@capacity)
        local rate = tonumber(@rate)
        local state = redis.call('HMGET', @key, 'tokens', 'updatedAt')
        local tokens = tonumber(state[1])
        local updated = tonumber(state[2])
        if tokens == nil or updated == nil then
          tokens = capacity
          updated = now
        end
        tokens = math.min(capacity, tokens + math.max(0, now - updated) * rate)
        local allowed = 0
        local wait = 0
        if tokens >= 1 then
          tokens = tokens - 1
          allowed = 1
        else
          wait = math.ceil((1 - tokens) / rate)
        end
        redis.call('HSET', @key, 'tokens', tostring(tokens), 'updatedAt', tostring(now))
        redis.call('PEXPIRE', @key, @ttl)
        return {allowed, wait}
        """);

    public static string Key(Guid playerId, string bucket) => $"ratelimit:{playerId:D}:{bucket}";

    /// <summary>Null when the request may pass, else how long to wait.</summary>
    public async Task<TimeSpan?> TakeAsync(Guid playerId, string bucket)
    {
        var limits = options.Value.For(bucket);
        try
        {
            var result = (RedisResult[])(await redis.Database().ScriptEvaluateAsync(TakeScript, new
            {
                key = (RedisKey)Key(playerId, bucket),
                capacity = limits.Capacity.ToString(CultureInfo.InvariantCulture),
                rate = (limits.RefillPerSecond / 1000).ToString("R", CultureInfo.InvariantCulture),
                ttl = (long)IdleTtl.TotalMilliseconds,
            }))!;
            return (int)result[0] == 1 ? null : TimeSpan.FromMilliseconds((long)result[1]);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("ratelimit");
            logger.LogDebug("Rate limit not checked (failing open): {Message}", ex.Message);
            return null;
        }
    }
}

public static class RateLimitExtensions
{
    /// <summary>Takes a token from the caller's <paramref name="bucket"/> before the endpoint runs; 429 1201 with
    /// <c>Retry-After</c> (whole seconds, at least 1) when it's empty. The endpoint must require authorization.</summary>
    public static RouteHandlerBuilder RateLimited(this RouteHandlerBuilder builder, string bucket) =>
        builder.AddEndpointFilter(async (context, next) =>
        {
            var http = context.HttpContext;
            var limiter = http.RequestServices.GetRequiredService<RateLimiter>();
            if (http.User.PlayerIdOrNull() is { } playerId && await limiter.TakeAsync(playerId, bucket) is { } wait)
            {
                http.RequestServices.GetRequiredService<RpgMetrics>().RateLimited(bucket);
                var seconds = Math.Max(1, (int)Math.Ceiling(wait.TotalSeconds));
                http.Response.Headers.RetryAfter = seconds.ToString(CultureInfo.InvariantCulture);
                return Results.Problem(statusCode: StatusCodes.Status429TooManyRequests, title: "Too many requests",
                    detail: $"Rate limit for {bucket} reached; retry in {seconds} s.",
                    extensions: new Dictionary<string, object?> { ["errorCode"] = ApiErrors.RateLimited });
            }

            return await next(context);
        });
}
