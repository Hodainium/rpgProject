using Rpg.GameServerApi.Observability;

namespace Rpg.GameServerApi.Runs;

/// <summary>Recomputes rpg_runs_in_progress from Postgres every 30 s (spec server-authority 5).</summary>
public sealed class RunsInProgressMonitor(RunStore store, RpgMetrics metrics, ILogger<RunsInProgressMonitor> logger)
    : BackgroundService
{
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(30);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(Interval);
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
