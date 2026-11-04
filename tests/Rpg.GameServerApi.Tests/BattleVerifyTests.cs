using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using Rpg.Client;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Battle;
using Rpg.GameServerApi.Outbox;
using Rpg.GameServerApi.Runs;
using Rpg.GameServerApi.Tests.Infrastructure;
using Rpg.Verification;
using StackExchange.Redis;
using static Rpg.GameServerApi.Tests.RunTests;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Spec battle-verify, the API half (sections 2.1, 2.2, 2.4, 3.2, 3.4, 5): a battle upload writes one outbox row that becomes one verify job, the
/// outbox relay publishes it, the endpoint serves the verdict (a rejection is a 200), and the caches never
/// hold a stale Submitted copy. The worker half is in Rpg.VerifierWorker.Tests.
/// </summary>
[Collection(StackCollection.Name)]
public class BattleVerifyTests(StackFixture stack)
{
    private static readonly RunStartRequest Start =
        new(ApiFactory.TestRuleset, "descent", ["warrior", "cleric", "ranger"]);

    private static readonly Dictionary<string, string?> QuietBackground = new()
    {
        ["Monitors:Interval"] = "01:00:00",
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
    public async Task Upload_Battle_WritesOneOutboxRow_AndTheRelayPublishesOneJob()
    {
        await using var probe = await RabbitProbe.OpenAsync(stack.RabbitMqUri);
        await probe.PurgeAsync();
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);

        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        var jobs = await probe.TakeAsync();
        await WaitAsync(async () => await ScalarAsync(factory,
            $"SELECT count(*) FROM outbox WHERE key = '{run.RunId}/f0/c5' AND published_at IS NOT NULL") == 1);

        var (job, attempt) = Assert.Single(jobs);
        Assert.Equal($"{run.RunId}/f0/c5", job.BattleId);
        Assert.Equal(Guid.Parse(run.RunId), job.RunId);
        Assert.Equal(2, job.RunSeq);
        Assert.Equal(ApiFactory.TestRuleset, job.RulesetVersion);
        Assert.Equal(0, attempt);
        Assert.Equal(1L, await ScalarAsync(factory,
            $"SELECT count(*) FROM outbox WHERE destination = 'rabbit' AND type = 'VerifyBattleJob' AND key = '{run.RunId}/f0/c5'"));
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
        await Task.Delay(800, Ct);  // a second job would be relayed within a poll or two
        var jobs = await probe.TakeAsync();

        Assert.Single(jobs);  // F1: one session, one outbox row, one job
        Assert.Equal(1L, await ScalarAsync(factory, $"SELECT count(*) FROM battle_sessions WHERE run_id = '{run.RunId}'"));
        Assert.Equal(1L, await ScalarAsync(factory, $"SELECT count(*) FROM outbox WHERE key LIKE '{run.RunId}/%'"));
    }

    [Fact]
    public async Task Upload_BrokerDown_StillStores_AndTheRowWaitsInTheOutbox()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>(QuietBackground)
        {
            ["RabbitMq:Uri"] = "amqp://guest:guest@127.0.0.1:1/",
        });
        var (client, run) = await StartedAsync(factory);

        var ack = await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        await factory.Services.GetRequiredService<OutboxRelay>().RunOnceAsync(Ct);

        Assert.Equal(2, ack.LastSeq);  // F10: the upload never depends on the broker
        Assert.Equal(1L, await ScalarAsync(factory,
            $"SELECT count(*) FROM outbox WHERE key = '{run.RunId}/f0/c5' AND published_at IS NULL AND dead_lettered_at IS NULL"));
    }

    [Fact]
    public async Task Relay_PublishesRowsWrittenWhileItWasPaused()
    {
        await using var probe = await RabbitProbe.OpenAsync(stack.RabbitMqUri);
        await probe.PurgeAsync();
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>(QuietBackground)
        {
            ["Outbox:Enabled"] = "false",
        });
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2, cell: 1), RunLog.Battle(run.RunId, 3, cell: 2)), Ct);
        Assert.Empty(await probe.TakeAsync(wait: TimeSpan.FromMilliseconds(500)));  // paused: nothing leaves

        var relay = factory.Services.GetRequiredService<OutboxRelay>();
        Assert.Equal(2, await relay.RunOnceAsync(Ct));
        var jobs = await probe.TakeAsync();

        Assert.Equal([$"{run.RunId}/f0/c1", $"{run.RunId}/f0/c2"], jobs.Select(j => j.Job.BattleId));  // in order
    }

    [Fact]
    public async Task UploadAndOutboxRow_AreOneTransaction()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: QuietBackground);
        var (client, run) = await StartedAsync(factory);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2, cell: 1)), Ct);

        // seq 3 is a new battle (session + outbox row written), seq 4 reuses battle c1's id: the whole batch rolls back.
        await Assert.ThrowsAsync<GameServerApiException>(() => client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Battle(run.RunId, 3, cell: 2), RunLog.Battle(run.RunId, 4, cell: 1)), Ct));

        Assert.Equal(1L, await ScalarAsync(factory, $"SELECT count(*) FROM battle_sessions WHERE run_id = '{run.RunId}'"));
        Assert.Equal(1L, await ScalarAsync(factory, $"SELECT count(*) FROM outbox WHERE key LIKE '{run.RunId}/%'"));  // F18
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
        Assert.Equal("2", Sample(metrics, "rpg_outbox_published_total", "destination=\"rabbit\"", "result=\"ok\""));
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
