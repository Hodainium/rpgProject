using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using Rpg.Client;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;
using StackExchange.Redis;
using Rpg.GameServerApi.Runs;
using Rpg.GameServerApi.Tests.Infrastructure;
using static Rpg.GameServerApi.Tests.RunTests;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Spec run-verify sections 2.0, 2.1, 2.6, 2.7 and 4 (F10 to F12, F19, F23 to F25), the API half: the genesis step at run
/// start, a step and its job per checkpoint (and no per-battle job), the epoch, the stairs gate, resume from the server's
/// own start, and the floor read model. The worker half (verdicts, the aggregator, gems) is StepProcessorTests.
/// </summary>
[Collection(StackCollection.Name)]
public class RunVerifyTests(StackFixture stack)
{
    private static readonly RunStartRequest Start =
        new(ApiFactory.TestRuleset, "descent", ["warrior", "cleric", "ranger"]);

    private static readonly Dictionary<string, string?> Quiet = new() { ["Monitors:Interval"] = "01:00:00", ["Outbox:Enabled"] = "false" };

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static Task<List<string>> RowsAsync(ApiFactory factory, string sql) => ListAsync(factory, sql);

    private static async Task<List<string>> ListAsync(ApiFactory factory, string sql)
    {
        await using var command = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(sql);
        await using var reader = await command.ExecuteReaderAsync(Ct);
        var rows = new List<string>();
        while (await reader.ReadAsync(Ct))
        {
            rows.Add(reader.GetValue(0).ToString()!);
        }

        return rows;
    }

    // ---- 2.0: the genesis step -----------------------------------------------------------------------------------

    [Fact]
    public async Task Start_WritesTheGenesisStepAndItsJob_InTheStartTransaction()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");

        var run = await client.StartRunAsync(Start, Ct);

        Assert.Equal(["0:0:1:genesis:Pending"], await RowsAsync(factory,
            $"SELECT epoch || ':' || from_seq || ':' || to_seq || ':' || kind || ':' || status FROM run_steps WHERE run_id = '{run.RunId}'"));
        var key = $"{run.RunId}/0/0";
        Assert.Equal(["rabbit:segment:VerifyStepJob"], await RowsAsync(factory,
            $"SELECT destination || ':' || topic || ':' || type FROM outbox WHERE key = '{key}'"));
        var job = JsonSerializer.Deserialize<VerifyStepJob>(
            (await RowsAsync(factory, $"SELECT payload::text FROM outbox WHERE key = '{key}'")).Single(), RpgJson.Options)!;
        Assert.Equal((Guid.Parse(run.RunId), 0, 0, ApiFactory.TestRuleset), (job.RunId, job.Epoch, job.StepNo, job.RulesetVersion));
    }

    [Fact]
    public async Task Start_ABrokerThatIsDown_StillStartsTheRun_TheJobWaitsInTheOutbox()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>(Quiet)
        {
            ["RabbitMq:Uri"] = "amqp://guest:guest@127.0.0.1:1/",
        });
        var client = await ClientAsync(factory, "alice");

        var run = await client.StartRunAsync(Start, Ct);

        Assert.Equal(1L, await ScalarAsync(factory,
            $"SELECT count(*) FROM outbox WHERE key = '{run.RunId}/0/0' AND published_at IS NULL"));   // F24: nothing needs the broker
    }

    [Fact]
    public async Task TheRelay_PublishesTheGenesisJobToVerifySegment()
    {
        await using var probe = await RabbitProbe.OpenAsync(stack.RabbitMqUri);
        await probe.PurgeAsync();
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);

        await factory.Services.GetRequiredService<Rpg.GameServerApi.Outbox.OutboxRelay>().RunOnceAsync(Ct);
        var jobs = await probe.TakeStepsAsync();

        var (job, attempt) = Assert.Single(jobs);
        Assert.Equal((Guid.Parse(run.RunId), 0, 0), (job.RunId, job.Epoch, job.StepNo));
        Assert.Equal(0, attempt);
    }

    // ---- 2.1: steps from uploads ------------------------------------------------------------------------------------

    [Fact]
    public async Task Upload_MakesAStepAndAJobPerCheckpoint_AfterSeqOne_AndNoPerBattleJob()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);

        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2), RunLog.Battle(run.RunId, 3),
            RunLog.Room(4), RunLog.NextFloor(5)), Ct);

        Assert.Equal(["0:0:1:genesis", "1:1:3:battle", "2:3:5:segment"], await RowsAsync(factory,
            $"SELECT step_no || ':' || from_seq || ':' || to_seq || ':' || kind FROM run_steps WHERE run_id = '{run.RunId}' ORDER BY step_no"));
        Assert.Equal(3L, await ScalarAsync(factory, $"SELECT count(*) FROM outbox WHERE type = 'VerifyStepJob' AND key LIKE '{run.RunId}/%'"));
        Assert.Equal(0L, await ScalarAsync(factory, $"SELECT count(*) FROM outbox WHERE type = 'VerifyBattleJob'"));   // the step verifies the battle
        Assert.Equal(1L, await ScalarAsync(factory, $"SELECT count(*) FROM battle_sessions WHERE run_id = '{run.RunId}' AND status = 'Submitted'"));
        Assert.Equal(5L, await ScalarAsync(factory, $"SELECT end_seq::bigint FROM run_floors WHERE run_id = '{run.RunId}' AND floor = 0"));
    }

    [Fact]
    public async Task Upload_TheSameBatchAgain_MakesNoSecondStep()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        var batch = RunLog.Batch(RunLog.Start(), RunLog.Room(2), RunLog.NextFloor(3));

        await client.SendActionsAsync(run.RunId, batch, Ct);
        await client.SendActionsAsync(run.RunId, batch, Ct);

        Assert.Equal(2L, await ScalarAsync(factory, $"SELECT count(*) FROM run_steps WHERE run_id = '{run.RunId}'"));   // genesis + one
        Assert.Equal(2L, await ScalarAsync(factory, $"SELECT count(*) FROM outbox WHERE type = 'VerifyStepJob' AND key LIKE '{run.RunId}/%'"));
    }

    [Fact]
    public async Task Upload_AStepAboveTheLimit_Is400_AndStoresNothing()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>(Quiet)
        {
            ["Verify:MaxStepActions"] = "3",
        });
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start()), Ct);

        var ex = await Assert.ThrowsAsync<GameServerApiException>(() => client.SendActionsAsync(run.RunId,
            RunLog.Batch(RunLog.Room(2), RunLog.Room(3), RunLog.Room(4), RunLog.NextFloor(5)), Ct));   // F19: four actions in one step

        Assert.Equal(HttpStatusCode.BadRequest, ex.StatusCode);
        Assert.Equal(1, (await client.GetRunAsync(run.RunId, Ct)).LastSeq);
        Assert.Equal(1L, await ScalarAsync(factory, $"SELECT count(*) FROM run_steps WHERE run_id = '{run.RunId}'"));
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Room(2), RunLog.Room(3), RunLog.NextFloor(4)), Ct);   // three is fine
    }

    [Fact]
    public async Task Upload_AClientWithoutAPendingBattleCheckpoint_MakesOneLongerBattleStep()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);

        // No checkpoint between the rooms and the battle: the server cannot tell, it only cuts at snapshots (F19).
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2), RunLog.Room(3),
            RunLog.Battle(run.RunId, 4)), Ct);

        Assert.Equal(["0:0:1:genesis", "1:1:4:battle"], await RowsAsync(factory,
            $"SELECT step_no || ':' || from_seq || ':' || to_seq || ':' || kind FROM run_steps WHERE run_id = '{run.RunId}' ORDER BY step_no"));
        Assert.Equal(2L, await ScalarAsync(factory,
            $"SELECT count(*) FROM outbox WHERE key LIKE '{run.RunId}/0/%' AND type = 'VerifyStepJob'"));   // genesis + that one step
    }

    [Fact]
    public async Task Rollback_ConcurrentUpload_Is1108_BecauseTheEpochIsReadUnderTheRunLock()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2)), Ct);

        // The rollback holds the run row lock (as the aggregator does) while the client's upload, still on epoch 0, arrives.
        await using var connection = await factory.Services.GetRequiredService<NpgsqlDataSource>().OpenConnectionAsync(Ct);
        await using var transaction = await connection.BeginTransactionAsync(Ct);
        await using (var lockRow = new NpgsqlCommand($"SELECT 1 FROM runs WHERE run_id = '{run.RunId}' FOR UPDATE", connection, transaction))
        {
            await lockRow.ExecuteNonQueryAsync(Ct);
        }

        var upload = client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Room(3)), Ct);
        await Task.Delay(1000, Ct);
        Assert.False(upload.IsCompleted, "the upload waits for the run row lock");

        await using (var rollBack = new NpgsqlCommand(
            $"UPDATE runs SET epoch = 1, verified_seq = 1, last_seq = 1, rollback_reason = 'Illegal' WHERE run_id = '{run.RunId}'",
            connection, transaction))
        {
            await rollBack.ExecuteNonQueryAsync(Ct);
        }

        await transaction.CommitAsync(Ct);

        var ex = await Assert.ThrowsAsync<GameServerApiException>(() => upload);
        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.RunRolledBack), (ex.StatusCode, ex.ErrorCode));   // F21
        Assert.Equal(1L, await ScalarAsync(factory, $"SELECT last_seq::bigint FROM runs WHERE run_id = '{run.RunId}'"));   // the late action stored nothing
    }

    [Fact]
    public async Task ARunStartedBeforeTheMigration_IsLegacy_NoStepsNoGateAndAWinIsNotHeld()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await ExecuteAsync(factory, $"UPDATE runs SET legacy = true WHERE run_id = '{run.RunId}'");

        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2), RunLog.NextFloor(3)), Ct);
        var stairs = await client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(3), Ct);
        var end = await client.EndRunAsync(run.RunId, RunLog.End(4, RunEndStatus.Won), Ct);

        Assert.Equal(1, stairs.Floor);   // no gate
        Assert.Equal(1L, await ScalarAsync(factory, $"SELECT count(*) FROM run_steps WHERE run_id = '{run.RunId}'"));   // only the genesis row
        Assert.Equal(RunStatus.Won, end.Status);   // it was never going to be verified
    }

    // ---- 2.6: the stairs gate (F12) -----------------------------------------------------------------------------------

    [Fact]
    public async Task Stairs_TheFloorJustPlayedIsNotVerified_Is1107_WithRetryAfter_ThenOpens()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2), RunLog.NextFloor(3)), Ct);

        var blocked = await Assert.ThrowsAsync<GameServerApiException>(() => client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(3), Ct));
        await ExecuteAsync(factory, $"UPDATE run_floors SET verified_at = now() WHERE run_id = '{run.RunId}' AND floor = 0");
        var opened = await client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(3), Ct);

        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.PreviousFloorUnverified), (blocked.StatusCode, blocked.ErrorCode));
        Assert.Equal(TimeSpan.FromSeconds(5), blocked.RetryAfter);
        Assert.Equal(1, opened.Floor);
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_stairs_gate_total"));
        Assert.Equal("1", Sample(metrics, "rpg_stairs_gate_total", "result=\"blocked\""));
        Assert.Equal("1", Sample(metrics, "rpg_stairs_gate_total", "result=\"open\""));
    }

    [Fact]
    public async Task Stairs_TheChecksRunInOrder_1105_Then1106_Then1107()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.NextFloor(2)), Ct);

        var skip = await Assert.ThrowsAsync<GameServerApiException>(() => client.GetFloorSeedAsync(run.RunId, 2, new FloorSeedRequest(2), Ct));
        var incomplete = await Assert.ThrowsAsync<GameServerApiException>(() => client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(1), Ct));
        var unverified = await Assert.ThrowsAsync<GameServerApiException>(() => client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(2), Ct));

        Assert.Equal(ApiErrors.FloorNotReachable, skip.ErrorCode);
        Assert.Equal(ApiErrors.UploadIncomplete, incomplete.ErrorCode);
        Assert.Equal(ApiErrors.PreviousFloorUnverified, unverified.ErrorCode);
    }

    [Fact]
    public async Task Stairs_ARepeatOfTheCurrentFloor_NeedsNoGate()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.NextFloor(2)), Ct);
        await GateOpenAsync(factory, run.RunId);
        var issued = await client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(2), Ct);
        await ExecuteAsync(factory, $"UPDATE run_floors SET verified_at = NULL WHERE run_id = '{run.RunId}'");

        var again = await client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(2), Ct);

        Assert.Equal(issued, again);
    }

    // ---- 2.4: the epoch (F11) -----------------------------------------------------------------------------------------

    [Fact]
    public async Task AStaleEpoch_Is1108_OnUploadStairsAndEnd_AndStoresNothing()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2)), Ct);
        await ExecuteAsync(factory,
            $"UPDATE runs SET epoch = 2, verified_seq = 1, rollback_reason = 'Illegal' WHERE run_id = '{run.RunId}'");

        var upload = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Room(3)), Ct));
        var stairs = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.GetFloorSeedAsync(run.RunId, 1, new FloorSeedRequest(2), Ct));
        var end = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.EndRunAsync(run.RunId, RunLog.End(3, RunEndStatus.Lost), Ct));

        foreach (var ex in new[] { upload, stairs, end })
        {
            Assert.Equal((HttpStatusCode.Conflict, ApiErrors.RunRolledBack), (ex.StatusCode, ex.ErrorCode));
            Assert.Equal((2, 1, "Illegal"), (ex.Problem?.Epoch, ex.Problem?.RollbackSeq, ex.Problem?.Reason));
        }

        Assert.Equal(2, (await client.GetRunAsync(run.RunId, Ct)).LastSeq);
        // The client that rebuilt from /resume sends the new epoch and carries on.
        var ack = await client.SendActionsAsync(run.RunId, new RunActionBatch([RunLog.Room(3)], Epoch: 2), Ct);
        Assert.Equal((3, 2, 1), (ack.LastSeq, ack.Epoch, ack.VerifiedSeq));
    }

    // ---- 2.2 and the end (F13) --------------------------------------------------------------------------------------

    [Fact]
    public async Task AWin_CreatesTheEndStep_AndStaysVerifying()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2), RunLog.NextFloor(3)), Ct);

        var end = await client.EndRunAsync(run.RunId, RunLog.End(4, RunEndStatus.Won), Ct);

        Assert.Equal(RunStatus.Verifying, end.Status);
        Assert.Equal(["genesis", "segment", "end"], await RowsAsync(factory,
            $"SELECT kind FROM run_steps WHERE run_id = '{run.RunId}' ORDER BY step_no"));
        Assert.Equal(4L, await ScalarAsync(factory, $"SELECT end_seq::bigint FROM runs WHERE run_id = '{run.RunId}'"));
        Assert.Equal(3L, await ScalarAsync(factory, $"SELECT count(*) FROM outbox WHERE type = 'VerifyStepJob' AND key LIKE '{run.RunId}/%'"));
    }

    [Fact]
    public async Task AWinThatIsTheFirstUpload_IsRefused_ItHasNoCheckpointToBeVerifiedFrom()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);

        var ex = await Assert.ThrowsAsync<GameServerApiException>(() => client.EndRunAsync(run.RunId, RunLog.End(1, RunEndStatus.Won), Ct));

        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.UploadIncomplete), (ex.StatusCode, ex.ErrorCode));
        Assert.Equal(RunStatus.Active, (await client.GetRunAsync(run.RunId, Ct)).Status);   // never Verifying, never Won
        Assert.Equal(0, (await client.GetRunAsync(run.RunId, Ct)).LastSeq);
        Assert.Equal(1L, await ScalarAsync(factory, $"SELECT count(*) FROM run_steps WHERE run_id = '{run.RunId}'"));   // the genesis step only
    }

    [Fact]
    public async Task ADeath_GetsAnOrdinarySegmentStep_NotAnEndStepThatDemandsAWin()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var byEndpoint = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(byEndpoint.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2)), Ct);
        await client.EndRunAsync(byEndpoint.RunId, RunLog.End(3, RunEndStatus.Lost), Ct);
        var queued = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(queued.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2),
            new RunActionRequest(3, new RunAction(RunActionTypes.End, 0), "h3", RunLog.PlayedAt, RunLog.Snapshot(3))), Ct);

        Assert.Equal(["genesis", "segment"], await RowsAsync(factory, $"SELECT kind FROM run_steps WHERE run_id = '{byEndpoint.RunId}' ORDER BY step_no"));
        Assert.Equal(["genesis", "segment"], await RowsAsync(factory, $"SELECT kind FROM run_steps WHERE run_id = '{queued.RunId}' ORDER BY step_no"));
    }

    [Fact]
    public async Task TheWallet_ShowsPendingAndVoidedRows_AsSuch_AndCountsOnlyReleasedGems()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        await client.StartRunAsync(Start, Ct);
        var player = Rpg.GameServerApi.Auth.DevTokenIssuer.IdOf("alice");
        await ExecuteAsync(factory, $"INSERT INTO wallets (player_id, gems, version) VALUES ('{player}', 10, 1)");
        foreach (var (key, status, delta) in new[] { ("k1", "released", 10), ("k2", "pending", 5), ("k3", "voided", 7) })
        {
            await ExecuteAsync(factory,
                $"INSERT INTO wallet_ledger (player_id, currency, delta, reason, idempotency_key, status) VALUES ('{player}', 'gems', {delta}, 'completion_mark', '{key}', '{status}')");
        }

        var wallet = await client.GetWalletAsync(Ct);

        Assert.Equal(10, wallet.Gems);
        Assert.Equal([null, "pending", "voided"], wallet.Recent.OrderBy(e => e.Delta == 10 ? 0 : e.Delta == 5 ? 1 : 2).Select(e => e.Status));
    }

    // ---- 2.6, 2.7: resume and the floor read model (F25, scenario 4) -----------------------------------------------

    [Fact]
    public async Task Resume_BeforeAnyUpload_ServesTheServersOwnStartSnapshot()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        var early = await client.ResumeAsync(run.RunId, Ct);
        await ExecuteAsync(factory,
            $"UPDATE runs SET genesis_hash = 'g', genesis_snapshot = '{{\"schemaVersion\":1,\"server\":true}}' WHERE run_id = '{run.RunId}'");

        var resumed = await client.ResumeAsync(run.RunId, Ct);

        Assert.Equal(JsonValueKind.Null, early.Snapshot.ValueKind);   // the anchor job has not finished yet
        Assert.Equal(0, resumed.CheckpointSeq);
        Assert.True(resumed.Snapshot.GetProperty("server").GetBoolean());
        Assert.Empty(resumed.Tail);
        Assert.Single(resumed.FloorSeeds);
    }

    [Fact]
    public async Task Resume_AtSeqOne_ServesTheServersSnapshot_NotTheClients()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Room(2)), Ct);
        await ExecuteAsync(factory,
            $"UPDATE runs SET genesis_hash = 'g', verified_seq = 1, genesis_snapshot = '{{\"schemaVersion\":1,\"server\":true}}' WHERE run_id = '{run.RunId}'");

        var resumed = await client.ResumeAsync(run.RunId, Ct);

        Assert.Equal(1, resumed.CheckpointSeq);
        Assert.True(resumed.Snapshot.GetProperty("server").GetBoolean());   // not the client's {"marker":1,…}
        Assert.Equal([2], resumed.Tail.Select(a => a.Seq));
        Assert.Equal(1, resumed.VerifiedSeq);
    }

    [Fact]
    public async Task FloorDigest_Is404UntilVerified_ThenServedFromPostgresAndRedis_AndSurvivesAFlush()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var alice = await ClientAsync(factory, "alice");
        var bob = await ClientAsync(factory, "bob");
        var run = await alice.StartRunAsync(Start, Ct);
        var http = factory.CreateClient();
        http.DefaultRequestHeaders.Authorization = new("Bearer", Token(factory, "alice"));
        using var missing = await http.GetAsync($"/api/v1/runs/{run.RunId}/floors/0", Ct);
        await ExecuteAsync(factory,
            $"UPDATE run_floors SET digest = '{{\"floor\":0,\"floorHash\":\"abc\"}}', verified_at = now() WHERE run_id = '{run.RunId}' AND floor = 0");

        using var fromPostgres = await http.GetAsync($"/api/v1/runs/{run.RunId}/floors/0", Ct);
        var key = RunSummaryCache.FloorKey(Guid.Parse(run.RunId), 0);
        await using var redis = await ConnectionMultiplexer.ConnectAsync(stack.RedisConnectionString + ",allowAdmin=true");
        var cached = await redis.GetDatabase().KeyExistsAsync(key);
        await redis.GetServers().Single().FlushDatabaseAsync();   // scenario 4
        using var afterFlush = await http.GetAsync($"/api/v1/runs/{run.RunId}/floors/0", Ct);
        var other = factory.CreateClient();
        other.DefaultRequestHeaders.Authorization = new("Bearer", Token(factory, "bob"));
        using var hidden = await other.GetAsync($"/api/v1/runs/{run.RunId}/floors/0", Ct);

        Assert.Equal(HttpStatusCode.NotFound, missing.StatusCode);
        Assert.Equal(HttpStatusCode.OK, fromPostgres.StatusCode);
        Assert.Equal("abc", (await fromPostgres.Content.ReadFromJsonAsync<FloorDigestResponse>(RpgJson.Options, Ct))!.Digest.GetProperty("floorHash").GetString());
        Assert.True(cached);
        Assert.Equal(HttpStatusCode.OK, afterFlush.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);   // another player's run answers like a missing one
        _ = bob;
    }

    [Fact]
    public async Task Steps_AreListedInDevelopment_ForTheOwnerOnly()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var alice = await ClientAsync(factory, "alice");
        var run = await alice.StartRunAsync(Start, Ct);
        var http = factory.CreateClient();
        http.DefaultRequestHeaders.Authorization = new("Bearer", Token(factory, "alice"));
        var other = factory.CreateClient();
        other.DefaultRequestHeaders.Authorization = new("Bearer", Token(factory, "bob"));

        var steps = await http.GetFromJsonAsync<List<RunStepDto>>($"/api/v1/runs/{run.RunId}/steps", RpgJson.Options, Ct);
        using var hidden = await other.GetAsync($"/api/v1/runs/{run.RunId}/steps", Ct);

        Assert.Equal([(0, StepKind.Genesis, StepStatus.Pending)], steps!.Select(s => (s.StepNo, s.Kind, s.Status)));
        Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
    }

}
