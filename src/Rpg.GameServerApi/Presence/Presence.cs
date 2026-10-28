using Microsoft.Extensions.Options;
using Rpg.Contracts.Presence;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Infrastructure;
using Rpg.GameServerApi.Observability;
using StackExchange.Redis;

namespace Rpg.GameServerApi.Presence;

/// <summary>Configuration section <c>Monitors</c>: how often the gauges are recomputed (spec server-authority 5).</summary>
public sealed class MonitorOptions
{
    public const string Section = "Monitors";

    public TimeSpan Interval { get; set; } = TimeSpan.FromSeconds(30);
}

/// <summary>
/// Live presence (spec server-authority 3.6): sorted sets of player ids scored by last seen (unix seconds).
/// <c>presence:online</c> is touched on every authenticated request and heartbeat; <c>presence:battle</c> follows the
/// heartbeat's activity. A hint for live monitoring, never used for decisions; Redis errors are counted and ignored.
/// </summary>
public sealed class PresenceTracker(RedisConnection redis, RpgMetrics metrics, TimeProvider clock,
    ILogger<PresenceTracker> logger)
{
    public const string OnlineKey = "presence:online";
    public const string BattleKey = "presence:battle";
    public static readonly TimeSpan OnlineWindow = TimeSpan.FromMinutes(5);
    public static readonly TimeSpan BattleWindow = TimeSpan.FromMinutes(2);

    /// <summary>On every authenticated request: fire and forget, so it never adds latency.</summary>
    public void Touch(Guid playerId)
    {
        try
        {
            redis.Database().SortedSetAdd(OnlineKey, playerId.ToString("D"), Now(), CommandFlags.FireAndForget);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("zadd");
        }
    }

    public async Task HeartbeatAsync(Guid playerId, PresenceActivity activity)
    {
        var member = playerId.ToString("D");
        try
        {
            var db = redis.Database();
            var online = db.SortedSetAddAsync(OnlineKey, member, Now());
            var battle = activity == PresenceActivity.Battle
                ? db.SortedSetAddAsync(BattleKey, member, Now())
                : db.SortedSetRemoveAsync(BattleKey, member);
            await Task.WhenAll(online, battle);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("zadd");
            logger.LogDebug("Presence heartbeat not stored: {Message}", ex.Message);
        }
    }

    /// <summary>Trims members older than each window, then counts the rest.</summary>
    public async Task<(long Online, long InBattle)> CountAsync()
    {
        var db = redis.Database();
        var now = Now();
        var onlineFrom = now - OnlineWindow.TotalSeconds;
        var battleFrom = now - BattleWindow.TotalSeconds;
        await db.SortedSetRemoveRangeByScoreAsync(OnlineKey, double.NegativeInfinity, onlineFrom, Exclude.Stop);
        await db.SortedSetRemoveRangeByScoreAsync(BattleKey, double.NegativeInfinity, battleFrom, Exclude.Stop);
        return (await db.SortedSetLengthAsync(OnlineKey, onlineFrom), await db.SortedSetLengthAsync(BattleKey, battleFrom));
    }

    private double Now() => clock.GetUtcNow().ToUnixTimeSeconds();
}

/// <summary>Recomputes rpg_players_online and rpg_players_in_battle; while Redis is down they keep their last value.</summary>
public sealed class PresenceMonitor(PresenceTracker tracker, RpgMetrics metrics, IOptions<MonitorOptions> options,
    ILogger<PresenceMonitor> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(options.Value.Interval);
        do
        {
            try
            {
                var (online, inBattle) = await tracker.CountAsync();
                metrics.SetPresence(online, inBattle);
            }
            catch (Exception ex) when (RedisConnection.IsError(ex))
            {
                logger.LogDebug("Presence not counted (gauges stale): {Message}", ex.Message);
            }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}

public static class PresenceEndpoints
{
    public static void MapPresenceEndpoints(this WebApplication app) =>
        app.MapPost("/api/v1/presence", async (HttpContext context, PresenceRequest? request, PresenceTracker tracker) =>
        {
            if (request is null || !Enum.IsDefined(request.Activity))
            {
                return Results.Problem(statusCode: StatusCodes.Status400BadRequest, title: "Bad request",
                    detail: "activity is one of Menu, Map, Battle.");
            }

            await tracker.HeartbeatAsync(context.User.Player().Id, request.Activity);
            return Results.NoContent();
        }).RequireAuthorization();

    /// <summary>Every authenticated request counts as being online (after authentication, before the endpoint).</summary>
    public static void UsePresence(this WebApplication app) =>
        app.Use((context, next) =>
        {
            if (context.User.PlayerIdOrNull() is { } playerId)
            {
                context.RequestServices.GetRequiredService<PresenceTracker>().Touch(playerId);
            }

            return next(context);
        });
}
