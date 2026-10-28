using Microsoft.Extensions.Options;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.Presence;

namespace Rpg.GameServerApi.Runs;

/// <summary>Recomputes rpg_runs_in_progress from Postgres every <c>Monitors:Interval</c> (30 s; spec server-authority 5).</summary>
public sealed class RunsInProgressMonitor(RunStore store, RpgMetrics metrics, IOptions<MonitorOptions> options,
    ILogger<RunsInProgressMonitor> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(options.Value.Interval);
        do
        {
            try
            {
                metrics.SetRunsInProgress(await store.CountActiveAsync(stoppingToken));
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // Keeps the last value; readiness already reports Postgres as unhealthy.
                logger.LogDebug("Runs in progress not counted: {Message}", ex.Message);
            }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
