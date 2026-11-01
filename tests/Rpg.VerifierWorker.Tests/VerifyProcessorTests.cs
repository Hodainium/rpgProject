using System.Text.Json;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Serialization;
using Rpg.Verification;
using Rpg.VerifierWorker.Tests.Infrastructure;
using StackExchange.Redis;
using static Rpg.VerifierWorker.Tests.Infrastructure.WorkerHarness;

namespace Rpg.VerifierWorker.Tests;

/// <summary>
/// Spec battle-verify 2.1 and 4 (F1, F2, F3, F5, F6, F7, F8, F9, F10, F12, F14): one job from start to decision, with the
/// fake runner standing in for Godot, a real Postgres and a real Redis.
/// </summary>
[Collection(StackCollection.Name)]
public class VerifyProcessorTests(Stack stack)
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task Verified_CommitsTheVerdict_FillsTheVerdictCache_AndDropsTheSubmittedCopy()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        var redis = await worker.RedisAsync();
        await redis.StringSetAsync(VerifyPolicy.SessionKey(battle.RunId, battle.Seq), "stale");

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(new JobDecision(JobAction.Ack, "verified"), decision);
        Assert.Equal("Verified", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        var verdict = JsonSerializer.Deserialize<BattleVerdict>(
            (await worker.ScalarAsync<string>("SELECT verdict::text FROM battle_sessions WHERE battle_id = $1", battle.BattleId))!,
            RpgJson.Options)!;
        Assert.Equal(ReplayVerdict.Verified, verdict.Status);
        Assert.Equal(FakeReplayRunner.Version, verdict.VerifierRulesetVersion);
        Assert.Equal("fake-engine", verdict.EngineVersion);
        Assert.Equal(1, await worker.ScalarAsync<int>("SELECT attempts FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        Assert.Equal(FakeReplayRunner.Version, await worker.ScalarAsync<string>("SELECT verifier_version FROM battle_sessions WHERE battle_id = $1", battle.BattleId));

        var cached = JsonSerializer.Deserialize<StoredBattle>(
            (await redis.StringGetAsync(VerifyPolicy.VerdictKey(battle.RunId, battle.Seq))).ToString(), RpgJson.Options)!;
        Assert.Equal(battle.PlayerId, cached.PlayerId);
        Assert.Equal(BattleSessionStatus.Verified, cached.Session.Status);
        Assert.Equal(ReplayVerdict.Verified, cached.Session.Verdict!.Status);
        Assert.False(await redis.KeyExistsAsync(VerifyPolicy.SessionKey(battle.RunId, battle.Seq)));  // F14
        var ttl = await redis.KeyTimeToLiveAsync(VerifyPolicy.VerdictKey(battle.RunId, battle.Seq));
        Assert.InRange(ttl!.Value, TimeSpan.FromMinutes(29), TimeSpan.FromMinutes(30));
        Assert.False(await redis.KeyExistsAsync(VerifyPolicy.LockKey(battle.BattleId)));  // released
        Assert.Equal(1, worker.Metrics.Count("rpg.verify_jobs", "result=verified"));
        Assert.Equal(1, worker.Metrics.Count("rpg.verify_latency.count"));
    }

    [Fact]
    public async Task ATakenJob_RenewsItsLease_SoTheSweeperNeverSeesItAsLost()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        await worker.ExecuteAsync("UPDATE battle_sessions SET enqueued_at = now() - interval '30 minutes' WHERE battle_id = $1", battle.BattleId);
        DateTime? during = null;
        worker.Runner.Handler = async (request, _) =>
        {
            during = await worker.ScalarAsync<DateTime?>("SELECT enqueued_at FROM battle_sessions WHERE battle_id = $1", battle.BattleId);
            return FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request));
        };

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.NotNull(during);
        Assert.True(DateTime.UtcNow - during!.Value < TimeSpan.FromMinutes(1), "the lease was renewed before the replay began");
    }

    [Fact]
    public async Task TheReplayRequest_CarriesTheStoredConditionsAndLog()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        using var request = JsonDocument.Parse(Assert.Single(worker.Runner.Requests));
        var snapshot = request.RootElement.GetProperty("snapshot");
        Assert.Equal(battle.BattleId, snapshot.GetProperty("battleId").GetString());
        Assert.Equal("1234567890123", snapshot.GetProperty("seed").GetString());
        Assert.Equal("Ability.Attack", request.RootElement.GetProperty("actionLog").GetProperty("actions")[0].GetProperty("ability").GetString());
        Assert.NotNull(JsonSerializer.Deserialize<ReplayRequest>(request.RootElement.GetRawText(), RpgJson.Options));
    }

    [Theory]
    [InlineData(MismatchReason.TurnMismatch)]
    [InlineData(MismatchReason.IllegalAbility)]
    [InlineData(MismatchReason.FinalHashMismatch)]
    [InlineData(MismatchReason.OutcomeMismatch)]
    public async Task Rejected_IsAVerdict2002_NotRetried(MismatchReason reason)
    {
        await using var worker = await CreateAsync(stack);
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Rejected(FakeReplayRunner.BattleIdOf(request), reason));
        var battle = await worker.SeedAsync();

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);  // F5

        Assert.Equal(new JobDecision(JobAction.Ack, "rejected"), decision);
        Assert.Equal("Rejected", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        var verdict = JsonSerializer.Deserialize<BattleVerdict>(
            (await worker.ScalarAsync<string>("SELECT verdict::text FROM battle_sessions WHERE battle_id = $1", battle.BattleId))!,
            RpgJson.Options)!;
        Assert.Equal(2002, verdict.ErrorCode);
        Assert.Equal("ReplayMismatch", verdict.Error);
        Assert.Equal(reason, verdict.Mismatch!.Reason);
        Assert.Equal(1, worker.Runner.Calls);
        Assert.Equal(1, worker.Metrics.Count("rpg.battle_rejections", $"reason={reason}"));
        Assert.Equal(1, worker.Metrics.Count("rpg.verify_jobs", "result=rejected"));
    }

    [Fact]
    public async Task SameJobTwice_OneVerdict_TheSecondIsADuplicate()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();

        var first = await worker.Processor.ProcessAsync(JobOf(battle), Ct);
        var second = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal("verified", first.Result);
        Assert.Equal(new JobDecision(JobAction.Ack, "duplicate"), second);  // F1, scenario 1
        Assert.Equal(1, worker.Runner.Calls);
        Assert.Equal(1, worker.Metrics.Count("rpg.verify_jobs", "result=duplicate"));
    }

    [Fact]
    public async Task ConcurrentWorkers_WithoutTheLock_StillOneVerdict()
    {
        await using var worker = await CreateAsync(stack, new() { ["Verifier:UseLock"] = "false" });
        var battle = await worker.SeedAsync();
        var gate = new TaskCompletionSource();
        var arrived = 0;
        worker.Runner.Handler = async (request, _) =>
        {
            if (Interlocked.Increment(ref arrived) == 2)
            {
                gate.SetResult();  // both replays are running at once
            }

            await gate.Task;
            return FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request));
        };

        var decisions = await Task.WhenAll(
            worker.Processor.ProcessAsync(JobOf(battle), Ct), worker.Processor.ProcessAsync(JobOf(battle), Ct));

        Assert.Equal(2, worker.Runner.Calls);  // F2: both replayed, the guarded update let one win
        Assert.Equal(["duplicate", "verified"], decisions.Select(d => d.Result).Order());
        Assert.All(decisions, d => Assert.Equal(JobAction.Ack, d.Action));
        Assert.Equal(1, await worker.ScalarAsync<int>("SELECT attempts FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
    }

    [Fact]
    public async Task LockHeldByAnotherWorker_RetriesSoonWithoutCountingAnAttempt()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        var redis = await worker.RedisAsync();
        await redis.StringSetAsync(VerifyPolicy.LockKey(battle.BattleId), "someone-else", TimeSpan.FromMinutes(1));

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(JobAction.Retry, decision.Action);
        Assert.Equal("lock_busy", decision.Result);
        Assert.Equal(TimeSpan.FromSeconds(5), decision.Tier!.Delay);
        Assert.Equal(0, worker.Runner.Calls);
        Assert.Equal(0, await worker.ScalarAsync<int>("SELECT attempts FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        Assert.Equal("someone-else", (await redis.StringGetAsync(VerifyPolicy.LockKey(battle.BattleId))).ToString());  // not ours to release
        Assert.Equal(1, worker.Metrics.Count("rpg.verify_lock", "result=busy"));
    }

    [Fact]
    public async Task CrashAfterTheCommit_TheRedeliveredJobIsANoOp()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        worker.Processor.AfterCommit = () => throw new InvalidOperationException("the worker died here");

        // The first delivery commits, then "dies" before its ack: the exception leaves ProcessAsync's decision unseen.
        await Assert.ThrowsAsync<InvalidOperationException>(() => worker.Processor.ProcessAsync(JobOf(battle), Ct));
        worker.Processor.AfterCommit = null;
        var redelivered = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(new JobDecision(JobAction.Ack, "duplicate"), redelivered);  // F3, scenario 2 (verdict half)
        Assert.Equal(1, worker.Runner.Calls);
        Assert.Equal("Verified", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        Assert.Equal(1, await worker.ScalarAsync<int>("SELECT attempts FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
    }

    [Fact]
    public async Task RunnerErrors_RetryOnTheTiers_ThenDeadLetterAtTheLimit()
    {
        await using var worker = await CreateAsync(stack);
        worker.Runner.Handler = (_, _) => Task.FromResult(FakeReplayRunner.Error());
        var battle = await worker.SeedAsync();

        var decisions = new List<JobDecision>();
        for (var i = 0; i < 5; i++)
        {
            decisions.Add(await worker.Processor.ProcessAsync(JobOf(battle), Ct));
        }

        Assert.Equal([TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(120), TimeSpan.FromSeconds(120)],
            decisions.Take(4).Select(d => d.Tier!.Delay));  // F6
        Assert.All(decisions.Take(4), d => Assert.Equal(JobAction.Retry, d.Action));
        Assert.Equal([1, 2, 3, 4], decisions.Take(4).Select(d => d.Attempt));
        Assert.Equal(new JobDecision(JobAction.DeadLetter, "dead_lettered", Reason: "attempts", Attempt: 5), decisions[4]);
        Assert.Equal("Submitted", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        Assert.Equal(5, await worker.ScalarAsync<int>("SELECT attempts FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        Assert.Equal("attempts", await worker.ScalarAsync<string>("SELECT dead_letter_reason FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        Assert.NotNull(await worker.ScalarAsync<DateTime?>("SELECT dead_lettered_at FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        Assert.Equal(4, worker.Metrics.Count("rpg.verify_jobs", "result=retry"));
        Assert.Equal(5, worker.Metrics.Count("rpg.verify_replay_duration.count", "result=error"));
    }

    [Fact]
    public async Task ARunnerThatTimesOutOrThrows_IsARunnerError()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        worker.Runner.Handler = (_, _) => Task.FromResult(new ReplayRun(ReplayRunStatus.TimedOut, null, "killed"));
        var timedOut = await worker.Processor.ProcessAsync(JobOf(battle), Ct);
        worker.Runner.Handler = (_, _) => throw new InvalidOperationException("the runner broke");
        var threw = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal((JobAction.Retry, 1), (timedOut.Action, timedOut.Attempt));  // F7
        Assert.Equal((JobAction.Retry, 2), (threw.Action, threw.Attempt));
    }

    [Fact]
    public async Task AResultForAnotherBattle_IsARunnerError()
    {
        await using var worker = await CreateAsync(stack);
        worker.Runner.Handler = (_, _) => Task.FromResult(FakeReplayRunner.Verified("some-other-battle"));
        var battle = await worker.SeedAsync();

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(JobAction.Retry, decision.Action);
        Assert.Equal("Submitted", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
    }

    [Fact]
    public async Task AFailureAfterTheCommit_NeverChangesTheDecision()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        // Valid JSON that is not a BattleSnapshot: the post-commit work (building the cached session) cannot read it.
        await worker.ExecuteAsync("UPDATE battle_sessions SET conditions = '{\"battleId\": 5}'::jsonb WHERE battle_id = $1", battle.BattleId);
        worker.Runner.Handler = (_, _) => Task.FromResult(FakeReplayRunner.Verified(battle.BattleId));

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(new JobDecision(JobAction.Ack, "verified"), decision);  // not a dead letter: the battle is decided
        Assert.Equal("Verified", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
    }

    [Fact]
    public async Task UnknownBattle_IsPoison()
    {
        await using var worker = await CreateAsync(stack);

        var decision = await worker.Processor.ProcessAsync(
            new VerifyBattleJob("nope/f0/c1", Guid.NewGuid(), 2, FakeReplayRunner.Version, DateTimeOffset.UtcNow), Ct);

        Assert.Equal(JobAction.DeadLetter, decision.Action);  // F8
        Assert.Equal("poison: unknown battle", decision.Reason);
        Assert.Equal(0, worker.Runner.Calls);
    }

    [Fact]
    public async Task WrongRuleset_DeadLettersAndLeavesTheSessionSubmitted()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync(ruleset: "4.7.2.stable.mono+ffffffffffffffff");

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(new JobDecision(JobAction.DeadLetter, "wrong_ruleset", Reason: "ruleset"), decision);  // F9
        Assert.Equal(0, worker.Runner.Calls);
        Assert.Equal("Submitted", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        Assert.Equal("ruleset", await worker.ScalarAsync<string>("SELECT dead_letter_reason FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
    }

    [Fact]
    public async Task AcceptedRulesets_WidenWhatTheWorkerVerifies()
    {
        await using var worker = await CreateAsync(stack, new() { ["Verifier:AcceptedRulesets:0"] = "4.7.2.stable.mono+ffffffffffffffff" });
        var battle = await worker.SeedAsync(ruleset: "4.7.2.stable.mono+ffffffffffffffff");

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal("verified", decision.Result);
    }

    [Fact]
    public async Task APermanentSqlError_IsNotTreatedAsPostgresBeingDown()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        // The verdict commit now violates a constraint every time: not an outage, so it must not be postponed for ever.
        await worker.ExecuteAsync("ALTER TABLE battle_sessions ADD CONSTRAINT never_verified CHECK (status = 'Submitted') NOT VALID");

        var failure = await Assert.ThrowsAsync<Npgsql.PostgresException>(() => worker.Processor.ProcessAsync(JobOf(battle), Ct));

        Assert.Equal("never_verified", failure.ConstraintName);
    }

    [Fact]
    public async Task PostgresDown_PostponesWithoutCountingAnAttempt()
    {
        await using var worker = await CreateAsync(stack,
            postgres: "Host=127.0.0.1;Port=1;Database=x;Username=x;Timeout=2;Command Timeout=2");
        var job = new VerifyBattleJob("a/f0/c1", Guid.NewGuid(), 2, FakeReplayRunner.Version, DateTimeOffset.UtcNow);

        var decision = await worker.Processor.ProcessAsync(job, Ct);

        Assert.Equal(JobAction.Retry, decision.Action);  // F12
        Assert.Equal(TimeSpan.FromSeconds(30), decision.Tier!.Delay);
        Assert.Equal(0, decision.Attempt);
        Assert.Equal(0, worker.Runner.Calls);
    }

    [Fact]
    public async Task RedisDown_StillVerifies_AndCountsTheErrors()
    {
        await using var worker = await CreateAsync(stack, redis: "127.0.0.1:1,abortConnect=false,connectTimeout=500,syncTimeout=500");
        var battle = await worker.SeedAsync();

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal("verified", decision.Result);  // F10
        Assert.Equal("Verified", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        Assert.Equal(1, worker.Metrics.Count("rpg.verify_lock", "result=redis_error"));
        Assert.Equal(1, worker.Metrics.Count("rpg.cache_errors", "operation=set"));
    }

    [Fact]
    public async Task AFlushedRedis_ChangesNothingForTheVerdict()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        var admin = await ConnectionMultiplexer.ConnectAsync(stack.RedisConnectionString + ",allowAdmin=true");
        await admin.GetServer(admin.GetEndPoints()[0]).FlushAllDatabasesAsync();

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal("verified", decision.Result);  // scenario 4
    }

    private static Task<WorkerHarness> CreateAsync(Stack stack, Dictionary<string, string?>? settings = null,
        string? postgres = null, string? redis = null) =>
        WorkerHarness.CreateAsync(stack, settings, postgres, redis);
}
