using System.Diagnostics;
using Microsoft.Extensions.Options;
using Npgsql;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Serialization;
using Rpg.Verification;
using System.Text.Json;

namespace Rpg.VerifierWorker;

public enum JobAction
{
    /// <summary>Done (a verdict was written, or one already existed): ack.</summary>
    Ack,

    /// <summary>Publish to <see cref="JobDecision.Tier"/>, then ack.</summary>
    Retry,

    /// <summary>Publish to the dead-letter queue with <see cref="JobDecision.Reason"/>, then ack.</summary>
    DeadLetter,
}

/// <param name="Result">The <c>rpg_verify_jobs</c> label.</param>
/// <param name="Attempt">The attempt count to put in the retry message's header.</param>
public sealed record JobDecision(JobAction Action, string Result, RetryTier? Tier = null, string? Reason = null,
    int Attempt = 0);

/// <summary>
/// One verify job, start to decision (spec battle-verify 2.1). It knows nothing about RabbitMQ: it returns what the
/// consumer must do with the message, and the consumer acts only after this returns, so the ack always follows the commit.
/// </summary>
public sealed class VerifyProcessor(VerdictStore store, VerifierRedis redis, IReplayRunner runner, WorkerState state,
    IOptions<VerifierOptions> options, WorkerMetrics metrics, TimeProvider clock, ILogger<VerifyProcessor> logger)
{
    public static readonly ActivitySource Source = new("Rpg.VerifierWorker");

    /// <summary>Tests: runs between the commit and the return, where a worker could die before the ack.</summary>
    public Func<Task>? AfterCommit { get; set; }

    public async Task<JobDecision> ProcessAsync(VerifyBattleJob job, CancellationToken ct)
    {
        try
        {
            return await ProcessCoreAsync(job, ct);
        }
        catch (Exception ex) when (ex is NpgsqlException { IsTransient: true } or IOException or TimeoutException)
        {
            // Postgres (or the network) is down: nothing was decided, so the attempt is not counted (F12). A permanent
            // SQL error (a constraint, bad data) is not this: it surfaces to the consumer and dead-letters the job.
            // PostgresException derives from NpgsqlException, hence the IsTransient test.
            logger.LogWarning("Verify of {BattleId} postponed: {Message}", job.BattleId, ex.Message);
            return Decide(new JobDecision(JobAction.Retry, "retry", VerifyTopology.RetryTiers[1]));
        }
    }

    private async Task<JobDecision> ProcessCoreAsync(VerifyBattleJob job, CancellationToken ct)
    {
        var settings = options.Value;
        var row = await store.LoadAsync(job.BattleId, ct);
        if (row is null)
        {
            return Decide(new JobDecision(JobAction.DeadLetter, "dead_lettered", Reason: "poison: unknown battle"));
        }

        if (row.Status != nameof(BattleSessionStatus.Submitted))
        {
            return Decide(new JobDecision(JobAction.Ack, "duplicate"));
        }

        if (!state.Accepts(row.Ruleset))
        {
            await store.DeadLetterAsync(job.BattleId, "ruleset", clock.GetUtcNow(), ct);
            return Decide(new JobDecision(JobAction.DeadLetter, "wrong_ruleset", Reason: "ruleset"));
        }

        await store.RenewLeaseAsync(job.BattleId, clock.GetUtcNow(), ct);
        var token = Guid.NewGuid().ToString("N");
        var locked = false;
        if (settings.UseLock)
        {
            switch (await redis.TryLockAsync(job.BattleId, token, settings.LockTtl))
            {
                case LockResult.Busy:
                    metrics.Lock("busy");
                    return Decide(new JobDecision(JobAction.Retry, "lock_busy", VerifyTopology.RetryTiers[0]));
                case LockResult.Acquired:
                    metrics.Lock("acquired");
                    locked = true;
                    break;
                default:
                    metrics.Lock("redis_error");
                    break;
            }
        }

        try
        {
            // The first look was before the lock: a worker that waited out a busy lock may find the verdict already there,
            // and would otherwise burn a Godot process to learn the same thing from the guarded update.
            if (locked && await store.LoadAsync(job.BattleId, ct) is { Status: not nameof(BattleSessionStatus.Submitted) })
            {
                return Decide(new JobDecision(JobAction.Ack, "duplicate"));
            }

            return await ReplayAndCommitAsync(job, row, ct);
        }
        finally
        {
            if (locked)
            {
                await redis.ReleaseAsync(job.BattleId, token);
            }
        }
    }

    private async Task<JobDecision> ReplayAndCommitAsync(VerifyBattleJob job, BattleRow row, CancellationToken ct)
    {
        using var activity = Source.StartActivity("godot.replay");
        var started = Stopwatch.GetTimestamp();
        ReplayRun run;
        try
        {
            run = await runner.ReplayAsync($$"""{"snapshot":{{row.ConditionsJson}},"actionLog":{{row.ActionLogJson}}}""", ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException and not NpgsqlException)
        {
            run = new ReplayRun(ReplayRunStatus.RunnerError, null, ex.Message);
        }

        var took = Stopwatch.GetElapsedTime(started);
        if (run.Status == ReplayRunStatus.Completed && run.Result is { } result && result.BattleId == job.BattleId)
        {
            var outcome = result.Verdict == ReplayVerdict.Verified ? "verified" : "rejected";
            metrics.ReplayDuration(outcome, took);
            metrics.GodotUsage(outcome, run.Usage);
            activity?.SetTag("rpg.verdict", result.Verdict.ToString());
            return await CommitAsync(job, row, result, ct);
        }

        metrics.ReplayDuration("error", took);
        metrics.GodotUsage("error", run.Usage);
        var detail = run.Result is null ? run.Detail : $"the result is for battle {run.Result.BattleId}";
        logger.LogWarning("Replay of {BattleId} failed: {Status} {Detail}", job.BattleId, run.Status, detail);
        var attempts = await store.RecordAttemptAsync(job.BattleId, ct);
        if (attempts >= options.Value.MaxAttempts)
        {
            await store.DeadLetterAsync(job.BattleId, "attempts", clock.GetUtcNow(), ct);
            return Decide(new JobDecision(JobAction.DeadLetter, "dead_lettered", Reason: "attempts", Attempt: attempts));
        }

        return Decide(new JobDecision(JobAction.Retry, "retry", VerifyPolicy.TierForAttempt(attempts), Attempt: attempts));
    }

    private async Task<JobDecision> CommitAsync(VerifyBattleJob job, BattleRow row, ReplayResult result, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var verdict = new BattleVerdict(result.Verdict, result.ErrorCode, result.Error, result.Mismatch, result.Outcome,
            result.Turns, result.FinalStateHash, state.RulesetVersion, result.EngineVersion, now);
        if (!await store.CommitVerdictAsync(job.BattleId, verdict, now, ct))
        {
            return Decide(new JobDecision(JobAction.Ack, "duplicate"));
        }

        if (AfterCommit is { } hook)
        {
            await hook();
        }

        // Everything after the commit is best effort: the battle is decided, so nothing here may change the job's outcome
        // (a failure would otherwise dead-letter a verified battle).
        try
        {
            metrics.Latency(now - row.SubmittedAt);
            if (result.Verdict == ReplayVerdict.Rejected && result.Mismatch is { } mismatch)
            {
                metrics.Rejection(mismatch.Reason);
            }

            // A stale Submitted copy must not outlive the verdict (F14).
            var session = new BattleSessionResponse(row.BattleId, row.RunId.ToString("D"), row.RunSeq,
                JsonSerializer.Deserialize<BattleSnapshot>(row.ConditionsJson, RpgJson.Options)!,
                JsonSerializer.Deserialize<ActionLog>(row.ActionLogJson, RpgJson.Options)!, row.Ruleset,
                result.Verdict == ReplayVerdict.Verified ? BattleSessionStatus.Verified : BattleSessionStatus.Rejected,
                row.SubmittedAt, verdict);
            if (!await redis.PublishVerdictAsync(new StoredBattle(row.PlayerId, session)))
            {
                metrics.CacheError("set");
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning("Post-commit work for {BattleId} failed (the verdict stands): {Message}", job.BattleId, ex.Message);
        }

        return Decide(new JobDecision(JobAction.Ack, result.Verdict == ReplayVerdict.Verified ? "verified" : "rejected"));
    }

    private JobDecision Decide(JobDecision decision)
    {
        metrics.Job(decision.Result);
        return decision;
    }
}
