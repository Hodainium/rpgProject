using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using Rpg.Client;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Battle;
using Rpg.GameServerApi.Runs;
using Rpg.GameServerApi.Tests.Infrastructure;
using Rpg.Verification;
using StackExchange.Redis;
using static Rpg.GameServerApi.Tests.RunTests;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Spec battle-verify, the API half (sections 2.1, 2.2, 2.4, 3.2, 3.4, 5): a battle upload becomes one verify job, the
/// reconciler republishes a lost one, the endpoint serves the verdict (a rejection is a 200), and the caches never
/// hold a stale Submitted copy. The worker half is in Rpg.VerifierWorker.Tests.
/// </summary>
[Collection(StackCollection.Name)]
public class BattleVerifyTests(StackFixture stack)
{
    private static readonly RunStartRequest Start =
        new(ApiFactory.TestRuleset, "descent", ["warrior", "cleric", "ranger"]);

    private static readonly Dictionary<string, string?> QuietBackground = new()
    {
        ["Verifier:SweepInterval"] = "01:00:00",
        ["Monitors:Interval"] = "01:00:00",
        ["Verifier:SweepGrace"] = "00:00:00",  // tests sweep what they just uploaded; the grace has a test of its own
    };

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task Migration_VerdictColumnsExist_AndTheVerdictConstraintHolds()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        var id = $"{run.RunId}/f0/c5";

        var noVerdict = await Assert.ThrowsAsync<PostgresException>(() =>
            ExecuteAsync(factory, $"UPDATE battle_sessions SET status = 'Verified' WHERE battle_id = '{id}'"));
        var unknownStatus = await Assert.ThrowsAsync<PostgresException>(() =>
            ExecuteAsync(factory, $"UPDATE battle_sessions SET status = 'Pending' WHERE battle_id = '{id}'"));
        var submittedWithVerdict = await Assert.ThrowsAsync<PostgresException>(() =>
            ExecuteAsync(factory, $"UPDATE battle_sessions SET verdict = '{{}}' WHERE battle_id = '{id}'"));

        Assert.Equal("battle_sessions_verdict_set", noVerdict.ConstraintName);
        Assert.Equal("battle_sessions_status", unknownStatus.ConstraintName);
        Assert.Equal("battle_sessions_verdict_set", submittedWithVerdict.ConstraintName);
    }

    [Fact]
    public async Task Upload_Battle_PublishesOneJob_AndMarksItEnqueued()
    {
        await using var probe = await RabbitProbe.OpenAsync(stack.RabbitMqUri);
        await probe.PurgeAsync();
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);

        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        var jobs = await probe.TakeAsync();
        await WaitAsync(async () => await ScalarAsync(factory,
            $"SELECT count(*) FROM battle_sessions WHERE run_id = '{run.RunId}' AND enqueued_at IS NOT NULL") == 1);

        var (job, attempt) = Assert.Single(jobs);
        Assert.Equal($"{run.RunId}/f0/c5", job.BattleId);
        Assert.Equal(Guid.Parse(run.RunId), job.RunId);
        Assert.Equal(2, job.RunSeq);
        Assert.Equal(ApiFactory.TestRuleset, job.RulesetVersion);
        Assert.Equal(0, attempt);
        Assert.Equal(1L, await ScalarAsync(factory,
            $"SELECT count(*) FROM battle_sessions WHERE run_id = '{run.RunId}' AND enqueued_at IS NOT NULL"));
    }

    [Fact]
    public async Task Upload_SameBattleAgain_PublishesNothingNew()
    {
        await using var probe = await RabbitProbe.OpenAsync(stack.RabbitMqUri);
        await probe.PurgeAsync();
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);
        var batch = RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2));

        await client.SendActionsAsync(run.RunId, batch, Ct);
        await client.SendActionsAsync(run.RunId, batch, Ct);
        await Task.Delay(500, Ct);  // a second job would be published right after the second response
        var jobs = await probe.TakeAsync();

        Assert.Single(jobs);  // F1: one session, one job
        Assert.Equal(1L, await ScalarAsync(factory, $"SELECT count(*) FROM battle_sessions WHERE run_id = '{run.RunId}'"));
    }

    [Fact]
    public async Task Upload_BrokerDown_StillStores_AndTheSweeperFailsQuietly()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>(QuietBackground)
        {
            ["RabbitMq:Uri"] = "amqp://guest:guest@127.0.0.1:1/",
        });
        var (client, run) = await StartedAsync(factory);

        var ack = await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        var sweep = await factory.Services.GetRequiredService<BattleVerifyDispatcher>().SweepOnceAsync(Ct);

        Assert.Equal(2, ack.LastSeq);  // F11: the upload never depends on the broker
        Assert.Equal((0, 1), sweep);
        Assert.Equal(1L, await ScalarAsync(factory,
            $"SELECT count(*) FROM battle_sessions WHERE run_id = '{run.RunId}' AND enqueued_at IS NULL"));
    }

    [Fact]
    public async Task Sweeper_PublishesAJobWhoseFastPathWasLost()
    {
        await using var probe = await RabbitProbe.OpenAsync(stack.RabbitMqUri);
        await probe.PurgeAsync();
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        await WaitAsync(async () => await probe.DepthAsync(VerifyTopology.Queue) == 1);  // the fast path has published
        await probe.PurgeAsync();  // the fast path's job is gone, as if the publish had been lost
        await ExecuteAsync(factory, $"UPDATE battle_sessions SET enqueued_at = NULL WHERE run_id = '{run.RunId}'");

        var sweep = await factory.Services.GetRequiredService<BattleVerifyDispatcher>().SweepOnceAsync(Ct);
        var again = await factory.Services.GetRequiredService<BattleVerifyDispatcher>().SweepOnceAsync(Ct);
        var jobs = await probe.TakeAsync();

        Assert.Equal((1, 0), sweep);
        Assert.Equal((0, 0), again);  // enqueued_at is fresh now
        Assert.Equal($"{run.RunId}/f0/c5", Assert.Single(jobs).Job.BattleId);
    }

    [Fact]
    public async Task Sweeper_RepublishesAfterTheWindow_AndSkipsVerifiedAndDeadLettered()
    {
        await using var probe = await RabbitProbe.OpenAsync(stack.RabbitMqUri);
        await probe.PurgeAsync();
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2, cell: 1), RunLog.Battle(run.RunId, 3, cell: 2),
                RunLog.Battle(run.RunId, 4, cell: 3), RunLog.Battle(run.RunId, 5, cell: 4)), Ct);
        await WaitAsync(async () => await probe.DepthAsync(VerifyTopology.Queue) == 4);
        await probe.PurgeAsync();
        var old = "now() - interval '30 minutes'";
        await ExecuteAsync(factory, $"UPDATE battle_sessions SET enqueued_at = {old} WHERE run_id = '{run.RunId}'");
        await ExecuteAsync(factory,  // c2: dead-lettered; c3: verified; c4: enqueued a moment ago
            $"UPDATE battle_sessions SET dead_lettered_at = now(), dead_letter_reason = 'attempts' WHERE battle_id = '{run.RunId}/f0/c2'");
        await SetVerdictAsync(factory, $"{run.RunId}/f0/c3", Verdict(ReplayVerdict.Verified));
        await ExecuteAsync(factory, $"UPDATE battle_sessions SET enqueued_at = now() WHERE battle_id = '{run.RunId}/f0/c4'");

        var sweep = await factory.Services.GetRequiredService<BattleVerifyDispatcher>().SweepOnceAsync(Ct);
        var jobs = await probe.TakeAsync();

        Assert.Equal((1, 0), sweep);
        Assert.Equal($"{run.RunId}/f0/c1", Assert.Single(jobs).Job.BattleId);
    }

    [Fact]
    public async Task Sweeper_DuringABacklog_NeverDoublesAJobThatIsStillQueued_ButRecoversALostOneOnceTheQueuesAreEmpty()
    {
        await using var probe = await RabbitProbe.OpenAsync(stack.RabbitMqUri);
        await probe.PurgeAsync();
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2, cell: 1), RunLog.Battle(run.RunId, 3, cell: 2)), Ct);
        await WaitAsync(async () => await probe.DepthAsync(VerifyTopology.Queue) == 2);  // two jobs wait for a worker
        // The backlog is older than RepublishAfter: the jobs are still in the queue, not lost.
        await ExecuteAsync(factory, $"UPDATE battle_sessions SET enqueued_at = now() - interval '30 minutes' WHERE run_id = '{run.RunId}'");
        var sweeper = factory.Services.GetRequiredService<BattleVerifyDispatcher>();

        var during = await sweeper.SweepOnceAsync(Ct);
        var depthAfter = await probe.DepthAsync(VerifyTopology.Queue);
        await probe.PurgeAsync();  // now the messages really are gone
        var afterLoss = await sweeper.SweepOnceAsync(Ct);

        Assert.Equal((0, 0), during);
        Assert.Equal(2u, depthAfter);  // no duplicate was published
        Assert.Equal((2, 0), afterLoss);
        Assert.Equal(2u, await probe.DepthAsync(VerifyTopology.Queue));
    }

    [Fact]
    public async Task Sweeper_AJobWithAFreshLease_IsLeftAloneEvenWhenTheQueuesAreEmpty()
    {
        await using var probe = await RabbitProbe.OpenAsync(stack.RabbitMqUri);
        await probe.PurgeAsync();
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        await WaitAsync(async () => await probe.DepthAsync(VerifyTopology.Queue) == 1);
        await probe.PurgeAsync();  // a worker took the job: the queue is empty, the job is being replayed
        await ExecuteAsync(factory, $"UPDATE battle_sessions SET enqueued_at = now() WHERE run_id = '{run.RunId}'");  // its renewed lease

        var sweep = await factory.Services.GetRequiredService<BattleVerifyDispatcher>().SweepOnceAsync(Ct);

        Assert.Equal((0, 0), sweep);
    }

    [Fact]
    public async Task Sweeper_WhenTheBrokerCannotBeAsked_RepublishesNothingStale()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>(QuietBackground)
        {
            ["RabbitMq:Uri"] = "amqp://guest:guest@127.0.0.1:1/",
        });
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        await ExecuteAsync(factory, $"UPDATE battle_sessions SET enqueued_at = now() - interval '30 minutes' WHERE run_id = '{run.RunId}'");

        var sweep = await factory.Services.GetRequiredService<BattleVerifyDispatcher>().SweepOnceAsync(Ct);

        Assert.Equal((0, 0), sweep);  // unknown backlog counts as waiting: the stale branch stays off
    }

    [Fact]
    public async Task Sweeper_LeavesAYoungSessionToTheUploadsOwnPublish()
    {
        await using var probe = await RabbitProbe.OpenAsync(stack.RabbitMqUri);
        await probe.PurgeAsync();
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>(QuietBackground)
        {
            ["Verifier:SweepGrace"] = "00:00:30",
        });
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        await WaitAsync(async () => await probe.DepthAsync(VerifyTopology.Queue) == 1);
        await probe.PurgeAsync();
        await ExecuteAsync(factory, $"UPDATE battle_sessions SET enqueued_at = NULL WHERE run_id = '{run.RunId}'");
        var sweeper = factory.Services.GetRequiredService<BattleVerifyDispatcher>();

        var young = await sweeper.SweepOnceAsync(Ct);  // its fast path may still be publishing
        await ExecuteAsync(factory, $"UPDATE battle_sessions SET submitted_at = now() - interval '1 minute' WHERE run_id = '{run.RunId}'");
        var older = await sweeper.SweepOnceAsync(Ct);

        Assert.Equal((0, 0), young);
        Assert.Equal((1, 0), older);
    }

    [Fact]
    public async Task Sweeper_AFailedPublish_GivesTheLeaseBack()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2, cell: 1), RunLog.Battle(run.RunId, 3, cell: 2)), Ct);
        await ExecuteAsync(factory, $"UPDATE battle_sessions SET enqueued_at = NULL WHERE run_id = '{run.RunId}'");
        var store = factory.Services.GetRequiredService<RunStore>();
        var attempts = 0;

        var sweep = await store.SweepUnenqueuedAsync((_, _) => Task.FromResult(++attempts == 1 ? true : false), 100,
            TimeSpan.FromMinutes(10), true, TimeSpan.Zero, DateTimeOffset.UtcNow, Ct);

        Assert.Equal((1, 1), sweep);  // one published, the second failed
        Assert.Equal(1L, await ScalarAsync(factory,
            $"SELECT count(*) FROM battle_sessions WHERE run_id = '{run.RunId}' AND enqueued_at IS NULL"));
        Assert.Equal(1L, await ScalarAsync(factory,
            $"SELECT count(*) FROM battle_sessions WHERE run_id = '{run.RunId}' AND enqueued_at IS NOT NULL"));
    }

    [Fact]
    public async Task Sweeper_APublishThatThrows_GivesTheLeasesBack()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2, cell: 1), RunLog.Battle(run.RunId, 3, cell: 2)), Ct);
        await ExecuteAsync(factory, $"UPDATE battle_sessions SET enqueued_at = NULL WHERE run_id = '{run.RunId}'");
        var store = factory.Services.GetRequiredService<RunStore>();

        await Assert.ThrowsAsync<OperationCanceledException>(() => store.SweepUnenqueuedAsync(
            (_, _) => throw new OperationCanceledException(), 100, TimeSpan.FromMinutes(10), true, TimeSpan.Zero,
            DateTimeOffset.UtcNow, Ct));  // shutdown in the middle of a sweep

        Assert.Equal(2L, await ScalarAsync(factory,
            $"SELECT count(*) FROM battle_sessions WHERE run_id = '{run.RunId}' AND enqueued_at IS NULL"));
    }

    [Fact]
    public async Task Sweeper_DoesNotHoldRowLocksWhilePublishing()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        await ExecuteAsync(factory, $"UPDATE battle_sessions SET enqueued_at = NULL WHERE run_id = '{run.RunId}'");
        var store = factory.Services.GetRequiredService<RunStore>();
        var publishing = new TaskCompletionSource();
        var release = new TaskCompletionSource();

        var sweep = store.SweepUnenqueuedAsync(async (_, _) =>
        {
            publishing.SetResult();
            await release.Task;  // a slow broker confirm
            return true;
        }, 100, TimeSpan.FromMinutes(10), true, TimeSpan.Zero, DateTimeOffset.UtcNow, Ct);
        await publishing.Task;
        // The verifier's commit must not wait for the sweep.
        var commit = ExecuteAsync(factory,
            $"UPDATE battle_sessions SET status = 'Verified', verdict = '{{}}'::jsonb WHERE run_id = '{run.RunId}'");

        await commit.WaitAsync(TimeSpan.FromSeconds(5), Ct);
        release.SetResult();
        Assert.Equal((1, 0), await sweep);
    }

    [Fact]
    public async Task Sweeper_TwoInstancesAtOnce_NeverPublishTheSameRowTwice()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2, cell: 1), RunLog.Battle(run.RunId, 3, cell: 2),
                RunLog.Battle(run.RunId, 4, cell: 3)), Ct);
        await ExecuteAsync(factory, $"UPDATE battle_sessions SET enqueued_at = NULL WHERE run_id = '{run.RunId}'");
        var store = factory.Services.GetRequiredService<RunStore>();
        var published = new System.Collections.Concurrent.ConcurrentBag<string>();
        async Task<bool> Slow(VerifyBattleJob job, CancellationToken ct)
        {
            published.Add(job.BattleId);
            await Task.Delay(300, ct);
            return true;
        }

        var now = DateTimeOffset.UtcNow;
        await Task.WhenAll(
            store.SweepUnenqueuedAsync(Slow, 100, TimeSpan.FromMinutes(10), true, TimeSpan.Zero, now, Ct),
            store.SweepUnenqueuedAsync(Slow, 100, TimeSpan.FromMinutes(10), true, TimeSpan.Zero, now, Ct));

        Assert.Equal(3, published.Count);
        Assert.Equal(3, published.Distinct().Count());  // F13: SKIP LOCKED
    }

    [Fact]
    public async Task GetBattle_SubmittedVerifiedRejected_ShowTheVerdict_AndARejectionIs200()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (alice, run) = await StartedAsync(factory);
        var bob = await ClientAsync(factory, "bob");
        await alice.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2, cell: 1), RunLog.Battle(run.RunId, 3, cell: 2)), Ct);

        var submitted = await alice.GetBattleAsync(run.RunId, 2, Ct);
        await SetVerdictAsync(factory, $"{run.RunId}/f0/c1", Verdict(ReplayVerdict.Verified));
        await SetVerdictAsync(factory, $"{run.RunId}/f0/c2", Verdict(ReplayVerdict.Rejected, MismatchReason.FinalHashMismatch));
        await FlushBattleKeysAsync(run.RunId);
        var verified = await alice.GetBattleAsync(run.RunId, 2, Ct);
        var rejected = await alice.GetBattleAsync(run.RunId, 3, Ct);
        var other = await Assert.ThrowsAsync<GameServerApiException>(() => bob.GetBattleAsync(run.RunId, 3, Ct));

        Assert.Equal(BattleSessionStatus.Submitted, submitted.Status);
        Assert.Null(submitted.Verdict);
        Assert.Equal(BattleSessionStatus.Verified, verified.Status);
        Assert.Equal(ReplayVerdict.Verified, verified.Verdict!.Status);
        Assert.Null(verified.Verdict.ErrorCode);
        Assert.Equal(BattleSessionStatus.Rejected, rejected.Status);
        Assert.Equal(ReplayErrors.ReplayMismatchCode, rejected.Verdict!.ErrorCode);
        Assert.Equal(ReplayErrors.ReplayMismatchName, rejected.Verdict.Error);
        Assert.Equal(MismatchReason.FinalHashMismatch, rejected.Verdict.Mismatch!.Reason);
        Assert.Equal(System.Net.HttpStatusCode.NotFound, other.StatusCode);  // a verdict is not another player's to read
    }

    [Fact]
    public async Task GetBattle_Verdict_IsCachedForThirtyMinutes_AndSubmittedForTenSeconds()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        await ReadyProbe.WaitUntilAsync(factory.CreateClient(), r => r.StatusOf("redis") == "Healthy");
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2, cell: 1), RunLog.Battle(run.RunId, 3, cell: 2)), Ct);
        await SetVerdictAsync(factory, $"{run.RunId}/f0/c2", Verdict(ReplayVerdict.Verified));
        var redis = await ConnectionMultiplexer.ConnectAsync(stack.RedisConnectionString);
        var runId = Guid.Parse(run.RunId);

        await client.GetBattleAsync(run.RunId, 2, Ct);
        await client.GetBattleAsync(run.RunId, 3, Ct);

        var submittedTtl = await redis.GetDatabase().KeyTimeToLiveAsync(BattleSessionCache.Key(runId, 2));
        var verdictTtl = await redis.GetDatabase().KeyTimeToLiveAsync(BattleSessionCache.VerdictKey(runId, 3));
        Assert.InRange(submittedTtl!.Value, TimeSpan.Zero, TimeSpan.FromSeconds(10));
        Assert.InRange(verdictTtl!.Value, TimeSpan.FromMinutes(29), TimeSpan.FromMinutes(30));
        Assert.False(await redis.GetDatabase().KeyExistsAsync(BattleSessionCache.VerdictKey(runId, 2)));
        Assert.False(await redis.GetDatabase().KeyExistsAsync(BattleSessionCache.Key(runId, 3)));
    }

    [Fact]
    public async Task GetBattle_RedisFlushed_IsServedFromPostgres()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        await ReadyProbe.WaitUntilAsync(factory.CreateClient(), r => r.StatusOf("redis") == "Healthy");
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        await SetVerdictAsync(factory, $"{run.RunId}/f0/c5", Verdict(ReplayVerdict.Rejected, MismatchReason.TurnMismatch));
        var first = await client.GetBattleAsync(run.RunId, 2, Ct);

        await FlushBattleKeysAsync(run.RunId);  // scenario 4
        var second = await client.GetBattleAsync(run.RunId, 2, Ct);

        Assert.Equal(JsonSerializer.Serialize(first, RpgJson.Options), JsonSerializer.Serialize(second, RpgJson.Options));
        Assert.Equal(BattleSessionStatus.Rejected, second.Status);
    }

    [Fact]
    public async Task GetBattle_ASubmittedReaderCannotWriteItsCopyBackOverAVerdict()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        await ReadyProbe.WaitUntilAsync(factory.CreateClient(), r => r.StatusOf("redis") == "Healthy");
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        var runId = Guid.Parse(run.RunId);
        var store = factory.Services.GetRequiredService<RunStore>();
        var cache = factory.Services.GetRequiredService<BattleSessionCache>();
        var submitted = await store.GetBattleAsync(runId, 2, Ct);  // the reader loads Submitted ...
        await SetVerdictAsync(factory, $"{run.RunId}/f0/c5", Verdict(ReplayVerdict.Verified));
        var decided = await store.GetBattleAsync(runId, 2, Ct);
        await cache.SetAsync(runId, 2, decided!);  // ... the verdict is cached meanwhile ...

        await cache.SetAsync(runId, 2, submitted!);  // ... and only then does the slow reader write its copy

        var redis = await ConnectionMultiplexer.ConnectAsync(stack.RedisConnectionString);
        Assert.False(await redis.GetDatabase().KeyExistsAsync(BattleSessionCache.Key(runId, 2)));
        Assert.True(await redis.GetDatabase().KeyExistsAsync(BattleSessionCache.VerdictKey(runId, 2)));
    }

    [Fact]
    public async Task GetBattle_ACacheEntryThatCannotBeRead_IsAMiss_NotA500()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        await ReadyProbe.WaitUntilAsync(factory.CreateClient(), r => r.StatusOf("redis") == "Healthy");
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        await SetVerdictAsync(factory, $"{run.RunId}/f0/c5", Verdict(ReplayVerdict.Verified));
        var runId = Guid.Parse(run.RunId);
        var redis = await ConnectionMultiplexer.ConnectAsync(stack.RedisConnectionString);
        // An entry from another build of the worker, or a corrupt one.
        await redis.GetDatabase().StringSetAsync(BattleSessionCache.VerdictKey(runId, 2), "{\"playerId\": 5, \"session\": []}");

        var battle = await client.GetBattleAsync(run.RunId, 2, Ct);

        Assert.Equal(BattleSessionStatus.Verified, battle.Status);  // Postgres answered
        var healed = JsonSerializer.Deserialize<StoredBattle>(
            (await redis.GetDatabase().StringGetAsync(BattleSessionCache.VerdictKey(runId, 2))).ToString(), RpgJson.Options);
        Assert.Equal(BattleSessionStatus.Verified, healed!.Session.Status);  // and the fill replaced the bad entry
    }

    [Fact]
    public async Task GetBattle_AfterTheVerdict_NeverReturnsAStaleSubmittedCopy()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        await ReadyProbe.WaitUntilAsync(factory.CreateClient(), r => r.StatusOf("redis") == "Healthy");
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        var cachedSubmitted = await client.GetBattleAsync(run.RunId, 2, Ct);  // fills battle:session
        await SetVerdictAsync(factory, $"{run.RunId}/f0/c5", Verdict(ReplayVerdict.Verified));
        var redis = await ConnectionMultiplexer.ConnectAsync(stack.RedisConnectionString);

        // What the worker does after its commit: the verdict key is filled and the Submitted copy deleted.
        var runId = Guid.Parse(run.RunId);
        var fromPostgres = await factory.Services.GetRequiredService<RunStore>().GetBattleAsync(runId, 2, Ct);
        await redis.GetDatabase().StringSetAsync(VerifyPolicy.VerdictKey(runId, 2),
            JsonSerializer.Serialize(fromPostgres, RpgJson.Options));
        await redis.GetDatabase().KeyDeleteAsync(VerifyPolicy.SessionKey(runId, 2));
        var afterwards = await client.GetBattleAsync(run.RunId, 2, Ct);

        Assert.Equal(BattleSessionStatus.Submitted, cachedSubmitted.Status);
        Assert.Equal(BattleSessionStatus.Verified, afterwards.Status);
    }

    [Fact]
    public async Task Monitor_ExportsTheBacklogAndTheQueueDepths()
    {
        await using var probe = await RabbitProbe.OpenAsync(stack.RabbitMqUri);
        await probe.PurgeAsync();
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2, cell: 1), RunLog.Battle(run.RunId, 3, cell: 2)), Ct);
        await SetVerdictAsync(factory, $"{run.RunId}/f0/c2", Verdict(ReplayVerdict.Verified));
        await WaitAsync(async () => await probe.DepthAsync(VerifyTopology.Queue) == 2);

        await factory.Services.GetRequiredService<BattleVerifyMonitor>().CountOnceAsync(Ct);
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_verify_queue_depth"));

        Assert.Equal("1", Sample(metrics, "rpg_battles_unverified"));
        Assert.Contains("rpg_battle_oldest_unverified_age_seconds", metrics);
        Assert.Equal("2", Sample(metrics, "rpg_verify_queue_depth", "queue=\"verify.battle\""));
        Assert.Equal("0", Sample(metrics, "rpg_verify_queue_depth", "queue=\"dlq\""));
        Assert.Equal("2", Sample(metrics, "rpg_verify_jobs_published_total", "source=\"upload\"", "result=\"ok\""));
    }

    private static async Task WaitAsync(Func<Task<bool>> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (!await condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "timed out waiting for the post-response publish");
            await Task.Delay(50, Ct);
        }
    }

    private static async Task<(GameServerClient Client, RunStartResponse Run)> StartedAsync(ApiFactory factory)
    {
        var client = await ClientAsync(factory, "alice");
        return (client, await client.StartRunAsync(Start, Ct));
    }

    private static BattleVerdict Verdict(ReplayVerdict status, MismatchReason? reason = null) =>
        new(status, status == ReplayVerdict.Rejected ? ReplayErrors.ReplayMismatchCode : null,
            status == ReplayVerdict.Rejected ? ReplayErrors.ReplayMismatchName : null,
            reason is null ? null : new ReplayMismatch(reason.Value, 3, "test"), BattleOutcome.Victory, 12,
            new string('b', 64), ApiFactory.TestRuleset, "test-engine", DateTimeOffset.UtcNow);

    /// <summary>What the worker's guarded update does.</summary>
    private static async Task SetVerdictAsync(ApiFactory factory, string battleId, BattleVerdict verdict)
    {
        await using var command = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(
            "UPDATE battle_sessions SET status = $2, verdict = $3::jsonb, verified_at = now(), verifier_version = 'v' " +
            "WHERE battle_id = $1");
        command.Parameters.Add(new NpgsqlParameter { Value = battleId });
        command.Parameters.Add(new NpgsqlParameter { Value = verdict.Status.ToString() });
        command.Parameters.Add(new NpgsqlParameter { Value = JsonSerializer.Serialize(verdict, RpgJson.Options) });
        await command.ExecuteNonQueryAsync(Ct);
    }

    private static async Task ExecuteAsync(ApiFactory factory, string sql)
    {
        await using var command = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(sql);
        await command.ExecuteNonQueryAsync(Ct);
    }

    private async Task FlushBattleKeysAsync(string runId)
    {
        var redis = await ConnectionMultiplexer.ConnectAsync(stack.RedisConnectionString);
        var database = redis.GetDatabase();
        foreach (var seq in Enumerable.Range(1, 8))
        {
            await database.KeyDeleteAsync(BattleSessionCache.Key(Guid.Parse(runId), seq));
            await database.KeyDeleteAsync(BattleSessionCache.VerdictKey(Guid.Parse(runId), seq));
        }
    }

    /// <summary>The value of the series <paramref name="name"/> carrying every one of <paramref name="labels"/>.</summary>
    private static string? Sample(string metrics, string name, params string[] labels) =>
        metrics.Split('\n')
            .Where(line => (line.StartsWith(name + "{", StringComparison.Ordinal)
                            || line.StartsWith(name + " ", StringComparison.Ordinal))
                           && labels.All(line.Contains))
            .Select(line => line[(Math.Max(line.LastIndexOf('}'), name.Length - 1) + 1)..].Trim().Split(' ')[0])
            .FirstOrDefault();
}
