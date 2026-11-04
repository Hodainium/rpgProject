using Microsoft.Extensions.Options;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.Presence;
using Rpg.Verification;

namespace Rpg.GameServerApi.Outbox;

/// <summary>
/// Recomputes <c>rpg_outbox_pending</c>, <c>rpg_outbox_oldest_unpublished_age_seconds</c> (the outbox lag) and
/// <c>rpg_outbox_dead_lettered</c> from Postgres every <c>Monitors:Interval</c> (spec settlement-outbox 5). A destination
/// with nothing in the table reads zero; Postgres being down keeps the last values.
/// </summary>
public sealed class OutboxMonitor(OutboxStore store, RpgMetrics metrics, IOptions<MonitorOptions> options, TimeProvider clock,
    ILogger<OutboxMonitor> logger) : BackgroundService
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
            var stats = await store.StatsAsync(clock.GetUtcNow(), ct);
            foreach (var destination in new[] { OutboxDestination.Rabbit, OutboxDestination.Redpanda })
            {
                var s = stats.FirstOrDefault(x => x.Destination == destination);
                metrics.SetOutbox(destination, s?.Pending ?? 0, s?.OldestAge ?? 0, s?.DeadLettered ?? 0);
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogDebug("Outbox not counted: {Message}", ex.Message);
        }
    }
}
