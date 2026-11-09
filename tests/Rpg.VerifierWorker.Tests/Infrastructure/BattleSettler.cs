using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using Npgsql;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Serialization;
using Rpg.Economy;
using Rpg.Verification;

namespace Rpg.VerifierWorker.Tests.Infrastructure;

public sealed record ReplayRun(ReplayRunStatus Status, ReplayResult? Result, string Detail, ReplayUsage? Usage = null);

/// <summary>
/// Settles one seeded battle the way a verifier step does (spec run-verify 2.2, 2.5): the guarded verdict and the settlement
/// in one transaction with the gems pending, then the pending rows released as if the run's verified prefix reached the
/// battle. The code under test is production's (<see cref="VerdictStore.CommitInTransactionAsync"/>, <see cref="PendingGems"/>);
/// only the replay (a <see cref="FakeReplayRunner"/>) and the loop around it belong to the test. The settlement tests
/// (settlement-outbox 2.2, economy-rewards, economy-challenges) were written against the per-battle worker, which is gone.
/// </summary>
public sealed class BattleSettler(IServiceProvider services, FakeReplayRunner runner)
{
    /// <summary>Runs between the commit and the return, where a worker could die before the ack.</summary>
    public Func<Task>? AfterCommit { get; set; }

    public async Task<JobDecision> ProcessAsync(VerifyBattleJob job, CancellationToken ct)
    {
        var data = services.GetRequiredService<NpgsqlDataSource>();
        var clock = services.GetRequiredService<TimeProvider>();
        var metrics = services.GetRequiredService<WorkerMetrics>();
        var redis = services.GetRequiredService<VerifierRedis>();
        var state = services.GetRequiredService<WorkerState>();
        var settlement = services.GetRequiredService<IOptions<SettlementOptions>>().Value;

        var row = await LoadAsync(data, job.BattleId, ct);
        if (row is null)
        {
            return new JobDecision(JobAction.DeadLetter, "dead_lettered", Reason: "poison: unknown battle");
        }

        if (row.Status != nameof(BattleSessionStatus.Submitted))
        {
            return new JobDecision(JobAction.Ack, "duplicate");
        }

        using var activity = WorkerTrace.Source.StartActivity("godot.replay");
        var run = await runner.ReplayAsync($$"""{"snapshot":{{row.ConditionsJson}},"actionLog":{{row.ActionLogJson}}}""", ct);
        if (run.Status != ReplayRunStatus.Completed || run.Result is not { } result)
        {
            return new JobDecision(JobAction.Retry, "retry", VerifyPolicy.TierForAttempt(1), Attempt: 1);
        }

        var now = clock.GetUtcNow();
        var verdict = new BattleVerdict(result.Verdict, result.ErrorCode, result.Error, result.Mismatch, result.Outcome,
            result.Turns, result.FinalStateHash, state.RulesetVersion, result.EngineVersion, now, result.Facts);
        CommitResult commit;
        await using (var connection = await data.OpenConnectionAsync(ct))
        await using (var transaction = await connection.BeginTransactionAsync(ct))
        {
            commit = await VerdictStore.CommitInTransactionAsync(connection, transaction, row, verdict, settlement, now, pending: true, ct);
            if (!commit.Committed)
            {
                await transaction.RollbackAsync(CancellationToken.None);
                return new JobDecision(JobAction.Ack, "duplicate");
            }

            await PendingGems.ReleaseAsync(connection, transaction, row.RunId, row.RunSeq, now, ct);
            await transaction.CommitAsync(ct);
        }

        if (AfterCommit is { } hook)
        {
            await hook();
        }

        metrics.Settlement(commit.Result switch
        {
            SettlementResult.Granted => "granted",
            SettlementResult.AlreadyMarked => "already_marked",
            SettlementResult.Rejected => "rejected",
            SettlementResult.NoRule => "no_rule",
            SettlementResult.BadId => "bad_id",
            SettlementResult.IgnoredFact => "ignored_fact",
            _ => "no_reward",
        });
        if (commit.Settlement is { } settled)
        {
            metrics.RewardRuleLookups("found", settled.Found);
            metrics.RewardRuleLookups("missing", settled.Missing);
            metrics.RewardRuleLookups("retired", settled.Retired);
            metrics.RewardRuleLookups("expired", settled.Expired);
            metrics.CompletionMarks("new", settled.MarksNew);
            metrics.CompletionMarks("existing", settled.MarksExisting);
        }

        if (commit.Grants.Count > 0)
        {
            metrics.GemsGranted("completion_mark", commit.Grants.Sum(g => g.Gems));
            if (!await redis.InvalidateWalletAsync(row.PlayerId))
            {
                metrics.CacheError("delete");
            }
        }

        return new JobDecision(JobAction.Ack, result.Verdict == ReplayVerdict.Verified ? "verified" : "rejected");
    }

    private static async Task<BattleRow?> LoadAsync(NpgsqlDataSource data, string battleId, CancellationToken ct)
    {
        await using var command = data.CreateCommand(
            """
            SELECT b.run_id, b.run_seq, r.player_id, b.status, b.ruleset_version, b.conditions::text, b.action_log::text,
                   b.submitted_at, b.attempts
            FROM battle_sessions b JOIN runs r ON r.run_id = b.run_id
            WHERE b.battle_id = $1
            """);
        command.Parameters.Add(new NpgsqlParameter { Value = battleId });
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct)
            ? new BattleRow(battleId, reader.GetGuid(0), reader.GetInt32(1), reader.GetGuid(2), reader.GetString(3),
                reader.GetString(4), reader.GetString(5), reader.GetString(6), reader.GetFieldValue<DateTimeOffset>(7),
                reader.GetInt32(8))
            : null;
    }
}

/// <summary>A canned replay of one battle: what the removed per-battle worker got from Godot, for <see cref="BattleSettler"/>.</summary>
public sealed class FakeReplayRunner
{
    private readonly List<string> _requests = [];
    private int _calls;

    public const string Version = "4.7.2.stable.mono+aaaaaaaaaaaaaaaa";

    /// <summary>What a replay returns; the default verifies the battle in the request.</summary>
    public Func<string, CancellationToken, Task<ReplayRun>>? Handler { get; set; }

    public int Calls => Volatile.Read(ref _calls);

    public IReadOnlyList<string> Requests
    {
        get
        {
            lock (_requests)
            {
                return [.. _requests];
            }
        }
    }

    public Task<ReplayRun> ReplayAsync(string requestJson, CancellationToken ct)
    {
        Interlocked.Increment(ref _calls);
        lock (_requests)
        {
            _requests.Add(requestJson);
        }

        return (Handler ?? ((request, _) => Task.FromResult(Verified(BattleIdOf(request)))))(requestJson, ct);
    }


    public static string BattleIdOf(string requestJson)
    {
        using var document = JsonDocument.Parse(requestJson);
        return document.RootElement.GetProperty("snapshot").GetProperty("battleId").GetString()!;
    }

    public static ReplayRun Verified(string battleId, BattleFacts? facts = null, BattleOutcome outcome = BattleOutcome.Victory) =>
        new(ReplayRunStatus.Completed,
            new ReplayResult(1, battleId, ReplayVerdict.Verified, null, null, null, outcome, 12,
                new string('c', 64), "fake-engine", facts), "");

    public static ReplayRun Rejected(string battleId, MismatchReason reason = MismatchReason.FinalHashMismatch) => new(
        ReplayRunStatus.Completed,
        new ReplayResult(1, battleId, ReplayVerdict.Rejected, ReplayErrors.ReplayMismatchCode,
            ReplayErrors.ReplayMismatchName, new ReplayMismatch(reason, 4, "tampered"), BattleOutcome.Victory, 12,
            new string('d', 64), "fake-engine"), "");

    public static ReplayRun Error(string detail = "boom") => new(ReplayRunStatus.RunnerError, null, detail);
}

