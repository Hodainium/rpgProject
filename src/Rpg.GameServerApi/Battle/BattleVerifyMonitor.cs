using Microsoft.Extensions.Options;
using RabbitMQ.Client;
using Rpg.Contracts.Battle;
using Rpg.GameServerApi.Infrastructure;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.Presence;
using Rpg.GameServerApi.Runs;

namespace Rpg.GameServerApi.Battle;

/// <summary>
/// Recomputes rpg_battles_unverified, rpg_battle_oldest_unverified_age_seconds (Postgres) and rpg_verify_queue_depth
/// (RabbitMQ passive declares) every <c>Monitors:Interval</c> (spec battle-verify 5). A dependency that is down keeps
/// its last value.
/// </summary>
public sealed class BattleVerifyMonitor(RunStore store, RabbitMqConnection rabbit, RpgMetrics metrics,
    IOptions<MonitorOptions> options, TimeProvider clock, ILogger<BattleVerifyMonitor> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(options.Value.Interval);
        do
        {
            await CountOnceAsync(stoppingToken);
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    public async Task CountOnceAsync(CancellationToken ct)
    {
        try
        {
            var (count, oldest) = await store.UnverifiedAsync(ct);
            metrics.SetBattlesUnverified(count, oldest is null ? 0 : (clock.GetUtcNow() - oldest.Value).TotalSeconds);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogDebug("Unverified battles not counted: {Message}", ex.Message);
        }

        try
        {
            if (rabbit.OpenConnection is not { } connection)
            {
                return;
            }

            await using var channel = await connection.CreateChannelAsync(cancellationToken: ct);
            metrics.SetVerifyQueueDepth("verify.battle", await DepthAsync(channel, VerifyTopology.Queue, ct));
            long retry = 0;
            foreach (var tier in VerifyTopology.RetryTiers)
            {
                retry += await DepthAsync(channel, tier.Queue, ct);
            }

            metrics.SetVerifyQueueDepth("retry", retry);
            metrics.SetVerifyQueueDepth("dlq", await DepthAsync(channel, VerifyTopology.DeadLetterQueue, ct));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // A queue that is not declared yet closes the channel (404): nothing has been published, depth stays unknown.
            logger.LogDebug("Verify queue depth not read: {Message}", ex.Message);
        }
    }

    private static async Task<long> DepthAsync(IChannel channel, string queue, CancellationToken ct) =>
        (await channel.QueueDeclarePassiveAsync(queue, ct)).MessageCount;
}
