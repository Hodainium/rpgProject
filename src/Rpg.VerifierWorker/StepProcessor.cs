using System.Diagnostics;
using Microsoft.Extensions.Options;
using Npgsql;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Economy;
using Rpg.Verification;

namespace Rpg.VerifierWorker;

/// <summary>
/// One step job, start to decision (spec run-verify 2.2). Like <see cref="VerifyProcessor"/> it knows nothing about
/// RabbitMQ: it returns what the consumer must do, and the ack follows the commit. The step verdict, the battle verdicts, the
/// pending settlement and the aggregator's work are one transaction (<see cref="StepStore.CommitAsync"/>).
/// </summary>
public sealed class StepProcessor(StepStore store, VerifierRedis redis, IStepRunner runner, WorkerState state,
    IOptions<VerifierOptions> options, IOptions<SettlementOptions> settlement, IOptions<RunVerifyOptions> verify,
    WorkerMetrics metrics, TimeProvider clock, ILogger<StepProcessor> logger)
{
    /// <summary>Tests: runs between the commit and the return, where a worker could die before the ack.</summary>
    public Func<Task>? AfterCommit { get; set; }

    public async Task<JobDecision> ProcessAsync(VerifyStepJob job, CancellationToken ct)
    {
        try
        {
            return await ProcessCoreAsync(job, ct);
        }
        catch (Exception ex) when (ex is NpgsqlException { IsTransient: true } or IOException or TimeoutException
                                       or PostgresException { SqlState: PostgresErrorCodes.DeadlockDetected or PostgresErrorCodes.SerializationFailure })
        {
            // Postgres is down, or it aborted this transaction to break a lock cycle: nothing was decided, so the attempt is not
            // counted and the step is tried again (spec run-verify 4 F16).
            logger.LogWarning("Step {Run}/{Step} postponed: {Message}", job.RunId, job.StepNo, ex.Message);
            return Decide(new JobDecision(JobAction.Retry, "postponed", VerifyTopology.SegmentRetryTiers[1]));
        }
    }

    private async Task<JobDecision> ProcessCoreAsync(VerifyStepJob job, CancellationToken ct)
    {
        var step = await store.LoadAsync(job.RunId, job.Epoch, job.StepNo, ct);
        if (step is null)
        {
            return Decide(new JobDecision(JobAction.DeadLetter, "dead_letter", Reason: "poison: unknown step"));
        }

        if (step.Status == "Voided")
        {
            return Decide(new JobDecision(JobAction.Ack, "superseded"));
        }

        if (step.Status != "Pending")
        {
            return Decide(new JobDecision(JobAction.Ack, "duplicate"));
        }

        if (!state.Accepts(step.Ruleset))
        {
            await store.DeadLetterAsync(step.RunId, step.Epoch, step.StepNo, "ruleset", clock.GetUtcNow(), ct);
            return Decide(new JobDecision(JobAction.DeadLetter, "ruleset", Reason: "ruleset"));
        }

        // A run the verifier ended needs no more steps; a run abandoned before it uploaded anything needs no anchor.
        var finished = step.RunStatus == "Rejected"
                       || (step.Kind == "genesis" && step.RunStatus is not ("Active" or "Verifying") && step.LastSeq == 0);
        if (finished)
        {
            await store.VoidAsync(step.RunId, step.Epoch, step.StepNo, ct);
            return Decide(new JobDecision(JobAction.Ack, step.Kind == "genesis" ? "run_gone" : "superseded"));
        }

        return await RunAndCommitAsync(step, ct);
    }

    private async Task<JobDecision> RunAndCommitAsync(StepRow step, CancellationToken ct)
    {
        var input = await store.BuildAsync(step, ct);
        if (input is null)
        {
            // Step 1 waits for the genesis job's start snapshot. Normally seconds; counted as an attempt each time, so a genesis
            // that never comes (dead-lettered, lost) ends in the DLQ like any other stuck job instead of cycling for ever.
            var waited = await store.RecordAttemptAsync(step.RunId, step.Epoch, step.StepNo, ct);
            if (waited >= options.Value.MaxAttempts * 4)
            {
                await store.DeadLetterAsync(step.RunId, step.Epoch, step.StepNo, "genesis_missing", clock.GetUtcNow(), ct);
                return Decide(new JobDecision(JobAction.DeadLetter, "dead_letter", Reason: "genesis_missing", Attempt: waited));
            }

            return Decide(new JobDecision(JobAction.Retry, "postponed", VerifyTopology.SegmentRetryTiers[0], Attempt: waited));
        }

        var started = Stopwatch.GetTimestamp();
        StepRun run;
        try
        {
            run = await runner.RunAsync(input.RequestJson, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException and not NpgsqlException)
        {
            run = new StepRun(ReplayRunStatus.RunnerError, null, ex.Message);
        }

        var took = Stopwatch.GetElapsedTime(started);
        if (run.Status == ReplayRunStatus.Completed && run.Verdict is { } verdict)
        {
            metrics.StepDuration(step.Kind, took);
            metrics.GodotUsage(verdict.Status == ReplayVerdict.Verified ? "verified" : "rejected", run.Usage);
            return await CommitAsync(step, input, verdict, ct);
        }

        metrics.GodotUsage("error", run.Usage);
        logger.LogWarning("Step {Run}/{Step} failed: {Status} {Detail}", step.RunId, step.StepNo, run.Status, run.Detail);
        var attempts = await store.RecordAttemptAsync(step.RunId, step.Epoch, step.StepNo, ct);
        if (attempts >= options.Value.MaxAttempts)
        {
            await store.DeadLetterAsync(step.RunId, step.Epoch, step.StepNo, "attempts", clock.GetUtcNow(), ct);
            return Decide(new JobDecision(JobAction.DeadLetter, "dead_letter", Reason: "attempts", Attempt: attempts));
        }

        return Decide(new JobDecision(JobAction.Retry, "retry", VerifyMessaging.SegmentTierForAttempt(attempts), Attempt: attempts));
    }

    private async Task<JobDecision> CommitAsync(StepRow step, StepInput input, StepVerdict reported, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var verdict = reported with { VerifierRulesetVersion = state.RulesetVersion, VerifiedAt = now };
        var commit = await store.CommitAsync(step, verdict, input, settlement.Value, verify.Value, now, ct);
        if (!commit.Committed)
        {
            return Decide(new JobDecision(JobAction.Ack, "duplicate"));
        }

        if (AfterCommit is { } hook)
        {
            await hook();
        }

        var malformed = verdict.Mismatch?.Reason == StepMismatchReason.MalformedRequest;
        var result = verdict.Status == ReplayVerdict.Verified ? "verified" : malformed ? "malformed" : "rejected";

        // Everything after the commit is best effort: the step is decided, nothing here may change the job's outcome.
        try
        {
            metrics.StepWait(now - step.CreatedAt);
            if (verdict.Mismatch is { } mismatch)
            {
                metrics.StepMismatch(mismatch.Reason);
            }

            foreach (var settled in commit.Settlements)
            {
                metrics.Settlement(settled.Result switch
                {
                    SettlementResult.Granted => "granted",
                    SettlementResult.AlreadyMarked => "already_marked",
                    SettlementResult.Rejected => "rejected",
                    SettlementResult.NoRule => "no_rule",
                    SettlementResult.BadId => "bad_id",
                    SettlementResult.IgnoredFact => "ignored_fact",
                    _ => "no_reward",
                });
                if (settled.Settlement is { } summary)
                {
                    metrics.RewardRuleLookups("found", summary.Found);
                    metrics.RewardRuleLookups("missing", summary.Missing);
                    metrics.RewardRuleLookups("retired", summary.Retired);
                    metrics.RewardRuleLookups("expired", summary.Expired);
                    metrics.CompletionMarks("existing", summary.MarksExisting);   // marks already held at settlement; new ones are claimed at release
                }

                metrics.LedgerTransition("pending", settled.Grants.Sum(g => g.Gems));
            }

            foreach (var battle in verdict.Battles.Where(b => b.Verdict == ReplayVerdict.Rejected && b.Mismatch is not null))
            {
                metrics.Rejection(battle.Mismatch!.Reason);
            }

            if (commit.Aggregate is { } aggregate)
            {
                metrics.Fanin(aggregate.Result);
                metrics.FloorsVerified(aggregate.FloorsVerified);
                metrics.LedgerTransition("released", aggregate.GemsReleased);
                metrics.CompletionMarks("new", aggregate.MarksClaimed);
                metrics.CompletionMarks("existing", aggregate.AlreadyPaid);
                metrics.LedgerTransition("voided", aggregate.GemsVoided);
                if (aggregate.Result == "won")
                {
                    metrics.RunVerdict("won");
                }

                if (aggregate.Result is "rolled_back" or "rejected" && aggregate.Reason is { } reason)
                {
                    var terminal = aggregate.Result == "rejected";
                    metrics.RunRolledBack(RunAggregator.CategoryOf(reason), terminal);
                    metrics.AntiCheat(RunAggregator.CategoryOf(reason));
                    if (terminal)
                    {
                        metrics.RunVerdict("rejected");
                    }
                }

                if (aggregate.Changed || commit.Settlements.Count > 0 || step.Kind == "genesis")
                {
                    if (!await redis.InvalidateRunAsync(step.RunId, step.PlayerId, floors: aggregate.Result is "rolled_back" or "rejected"
                            || aggregate.FloorsVerified > 0))
                    {
                        metrics.CacheError("delete");
                    }
                }
            }

            foreach (var row in commit.Battles)
            {
                var session = verdict.Battles.First(b => b.BattleId == row.BattleId);
                var rejected = session.Verdict == ReplayVerdict.Rejected;
                var response = new BattleSessionResponse(row.BattleId, row.RunId.ToString("D"), row.RunSeq,
                    System.Text.Json.JsonSerializer.Deserialize<BattleSnapshot>(row.ConditionsJson, Rpg.Contracts.Serialization.RpgJson.Options)!,
                    System.Text.Json.JsonSerializer.Deserialize<ActionLog>(row.ActionLogJson, Rpg.Contracts.Serialization.RpgJson.Options)!,
                    row.Ruleset, rejected ? BattleSessionStatus.Rejected : BattleSessionStatus.Verified, row.SubmittedAt,
                    new BattleVerdict(session.Verdict, session.ErrorCode, session.Error, session.Mismatch, session.Outcome,
                        session.Turns, session.FinalStateHash, verdict.VerifierRulesetVersion, session.EngineVersion, now, session.Facts));
                if (!await redis.PublishVerdictAsync(new StoredBattle(row.PlayerId, response)))
                {
                    metrics.CacheError("set");
                }
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning("Post-commit work for step {Run}/{Step} failed (the verdict stands): {Message}", step.RunId,
                step.StepNo, ex.Message);
        }

        return Decide(new JobDecision(JobAction.Ack, result));
    }

    private JobDecision Decide(JobDecision decision)
    {
        metrics.StepJob(decision.Result);
        return decision;
    }
}
