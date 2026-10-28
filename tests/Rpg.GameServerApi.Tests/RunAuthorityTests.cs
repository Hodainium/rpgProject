using System.Net;
using System.Text.Json;
using Rpg.Client;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Presence;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Battle;
using Rpg.GameServerApi.Presence;
using Rpg.GameServerApi.Tests.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using StackExchange.Redis;
using static Rpg.GameServerApi.Tests.RunTests;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Spec server-authority Part B, sections 4 and 6: the action log, the stairs and end gates, run ends, resume, battle
/// sessions, presence and rate limits, through the real Rpg.Client with dev tokens. A database per test.
/// </summary>
[Collection(StackCollection.Name)]
public class RunAuthorityTests(StackFixture stack)
{
    private static readonly RunStartRequest Start =
        new(ApiFactory.TestRuleset, "descent", ["warrior", "cleric", "ranger"]);

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task Actions_UploadInOrder_StoredWithCheckpointSnapshots()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);

        var first = await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2), RunLog.Room(3)), Ct);
        var second = await client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Battle(run.RunId, 4), RunLog.Room(5), RunLog.NextFloor(6)), Ct);

        Assert.Equal(3, first.LastSeq);
        Assert.Equal(6, second.LastSeq);
        Assert.Equal(6, (await client.GetRunAsync(run.RunId, Ct)).LastSeq);
        Assert.Equal(6L, await ScalarAsync(factory, $"SELECT count(*) FROM run_actions WHERE run_id = '{run.RunId}'"));
        Assert.Equal(3L, await ScalarAsync(factory,
            $"SELECT count(*) FROM run_actions WHERE run_id = '{run.RunId}' AND snapshot IS NOT NULL"));
        Assert.Equal(3L, await ScalarAsync(factory,
            $"SELECT count(*) FROM run_actions WHERE run_id = '{run.RunId}' AND seq IN (1, 4, 6)" +
            " AND snapshot->>'marker' = seq::text"));
        Assert.Equal(1L, await ScalarAsync(factory,
            $"SELECT count(*) FROM run_actions WHERE run_id = '{run.RunId}' AND seq = 2 AND action @> '{{\"cell\": 1}}'"));
    }

    [Fact]
    public async Task Actions_BatchRetry_IsIdempotent()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        var batch = RunLog.Batch(RunLog.Start(), RunLog.Room(2), RunLog.Battle(run.RunId, 3));

        var once = await client.SendActionsAsync(run.RunId, batch, Ct);
        var retried = await client.SendActionsAsync(run.RunId, batch, Ct);
        var overlapping = await client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Room(2), RunLog.Battle(run.RunId, 3), RunLog.Room(4)), Ct);

        Assert.Equal(3, once.LastSeq);
        Assert.Equal(once, retried);
        Assert.Equal(4, overlapping.LastSeq);
        Assert.Equal(4L, await ScalarAsync(factory, $"SELECT count(*) FROM run_actions WHERE run_id = '{run.RunId}'"));
        Assert.Equal(1L, await ScalarAsync(factory, $"SELECT count(*) FROM battle_sessions WHERE run_id = '{run.RunId}'"));
    }

    [Fact]
    public async Task Actions_SameSeqDifferentBody_Conflicts()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2)), Ct);

        var ex = await Assert.ThrowsAsync<GameServerApiException>(() => client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Room(2, cell: 9), RunLog.Room(3)), Ct));
        var hash = await Assert.ThrowsAsync<GameServerApiException>(() => client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Room(2, hash: "other")), Ct));

        Assert.Equal(HttpStatusCode.Conflict, ex.StatusCode);
        Assert.Equal(ApiErrors.SequenceConflict, ex.ErrorCode);
        Assert.Equal(2, ex.Problem?.LastSeq);
        Assert.Equal(ApiErrors.SequenceConflict, hash.ErrorCode);
        Assert.Equal(2, (await client.GetRunAsync(run.RunId, Ct)).LastSeq);  // seq 3 wasn't stored
    }

    [Fact]
    public async Task Actions_Gap_ReportsExpectedSeq()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start()), Ct);

        var ex = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Room(3), RunLog.Room(4)), Ct));
        var resent = await client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Room(ex.Problem!.ExpectedSeq!.Value), RunLog.Room(3), RunLog.Room(4)), Ct);

        Assert.Equal(ApiErrors.SequenceGap, ex.ErrorCode);
        Assert.Equal(2, ex.Problem.ExpectedSeq);
        Assert.Equal(4, resent.LastSeq);
    }

    [Fact]
    public async Task Actions_CheckpointWithoutSnapshot_Rejected()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        var notAnObject = JsonDocument.Parse("[1]").RootElement.Clone();
        var wrongVersion = JsonDocument.Parse("""{"schemaVersion":2}""").RootElement.Clone();

        RunActionBatch[] bad =
        [
            RunLog.Batch(RunLog.Start() with { Snapshot = null }),
            RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2) with { Snapshot = null }),
            RunLog.Batch(RunLog.Start(), RunLog.NextFloor(2) with { Snapshot = null }),
            RunLog.Batch(RunLog.Start() with { Snapshot = notAnObject }),
            RunLog.Batch(RunLog.Start() with { Snapshot = wrongVersion }),
            // and the other shape checks: gaps inside a batch, too many actions, unknown types, foreign battle ids
            RunLog.Batch(RunLog.Start(), RunLog.Room(3)),
            new RunActionBatch(Enumerable.Range(1, 51).Select(seq => RunLog.Room(seq)).ToList()),
            new RunActionBatch([]),
            RunLog.Batch(RunLog.Start(), RunLog.Room(2) with { Action = new RunAction("teleport", 0) }),
            RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2, battleId: $"{Guid.NewGuid():D}/f0/c5")),
            RunLog.Batch(RunLog.Start(), RunLog.Room(2) with { Action = new RunAction(RunActionTypes.End, 0) },
                RunLog.Room(3)),
        ];

        foreach (var batch in bad)
        {
            var ex = await Assert.ThrowsAsync<GameServerApiException>(() => client.SendActionsAsync(run.RunId, batch, Ct));
            Assert.Equal(HttpStatusCode.BadRequest, ex.StatusCode);
        }

        Assert.Equal(0, (await client.GetRunAsync(run.RunId, Ct)).LastSeq);
    }

    [Fact]
    public async Task Actions_Concurrent_SerializeBySeq()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var deviceA = await ClientAsync(factory, "alice");
        var deviceB = await ClientAsync(factory, "alice");
        var run = await deviceA.StartRunAsync(Start, Ct);
        await deviceA.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start()), Ct);

        var results = await Task.WhenAll(
            Outcome(deviceA.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Room(2, cell: 1), RunLog.Room(3, cell: 1)), Ct)),
            Outcome(deviceB.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Room(2, cell: 7), RunLog.Room(3, cell: 7)), Ct)));

        Assert.Single(results, r => r == "ok");
        Assert.Single(results, r => r == ApiErrors.SequenceConflict.ToString());
        Assert.Equal(3, (await deviceA.GetRunAsync(run.RunId, Ct)).LastSeq);
        Assert.Equal(1L, await ScalarAsync(factory,
            $"SELECT count(DISTINCT action->>'cell') FROM run_actions WHERE run_id = '{run.RunId}' AND seq IN (2, 3)"));
    }

    [Fact]
    public async Task FloorSeed_UploadIncomplete_Rejected()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2), RunLog.Room(3)), Ct);

        var ahead = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(4), Ct));
        var none = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(), Ct));
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.NextFloor(4)), Ct);
        var issued = await client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(4), Ct);
        var repeated = await client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(), Ct);  // a retry needs no gate

        Assert.Equal(ApiErrors.UploadIncomplete, ahead.ErrorCode);
        Assert.Equal(3, ahead.Problem?.LastSeq);
        Assert.Equal(ApiErrors.UploadIncomplete, none.ErrorCode);
        Assert.Equal(issued, repeated);
        var metrics = await PollMetricsAsync(factory, text => text.Contains("upload_incomplete"));
        Assert.Equal("2", Sample(metrics, "rpg_floor_seeds_total", "result=\"upload_incomplete\""));
    }

    [Fact]
    public async Task EndRun_UploadIncomplete_Rejected()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2)), Ct);

        var ex = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.EndRunAsync(run.RunId, RunLog.End(5, RunEndStatus.Won), Ct));

        Assert.Equal(ApiErrors.UploadIncomplete, ex.ErrorCode);
        Assert.Equal(2, ex.Problem?.LastSeq);
        Assert.Equal(RunStatus.Active, (await client.GetRunAsync(run.RunId, Ct)).Status);
    }

    [Fact]
    public async Task EndRun_Won_VerifyingThenAutoApproved()
    {
        await using (var factory = await ApiFactory.RunsAsync(stack))
        {
            var client = await ClientAsync(factory, "alice");
            var run = await client.StartRunAsync(Start, Ct);
            await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2)), Ct);

            var end = await client.EndRunAsync(run.RunId, RunLog.End(3, RunEndStatus.Won), Ct);
            var retry = await client.EndRunAsync(run.RunId, RunLog.End(3, RunEndStatus.Won), Ct);
            var summary = await client.GetRunAsync(run.RunId, Ct);
            var late = await Assert.ThrowsAsync<GameServerApiException>(() =>
                client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Room(4)), Ct));

            Assert.Equal(RunStatus.Verifying, end.Status);
            Assert.Equal(end, retry);
            Assert.Equal(RunStatus.Verifying, summary.Status);
            Assert.Equal(3, summary.LastSeq);
            Assert.Null(summary.EndedAt);
            Assert.Equal(run.RunId, (await client.GetCurrentRunAsync(Ct))?.RunId);  // still the player's current run
            Assert.Equal(ApiErrors.RunNotActive, late.ErrorCode);
            Assert.Equal(1L, await ScalarAsync(factory,
                $"SELECT count(*) FROM runs WHERE run_id = '{run.RunId}' AND claimed_run_hash = 'run3'"));
        }

        await using (var factory = await ApiFactory.RunsAsync(stack,
                         settings: new Dictionary<string, string?> { ["Run:AutoApproveWins"] = "true" }))
        {
            var client = await ClientAsync(factory, "alice");
            var run = await client.StartRunAsync(Start, Ct);
            await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start()), Ct);

            var end = await client.EndRunAsync(run.RunId, RunLog.End(2, RunEndStatus.Won), Ct);

            Assert.Equal(RunStatus.Won, end.Status);
            Assert.NotNull((await client.GetRunAsync(run.RunId, Ct)).EndedAt);
            Assert.Null(await client.GetCurrentRunAsync(Ct));
        }
    }

    [Fact]
    public async Task EndRun_Lost_ByEndpointOrQueuedAction()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var byEndpoint = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(byEndpoint.RunId, RunLog.Batch(RunLog.Start()), Ct);
        var lost = await client.EndRunAsync(byEndpoint.RunId, RunLog.End(2, RunEndStatus.Lost), Ct);

        var queued = await client.StartRunAsync(Start, Ct);
        var death = RunLog.Batch(RunLog.Start(), RunLog.Room(2),
            new RunActionRequest(3, new RunAction(RunActionTypes.End, 0), "h3", RunLog.PlayedAt, RunLog.Snapshot(3)));
        var ack = await client.SendActionsAsync(queued.RunId, death, Ct);
        var retried = await client.SendActionsAsync(queued.RunId, death, Ct);  // the answer was lost: still a no-op
        var after = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.SendActionsAsync(queued.RunId, RunLog.Batch(RunLog.Room(4)), Ct));

        Assert.Equal(RunStatus.Lost, lost.Status);
        Assert.Equal(RunStatus.Lost, (await client.GetRunAsync(byEndpoint.RunId, Ct)).Status);
        Assert.Equal(3, ack.LastSeq);
        Assert.Equal(ack, retried);
        Assert.Equal(ApiErrors.RunNotActive, after.ErrorCode);
        var summary = await client.GetRunAsync(queued.RunId, Ct);
        Assert.Equal(RunStatus.Lost, summary.Status);
        Assert.NotNull(summary.EndedAt);
        Assert.Null(await client.GetCurrentRunAsync(Ct));
    }

    [Fact]
    public async Task StartRun_WhileVerifying_Rejected()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start()), Ct);
        await client.EndRunAsync(run.RunId, RunLog.End(2, RunEndStatus.Won), Ct);

        var ex = await Assert.ThrowsAsync<GameServerApiException>(() => client.StartRunAsync(Start, Ct));

        Assert.Equal(HttpStatusCode.Conflict, ex.StatusCode);
        Assert.Equal(ApiErrors.RunNotActive, ex.ErrorCode);
        Assert.Equal(RunStatus.Verifying, (await client.GetRunAsync(run.RunId, Ct)).Status);
        Assert.Equal(1L, await ScalarAsync(factory, "SELECT count(*) FROM runs"));
    }

    [Fact]
    public async Task Actions_Battle_CreatesSession()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        await ReadyProbe.WaitUntilAsync(factory.CreateClient(), r => r.StatusOf("redis") == "Healthy");
        var alice = await ClientAsync(factory, "alice");
        var bob = await ClientAsync(factory, "bob");
        var run = await alice.StartRunAsync(Start, Ct);
        var battle = RunLog.Battle(run.RunId, 2, cell: 5);
        await alice.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), battle), Ct);
        await alice.SendActionsAsync(run.RunId, RunLog.Batch(battle), Ct);  // re-upload maps to the same row

        var session = await alice.GetBattleAsync(run.RunId, 2, Ct);
        var cached = await alice.GetBattleAsync(run.RunId, 2, Ct);
        var reused = await Assert.ThrowsAsync<GameServerApiException>(() => alice.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Battle(run.RunId, 3, cell: 5)), Ct));  // the same battle id at another seq
        var notABattle = await Assert.ThrowsAsync<GameServerApiException>(() => alice.GetBattleAsync(run.RunId, 1, Ct));
        var otherPlayer = await Assert.ThrowsAsync<GameServerApiException>(() => bob.GetBattleAsync(run.RunId, 2, Ct));

        Assert.Equal(battle.Action.Battle!.BattleId, session.BattleId);
        Assert.Equal(2, session.RunSeq);
        Assert.Equal(ApiFactory.TestRuleset, session.RulesetVersion);
        Assert.Equal(Rpg.Contracts.Battle.BattleSessionStatus.Submitted, session.Status);
        Assert.Equal(JsonSerializer.Serialize(battle.Action.Battle.Conditions, RpgJson.Options),
            JsonSerializer.Serialize(session.Conditions, RpgJson.Options));
        Assert.Equal(JsonSerializer.Serialize(session, RpgJson.Options), JsonSerializer.Serialize(cached, RpgJson.Options));
        Assert.Equal(ApiErrors.SequenceConflict, reused.ErrorCode);
        Assert.Equal(HttpStatusCode.NotFound, notABattle.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, otherPlayer.StatusCode);
        Assert.Equal(1L, await ScalarAsync(factory,
            $"SELECT count(*) FROM battle_sessions WHERE run_id = '{run.RunId}' AND seed = 1234567890123"));
        var redis = await ConnectionMultiplexer.ConnectAsync(stack.RedisConnectionString);
        Assert.True(await redis.GetDatabase().KeyExistsAsync(BattleSessionCache.Key(Guid.Parse(run.RunId), 2)));
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_battles_submitted_total"));
        // Alice's second read, and Bob's 404 straight from the cached owner.
        Assert.Equal("2", Labeled(metrics, "rpg_cache_reads_total", "entity=\"battle\"", "source=\"redis\""));
    }

    [Fact]
    public async Task Resume_ReturnsLatestCheckpointAndTail()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var alice = await ClientAsync(factory, "alice");
        var bob = await ClientAsync(factory, "bob");
        var run = await alice.StartRunAsync(Start, Ct);
        var empty = await alice.ResumeAsync(run.RunId, Ct);
        RunActionRequest[] tail =
        [
            RunLog.Room(5, floor: 1, cell: 2),
            RunLog.Room(6, floor: 1, cell: 3) with { PlayedAt = RunLog.PlayedAt.ToOffset(TimeSpan.FromHours(2)) },
        ];
        await alice.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Start(), RunLog.Room(2), RunLog.NextFloor(3)), Ct);
        await alice.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(3), Ct);
        await alice.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Battle(run.RunId, 4, floor: 1, cell: 9)), Ct);
        await alice.SendActionsAsync(run.RunId, RunLog.Batch(tail[0], tail[1]), Ct);

        var resumed = await alice.ResumeAsync(run.RunId, Ct);
        var hidden = await Assert.ThrowsAsync<GameServerApiException>(() => bob.ResumeAsync(run.RunId, Ct));

        Assert.Equal(0, empty.CheckpointSeq);
        Assert.Equal(JsonValueKind.Null, empty.Snapshot.ValueKind);
        Assert.Empty(empty.Tail);
        Assert.Single(empty.FloorSeeds);
        Assert.Equal([0, 1], resumed.FloorSeeds.Select(f => f.Floor));
        Assert.Equal(run.FloorSeed, resumed.FloorSeeds[0].FloorSeed);
        Assert.Equal(4, resumed.CheckpointSeq);  // the battle: the latest snapshot
        Assert.True(JsonElement.DeepEquals(RunLog.Snapshot(4), resumed.Snapshot));
        Assert.Equal([5, 6], resumed.Tail.Select(a => a.Seq));
        Assert.Equal(Json(tail[0]), Json(resumed.Tail[0]));
        Assert.Equal(Json(tail[1] with { PlayedAt = tail[1].PlayedAt.ToUniversalTime() }), Json(resumed.Tail[1]));
        Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);

        // A later checkpoint moves the cut; an ended run can't be resumed.
        await alice.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Battle(run.RunId, 7, floor: 1, cell: 4)), Ct);
        var withBattle = await alice.ResumeAsync(run.RunId, Ct);
        Assert.Equal(7, withBattle.CheckpointSeq);
        await alice.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Room(8, floor: 1)), Ct);
        Assert.Equal(Json(RunLog.Room(8, floor: 1)), Json((await alice.ResumeAsync(run.RunId, Ct)).Tail.Single()));
        await alice.EndRunAsync(run.RunId, RunLog.End(9, RunEndStatus.Lost), Ct);
        var ended = await Assert.ThrowsAsync<GameServerApiException>(() => alice.ResumeAsync(run.RunId, Ct));
        Assert.Equal(ApiErrors.RunNotActive, ended.ErrorCode);
    }

    [Fact]
    public async Task Resume_TailCarriesItsBattles()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        // Every uploaded battle is a checkpoint, so a battle only lands in a tail when its snapshot is gone; clear it
        // in the database to check the tail rebuilds the battle from battle_sessions.
        var battle = RunLog.Battle(run.RunId, 2);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), battle, RunLog.Room(3)), Ct);
        await using (var command = factory.Services.GetRequiredService<Npgsql.NpgsqlDataSource>().CreateCommand(
                         $"UPDATE run_actions SET snapshot = NULL WHERE run_id = '{run.RunId}' AND seq = 2"))
        {
            await command.ExecuteNonQueryAsync(Ct);
        }

        var resumed = await client.ResumeAsync(run.RunId, Ct);

        Assert.Equal(1, resumed.CheckpointSeq);
        Assert.Equal(Json(battle with { Snapshot = null }), Json(resumed.Tail[0]));
    }

    [Fact]
    public async Task RateLimit_Exceeded_Returns429()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>
        {
            ["RateLimit:Buckets:runs:Capacity"] = "2",
            ["RateLimit:Buckets:runs:RefillPerSecond"] = "0.05",
        });
        var client = await ClientAsync(factory, "limited-" + Guid.NewGuid().ToString("N")[..8]);
        await client.StartRunAsync(Start, Ct);
        var run = await client.StartRunAsync(Start, Ct);

        var ex = await Assert.ThrowsAsync<GameServerApiException>(() => client.StartRunAsync(Start, Ct));
        var stairs = await client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(0), Ct);  // another bucket

        Assert.Equal(HttpStatusCode.TooManyRequests, ex.StatusCode);
        Assert.Equal(ApiErrors.RateLimited, ex.ErrorCode);
        Assert.NotNull(ex.RetryAfter);
        Assert.InRange(ex.RetryAfter!.Value, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(20));
        Assert.Equal(1, stairs.Floor);
        Assert.Equal(run.RunId, (await client.GetCurrentRunAsync(Ct))?.RunId);
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_rate_limited_total"));
        Assert.Equal("1", Sample(metrics, "rpg_rate_limited_total", "bucket=\"runs\""));
    }

    [Fact]
    public async Task RateLimit_RedisDown_FailsOpen()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, redis: StackFixture.Unreachable.Redis,
            settings: new Dictionary<string, string?>
            {
                ["RateLimit:Buckets:runs:Capacity"] = "1",
                ["RateLimit:Buckets:runs:RefillPerSecond"] = "0.001",
            });
        var client = await ClientAsync(factory, "alice");

        for (var i = 0; i < 3; i++)
        {
            await client.StartRunAsync(Start, Ct);
        }

        var metrics = await factory.CreateClient().GetStringAsync("/metrics", Ct);
        Assert.Contains("operation=\"ratelimit\"", metrics);
        Assert.DoesNotContain("rpg_rate_limited_total{", metrics);
    }

    [Fact]
    public async Task Gauges_PresenceAndRuns()
    {
        const int database = 5;  // presence sets are global: keep them away from the other tests
        var admin = await ConnectionMultiplexer.ConnectAsync(stack.RedisConnectionString + ",allowAdmin=true");
        await admin.GetServers().Single().FlushDatabaseAsync(database);
        await using var factory = await ApiFactory.RunsAsync(stack,
            redis: stack.RedisConnectionString + $",defaultDatabase={database}",
            settings: new Dictionary<string, string?> { ["Monitors:Interval"] = "00:00:01" });
        var alice = await ClientAsync(factory, "alice");
        var bob = await ClientAsync(factory, "bob");
        await alice.StartRunAsync(Start, Ct);
        await alice.StartRunAsync(Start, Ct);  // abandons the first
        await bob.StartRunAsync(Start, Ct);
        await alice.HeartbeatAsync(new PresenceRequest(PresenceActivity.Map), Ct);
        await bob.HeartbeatAsync(new PresenceRequest(PresenceActivity.Battle), Ct);
        // carol was last seen 6 minutes ago, dave left a battle 3 minutes ago.
        var db = admin.GetDatabase(database);
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        await db.SortedSetAddAsync(PresenceTracker.OnlineKey, "carol", now - 360);
        await db.SortedSetAddAsync(PresenceTracker.OnlineKey, "dave", now - 30);
        await db.SortedSetAddAsync(PresenceTracker.BattleKey, "dave", now - 180);

        var metrics = await PollMetricsAsync(factory, text =>
            Value(text, "rpg_players_online") == "3" && Value(text, "rpg_runs_in_progress") == "2");

        Assert.Equal("3", Value(metrics, "rpg_players_online"));  // alice, bob, dave
        Assert.Equal("1", Value(metrics, "rpg_players_in_battle"));  // bob
        Assert.Equal("2", Value(metrics, "rpg_runs_in_progress"));
        Assert.Null(await db.SortedSetScoreAsync(PresenceTracker.OnlineKey, "carol"));  // trimmed

        await bob.HeartbeatAsync(new PresenceRequest(PresenceActivity.Menu), Ct);
        metrics = await PollMetricsAsync(factory, text => Value(text, "rpg_players_in_battle") == "0");
        Assert.Equal("0", Value(metrics, "rpg_players_in_battle"));
    }

    [Fact]
    public async Task Metrics_CountActionsBattlesEndsAndUploadLag()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        var lateStart = RunLog.Start() with { PlayedAt = DateTimeOffset.UtcNow.AddSeconds(-90) };
        await client.SendActionsAsync(run.RunId, RunLog.Batch(lateStart, RunLog.Battle(run.RunId, 2)), Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(lateStart), Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Room(5)), Ct).ContinueWith(_ => { }, Ct);
        await client.EndRunAsync(run.RunId, RunLog.End(3, RunEndStatus.Lost), Ct);

        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_run_ends_total"));

        Assert.Equal("1", Labeled(metrics, "rpg_run_actions_total", "result=\"accepted\"", "type=\"start_run\""));
        Assert.Equal("1", Labeled(metrics, "rpg_run_actions_total", "result=\"duplicate\"", "type=\"start_run\""));
        Assert.Equal("1", Labeled(metrics, "rpg_run_actions_total", "result=\"gap\"", "type=\"enter_room\""));
        Assert.Equal("1", Value(metrics, "rpg_battles_submitted_total"));
        Assert.Equal("1", Sample(metrics, "rpg_run_ends_total", "status=\"lost\""));
        Assert.Equal("3", Value(metrics, "rpg_run_action_batch_size_count"));
        Assert.True(double.Parse(Value(metrics, "rpg_run_action_upload_lag_seconds_sum")!,
            System.Globalization.CultureInfo.InvariantCulture) >= 90);
        Assert.Contains("rpg_run_action_duration_seconds_bucket", metrics);
        Assert.Contains("rpg_dev_tokens_issued_total", metrics);
    }

    private static async Task<string> Outcome(Task<RunActionAck> call)
    {
        try
        {
            await call;
            return "ok";
        }
        catch (GameServerApiException ex)
        {
            return ex.ErrorCode?.ToString() ?? ex.StatusCode.ToString();
        }
    }

    private static string Json(RunActionRequest action) => JsonSerializer.Serialize(action, RpgJson.Options);

    /// <summary>The value of the only series named <paramref name="name"/> (with or without exporter labels), or null.</summary>
    private static string? Value(string metrics, string name) => Labeled(metrics, name);

    /// <summary>The value of the series <paramref name="name"/> carrying every one of <paramref name="labels"/>.</summary>
    private static string? Labeled(string metrics, string name, params string[] labels) =>
        metrics.Split('\n')
            .Where(line => (line.StartsWith(name + "{", StringComparison.Ordinal)
                            || line.StartsWith(name + " ", StringComparison.Ordinal))
                           && labels.All(line.Contains))
            .Select(line => line[(Math.Max(line.LastIndexOf('}'), name.Length - 1) + 1)..].Trim().Split(' ')[0])
            .FirstOrDefault();
}
