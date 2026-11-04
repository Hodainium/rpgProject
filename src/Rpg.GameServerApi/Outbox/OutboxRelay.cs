using System.Diagnostics;
using Microsoft.Extensions.Options;
using Rpg.GameServerApi.Observability;
using Rpg.Verification;

namespace Rpg.GameServerApi.Outbox;

/// <summary>
/// The outbox relay (spec settlement-outbox 2.1): leases rows, publishes each to its destination with a confirm, marks
/// it published. At-least-once: a crash between the confirm and the mark publishes the row again, with the same event id.
/// A permanent failure dead-letters the row at once; a transient one backs off and blocks only that row's key.
/// </summary>
public sealed class OutboxRelay(OutboxStore store, IEnumerable<IOutboxSink> sinks, IOptions<OutboxOptions> options,
    RpgMetrics metrics, TimeProvider clock, ILogger<OutboxRelay> logger) : BackgroundService
{
    public static readonly ActivitySource Source = new("Rpg.GameServerApi.Outbox");

    private readonly IReadOnlyDictionary<string, IOutboxSink> _sinks = sinks.ToDictionary(s => s.Destination);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            var worked = 0;
            try
            {
                if (options.Value.Enabled)
                {
                    worked = await RunOnceAsync(stoppingToken);
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning("Outbox poll failed: {Message}", ex.Message);
            }
            catch (OperationCanceledException)
            {
                break;
            }

            if (worked == 0)
            {
                try
                {
                    await Task.Delay(options.Value.PollInterval, stoppingToken);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }
    }

    /// <summary>One lease-and-publish pass (tests call it directly). Returns how many rows it took.</summary>
    public async Task<int> RunOnceAsync(CancellationToken ct)
    {
        var settings = options.Value;
        var rows = await store.LeaseAsync(settings.BatchSize, settings.Lease, clock.GetUtcNow(), ct);
        // Destinations run side by side, so a Redpanda outage never delays a verify job. Within one destination rows go in
        // order; a transient failure backs off only its own key, and a run of failures (the destination is down) ends the
        // pass so the rest of the batch is not made to wait out a timeout each.
        await Task.WhenAll(rows.GroupBy(r => r.Destination).Select(group => PublishGroupAsync(group.ToList(), ct)));
        return rows.Count;
    }

    /// <summary>Consecutive transient failures after which the rest of a destination's batch is given back.</summary>
    private const int FailureBreaker = 3;

    private async Task PublishGroupAsync(List<OutboxRow> rows, CancellationToken ct)
    {
        var failures = 0;
        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            if (!_sinks.TryGetValue(row.Destination, out var sink))
            {
                await store.DeadLetterAsync(row.Id, $"no sink for '{row.Destination}'", clock.GetUtcNow(), ct);
                metrics.OutboxPublished(row.Destination, row.Type, "failed");
                continue;
            }

            ActivityContext.TryParse(row.TraceParent, null, out var parent);
            using var activity = Source.StartActivity("outbox.publish", ActivityKind.Producer, parent);
            activity?.SetTag("rpg.outbox.type", row.Type);
            var started = Stopwatch.GetTimestamp();
            try
            {
                await sink.PublishAsync(row, ct);
                metrics.OutboxPublished(row.Destination, row.Type, "ok");
                metrics.OutboxPublishDuration(row.Destination, Stopwatch.GetElapsedTime(started));
                failures = 0;
                try
                {
                    await store.MarkPublishedAsync(row.Id, clock.GetUtcNow(), ct);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    // Delivered but not recorded: not a publish failure. The lease expires and the row goes out again with
                    // the same event id (at-least-once); it must never be counted as failed or dead-lettered.
                    logger.LogWarning("Outbox row {Id} ({Type}) was published but not marked: {Message}", row.Id, row.Type,
                        ex.Message);
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                await ReleaseAsync(rows.Skip(i));
                throw;
            }
            catch (OutboxPermanentException ex)
            {
                logger.LogError("Outbox row {Id} ({Type}) dead-lettered: {Reason}", row.Id, row.Type, ex.Message);
                await store.DeadLetterAsync(row.Id, ex.Message, clock.GetUtcNow(), CancellationToken.None);
                metrics.OutboxPublished(row.Destination, row.Type, "failed");
            }
            catch (Exception ex)
            {
                metrics.OutboxPublished(row.Destination, row.Type, "failed");
                var max = options.Value.MaxAttempts;
                if (row.Destination == OutboxDestination.Redpanda && max > 0 && row.Attempts >= max)
                {
                    logger.LogError("Outbox row {Id} ({Type}) dead-lettered after {Attempts} attempts: {Message}", row.Id,
                        row.Type, row.Attempts, ex.Message);
                    await store.DeadLetterAsync(row.Id, "attempts", clock.GetUtcNow(), CancellationToken.None);
                }
                else
                {
                    logger.LogWarning("Outbox row {Id} ({Type}) not published (attempt {Attempts}): {Message}", row.Id,
                        row.Type, row.Attempts, ex.Message);
                    await store.ScheduleRetryAsync(row.Id, clock.GetUtcNow() + options.Value.Backoff(row.Attempts),
                        CancellationToken.None);
                }

                if (++failures >= FailureBreaker)
                {
                    await ReleaseAsync(rows.Skip(i + 1));
                    return;
                }
            }
        }
    }

    private async Task ReleaseAsync(IEnumerable<OutboxRow> rest)
    {
        var ids = rest.Select(r => r.Id).ToArray();
        if (ids.Length > 0)
        {
            await store.ReleaseAsync(ids, CancellationToken.None);
        }
    }
}
