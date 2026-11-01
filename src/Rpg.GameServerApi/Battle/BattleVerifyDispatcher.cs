using Microsoft.Extensions.Options;
using Rpg.GameServerApi.Runs;

namespace Rpg.GameServerApi.Battle;

/// <summary>Configuration section <c>Verifier</c> (the API's half; the worker reads the same section name).</summary>
public sealed class VerifierOptions
{
    public const string Section = "Verifier";

    public TimeSpan SweepInterval { get; set; } = TimeSpan.FromSeconds(10);

    /// <summary>
    /// A job enqueued longer ago than this is published again if its session is still Submitted. Longer than the worst
    /// time a job legitimately spends away from the main queue (the 120 s retry tier plus the 60 s process timeout).
    /// </summary>
    public TimeSpan RepublishAfter { get; set; } = TimeSpan.FromMinutes(10);

    /// <summary>A session younger than this is left to the upload's own fast-path publish.</summary>
    public TimeSpan SweepGrace { get; set; } = TimeSpan.FromSeconds(30);

    public int SweepBatch { get; set; } = 100;
}

/// <summary>
/// The reconciler of spec battle-verify 2.4: until slice 4's outbox, a battle whose publish was lost (a crash between
/// commit and publish, the broker down) is republished from Postgres, so no battle stays unverified for that reason.
/// </summary>
public sealed class BattleVerifyDispatcher(RunStore store, VerifyJobPublisher publisher, IOptions<VerifierOptions> options,
    TimeProvider clock, ILogger<BattleVerifyDispatcher> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(options.Value.SweepInterval);
        do
        {
            try
            {
                var (published, failed) = await SweepOnceAsync(stoppingToken);
                if (failed > 0)
                {
                    logger.LogWarning("Verify sweep: {Published} job(s) republished, {Failed} not (the broker is unreachable?)",
                        published, failed);
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning("Verify sweep failed: {Message}", ex.Message);
            }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    /// <summary>
    /// One sweep; also called directly by tests. A job that was never enqueued is always published. A job enqueued long
    /// ago is republished only when the queues are EMPTY: while anything waits, the job may be one of those waiting (a
    /// backlog older than RepublishAfter must not be doubled), and a job being replayed carries a lease its worker
    /// renewed. Unknown backlog (the broker cannot be asked) counts as waiting.
    /// </summary>
    public async Task<(int Published, int Failed)> SweepOnceAsync(CancellationToken ct)
    {
        var republishStale = await publisher.BacklogAsync(ct) == 0;
        return await store.SweepUnenqueuedAsync((job, token) => publisher.TryPublishAsync(job, "sweeper", token),
            options.Value.SweepBatch, options.Value.RepublishAfter, republishStale, options.Value.SweepGrace,
            clock.GetUtcNow(), ct);
    }
}
