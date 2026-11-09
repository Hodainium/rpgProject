using System.Text.Json;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Verification;
using Rpg.VerifierWorker.Tests.Infrastructure;
using static Rpg.VerifierWorker.Tests.Infrastructure.WorkerHarness;

namespace Rpg.VerifierWorker.Tests;

/// <summary>
/// Spec run-verify 2.0 to 2.5 and 4 (F1, F2, F4 to F10, F13 to F16, F20, F23, F24): one step job from start to decision, with the
/// fake step runner standing in for Godot, a real Postgres and a real Redis. The aggregator runs inside the commit, so
/// the same tests cover the verified prefix, the links, the gems and the rollback.
/// </summary>
[Collection(StackCollection.Name)]
public class StepProcessorTests(Stack stack)
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static Task<WorkerHarness> CreateAsync(Stack stack, Dictionary<string, string?>? settings = null,
        string? postgres = null, string? redis = null) =>
        WorkerHarness.CreateAsync(stack, settings, postgres, redis);

    private static BattleFacts BossFacts => new("enc.boss", ["boss.lich"], ["warrior"]);

    /// <summary>A run whose start is verified: seq 1 uploaded with the anchor's hash and the genesis job done.</summary>
    private static async Task<SeededRun> VerifiedStartAsync(WorkerHarness worker, Guid? player = null, string status = "Active")
    {
        var run = await worker.SeedRunAsync(status, 0, player);
        await worker.UploadAsync(run, 1, RunActionTypes.StartRun, snapshot: true, hash: FakeStepRunner.GenesisHash);
        var decision = await worker.Steps.ProcessAsync(StepJobOf(run, 0), Ct);
        Assert.Equal("verified", decision.Result);
        Assert.Equal(1, (await worker.RunStateAsync(run)).VerifiedSeq);
        return run;
    }

    private static Task<string?> Status(WorkerHarness worker, SeededRun run, int stepNo) =>
        worker.ScalarAsync<string>("SELECT status FROM run_steps WHERE run_id = $1 AND step_no = $2", run.RunId, stepNo);

    private static async Task<long> WalletAsync(WorkerHarness worker, SeededRun run) =>
        await worker.ScalarAsync<int?>("SELECT gems FROM wallets WHERE player_id = $1", run.PlayerId) ?? 0;

    // ---- the genesis anchor (2.0, F23, F24) -------------------------------------------------------------------------

    [Fact]
    public async Task Genesis_StoresTheServersOwnStart_AndWaitsForTheClaim()
    {
        await using var worker = await CreateAsync(stack);
        var run = await worker.SeedRunAsync();

        var decision = await worker.Steps.ProcessAsync(StepJobOf(run, 0), Ct);

        Assert.Equal(new JobDecision(JobAction.Ack, "verified"), decision);
        Assert.Equal(FakeStepRunner.GenesisHash, await worker.ScalarAsync<string>("SELECT genesis_hash FROM runs WHERE run_id = $1", run.RunId));
        Assert.Equal(1L, await worker.ScalarAsync<long>(
            "SELECT count(*) FROM runs WHERE run_id = $1 AND genesis_snapshot @> '{\"genesis\": true}'", run.RunId));
        Assert.Equal(0, (await worker.RunStateAsync(run)).VerifiedSeq);   // no seq 1 yet: nothing to compare
        Assert.Equal("Verified", await Status(worker, run, 0));
        Assert.Null(worker.StepRunner.Requests[0].StartSnapshot);   // the job rebuilds the start from the server's inputs only
        Assert.Equal("11", worker.StepRunner.Requests[0].FloorSeeds[0]);
    }

    [Fact]
    public async Task Genesis_AClaimThatMatchesTheAnchor_SetsVerifiedSeqToOne_UploadFirstOrAnchorFirst()
    {
        await using var worker = await CreateAsync(stack);

        // Upload first: the genesis commit compares when the anchor arrives.
        var first = await VerifiedStartAsync(worker);
        Assert.Equal(("Active", 0, 1), ((await worker.RunStateAsync(first)).Status, (await worker.RunStateAsync(first)).Epoch,
            (await worker.RunStateAsync(first)).VerifiedSeq));

        // Anchor first: the upload's own aggregation compares (the API runs RunAggregator in the upload transaction).
        var second = await worker.SeedRunAsync();
        await worker.Steps.ProcessAsync(StepJobOf(second, 0), Ct);
        await worker.UploadAsync(second, 1, RunActionTypes.StartRun, snapshot: true, hash: FakeStepRunner.GenesisHash);
        await AggregateAsync(worker, second);
        Assert.Equal(1, (await worker.RunStateAsync(second)).VerifiedSeq);
    }

    [Fact]
    public async Task Genesis_AForgedStart_EndsTheRun_Rejected_WhenTheAnchorArrivesAfterTheClaim()
    {
        await using var worker = await CreateAsync(stack);
        var run = await worker.SeedRunAsync();
        await worker.UploadAsync(run, 1, RunActionTypes.StartRun, snapshot: true, hash: "a-richer-start");
        await worker.UploadAsync(run, 2);
        await worker.UploadAsync(run, 3, RunActionTypes.NextFloor, snapshot: true);

        await worker.Steps.ProcessAsync(StepJobOf(run, 0), Ct);

        var state = await worker.RunStateAsync(run);
        Assert.Equal("Rejected", state.Status);
        Assert.Equal(0, state.VerifiedSeq);
        Assert.Equal(0, state.LastSeq);   // everything after the anchor is archived
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM run_actions_voided WHERE run_id = $1", run.RunId));
        Assert.Equal("Voided", await Status(worker, run, 1));
        Assert.Equal("Verified", await Status(worker, run, 0));   // the anchor itself stays
        var types = await worker.OutboxTypesAsync("redpanda");
        Assert.Contains("RunRolledBack", types);
        Assert.Contains("AntiCheatAlert", types);
        var rolled = (await worker.OutboxPayloadsAsync("RunRolledBack")).Single();
        using var document = JsonDocument.Parse(rolled);
        Assert.True(document.RootElement.GetProperty("payload").GetProperty("terminal").GetBoolean());
        Assert.Equal("GenesisMismatch", document.RootElement.GetProperty("payload").GetProperty("reason").GetString());
        Assert.Equal(1, worker.Metrics.Count("rpg.run_rollbacks", "terminal=True"));
    }

    [Fact]
    public async Task Genesis_AForgedStart_IsRejectedAtTheUpload_WhenTheAnchorIsAlreadyThere()
    {
        await using var worker = await CreateAsync(stack);
        var run = await worker.SeedRunAsync();
        await worker.Steps.ProcessAsync(StepJobOf(run, 0), Ct);
        await worker.UploadAsync(run, 1, RunActionTypes.StartRun, snapshot: true, hash: "forged");

        var result = await AggregateAsync(worker, run);

        Assert.Equal("rejected", result.Result);
        Assert.Equal(Rpg.Contracts.Runs.StepMismatchReason.GenesisMismatch, result.Reason);
        Assert.Equal("Rejected", (await worker.RunStateAsync(run)).Status);
    }

    [Fact]
    public async Task Genesis_ARunAbandonedBeforeTheJobRan_IsANoOp_NoGodotRun()
    {
        await using var worker = await CreateAsync(stack);
        var run = await worker.SeedRunAsync(runStatus: "Abandoned");

        var decision = await worker.Steps.ProcessAsync(StepJobOf(run, 0), Ct);

        Assert.Equal(new JobDecision(JobAction.Ack, "run_gone"), decision);
        Assert.Equal(0, worker.StepRunner.Calls);
        Assert.Equal("Voided", await Status(worker, run, 0));
        Assert.Equal(1, worker.Metrics.Count("rpg.step_jobs", "result=run_gone"));
    }

    [Fact]
    public async Task Genesis_ADeadLetteredJob_LeavesTheUploadsStoredAndTheGateShut()
    {
        await using var worker = await CreateAsync(stack, new Dictionary<string, string?> { ["Verifier:MaxAttempts"] = "1" });
        var run = await worker.SeedRunAsync();
        await worker.UploadAsync(run, 1, RunActionTypes.StartRun, snapshot: true, hash: FakeStepRunner.GenesisHash);
        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Error());

        var decision = await worker.Steps.ProcessAsync(StepJobOf(run, 0), Ct);

        Assert.Equal(JobAction.DeadLetter, decision.Action);
        Assert.Equal("attempts", decision.Reason);
        var state = await worker.RunStateAsync(run);
        Assert.Equal(("Active", 0, 0, 1), (state.Status, state.Epoch, state.VerifiedSeq, state.LastSeq));
        Assert.Equal("Pending", await Status(worker, run, 0));
        Assert.NotNull(await worker.ScalarAsync<DateTime?>("SELECT dead_lettered_at FROM run_steps WHERE run_id = $1 AND step_no = 0", run.RunId));
        Assert.Equal(0, await worker.ScalarAsync<int>("SELECT verified_seq FROM runs WHERE run_id = $1", run.RunId));
    }

    // ---- the verified prefix, links and floors (2.3) -----------------------------------------------------------------

    [Fact]
    public async Task Steps_VerifyInAnyOrder_ButTheFloorIsVerifiedOnlyOnceThePrefixReachesItsEnd()
    {
        await using var worker = await CreateAsync(stack);
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2);
        await worker.UploadAsync(run, 3, RunActionTypes.Battle, snapshot: true);          // step 1: 1 to 3
        await worker.UploadAsync(run, 4);
        await worker.UploadAsync(run, 5, RunActionTypes.NextFloor, snapshot: true);        // step 2: 3 to 5, leaves floor 0

        var later = await worker.Steps.ProcessAsync(StepJobOf(run, 2), Ct);              // F6: out of order
        Assert.Equal("verified", later.Result);
        Assert.Equal(1, (await worker.RunStateAsync(run)).VerifiedSeq);
        Assert.Null(await worker.ScalarAsync<DateTime?>("SELECT verified_at FROM run_floors WHERE run_id = $1 AND floor = 0", run.RunId));

        await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);

        Assert.Equal(5, (await worker.RunStateAsync(run)).VerifiedSeq);
        Assert.NotNull(await worker.ScalarAsync<DateTime?>("SELECT verified_at FROM run_floors WHERE run_id = $1 AND floor = 0", run.RunId));
        var payload = JsonDocument.Parse((await worker.OutboxPayloadsAsync("FloorVerified")).Single()).RootElement.GetProperty("payload");
        Assert.Equal((0, 5), (payload.GetProperty("floor").GetInt32(), payload.GetProperty("endSeq").GetInt32()));
        Assert.True(worker.Metrics.Count("rpg.fanin", "result=waiting") >= 1);   // the later step waited for the earlier one
    }

    [Fact]
    public async Task ABrokenLink_RollsTheRunBack_BlamingTheLaterStep()
    {
        await using var worker = await CreateAsync(stack);
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.NextFloor, snapshot: true);   // step 1: 1 to 2
        await worker.UploadAsync(run, 3, RunActionTypes.NextFloor, snapshot: true, floor: 1);   // step 2: 2 to 3
        worker.StepRunner.Handler = (request, _) => Task.FromResult(request.ToSeq == 2
            ? FakeStepRunner.Ok(new StepVerdict(ReplayVerdict.Verified, null, null, null, "h1", "not-what-the-next-step-starts-from",
                null, [], null, "", "fake", DateTimeOffset.UtcNow))
            : worker.StepRunner.Honest(request));

        await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);
        await worker.Steps.ProcessAsync(StepJobOf(run, 2), Ct);

        var state = await worker.RunStateAsync(run);
        Assert.Equal(("Active", 1, 1, 1), (state.Status, state.Epoch, state.VerifiedSeq, state.LastSeq));
        var payload = JsonDocument.Parse((await worker.OutboxPayloadsAsync("RunRolledBack")).Single()).RootElement.GetProperty("payload");
        Assert.Equal("LinkBroken", payload.GetProperty("reason").GetString());
        Assert.False(payload.GetProperty("terminal").GetBoolean());
    }

    [Fact]
    public async Task AFabricatedBattle_IsRejectedAsConditionsMismatch_RollsTheRunBack_AndNothingIsPaid()
    {
        await using var worker = await CreateAsync(stack);
        worker.StepRunner.Facts = BossFacts;   // were it replayed, this battle would pay for beating a boss
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2);
        await worker.UploadAsync(run, 3, RunActionTypes.Battle, snapshot: true);   // step 1: 1 to 3, the "boss"
        // Godot finds the claimed conditions are not what the run produces at this point: the step is rejected before the
        // battle is replayed, so the result carries no battle verdict at all (F15).
        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Rejected(StepMismatchReason.ConditionsMismatch, seq: 3));

        var decision = await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);

        Assert.Equal("rejected", decision.Result);
        var state = await worker.RunStateAsync(run);
        Assert.Equal(("Active", 1, 1, 1), (state.Status, state.Epoch, state.VerifiedSeq, state.LastSeq));   // back to the verified checkpoint
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger WHERE player_id = $1", run.PlayerId));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks WHERE player_id = $1", run.PlayerId));
        Assert.Equal(0, await WalletAsync(worker, run));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM battle_sessions WHERE run_id = $1", run.RunId));
        Assert.Equal(1L, await worker.ScalarAsync<long>(
            "SELECT count(*) FROM battle_sessions_voided WHERE run_id = $1 AND status = 'Submitted'", run.RunId));   // archived, never decided
        var rolledBack = JsonDocument.Parse((await worker.OutboxPayloadsAsync("RunRolledBack")).Single()).RootElement.GetProperty("payload");
        Assert.Equal("ConditionsMismatch", rolledBack.GetProperty("reason").GetString());
        Assert.False(rolledBack.GetProperty("terminal").GetBoolean());
        Assert.Single(await worker.OutboxPayloadsAsync("AntiCheatAlert"));
        Assert.Empty(await worker.OutboxPayloadsAsync("BattleVerified"));
        Assert.Empty(await worker.OutboxPayloadsAsync("RewardPending"));
        Assert.Equal(1, worker.Metrics.Count("rpg.step_mismatches", "reason=ConditionsMismatch"));
    }

    [Fact]
    public async Task TheAggregatorsEvents_AreWrittenInTheStepVerdictsTransaction_AllOrNothing()
    {
        await using var worker = await CreateAsync(stack);
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.NextFloor, snapshot: true);   // step 1: 1 to 2
        worker.StepRunner.Handler = (request, _) => Task.FromResult(FakeStepRunner.Ok(new StepVerdict(ReplayVerdict.Rejected, 2002,
            "ReplayMismatch", new StepMismatch(StepMismatchReason.StateHashMismatch, 2, "d"), request.StartStateHash!, "", null, [], null,
            "", "fake", DateTimeOffset.UtcNow)));
        // The last row the decision writes fails: nothing the transaction did may remain (F18, scenario 3's other half).
        await worker.ExecuteAsync(
            """
            CREATE FUNCTION fail_alert() RETURNS trigger LANGUAGE plpgsql AS
            $$ BEGIN IF NEW.type = 'AntiCheatAlert' THEN RAISE EXCEPTION 'injected'; END IF; RETURN NEW; END $$;
            CREATE TRIGGER fail_alert BEFORE INSERT ON outbox FOR EACH ROW EXECUTE FUNCTION fail_alert();
            """);

        await Assert.ThrowsAnyAsync<Exception>(() => worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct));

        var state = await worker.RunStateAsync(run);
        Assert.Equal((0, 1), (state.Epoch, state.VerifiedSeq));   // no rollback
        Assert.Equal("Pending", await worker.ScalarAsync<string>("SELECT status FROM run_steps WHERE run_id = $1 AND step_no = 1", run.RunId));
        Assert.Empty(await worker.OutboxPayloadsAsync("RunRolledBack"));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM run_actions_voided WHERE run_id = $1", run.RunId));

        // Without the fault, the verdict, the rollback and both events land together, unpublished (only the relay publishes).
        await worker.ExecuteAsync("DROP TRIGGER fail_alert ON outbox");
        await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);

        Assert.Equal(1, (await worker.RunStateAsync(run)).Epoch);
        Assert.Single(await worker.OutboxPayloadsAsync("RunRolledBack"));
        Assert.Single(await worker.OutboxPayloadsAsync("AntiCheatAlert"));
        Assert.Equal(0L, await worker.ScalarAsync<long>(
            "SELECT count(*) FROM outbox WHERE type IN ('RunRolledBack','AntiCheatAlert') AND published_at IS NOT NULL"));
    }

    [Fact]
    public async Task AFloorsDigest_IsStored_WhenItsStepEntersTheVerifiedPrefix()
    {
        await using var worker = await CreateAsync(stack);
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.NextFloor, snapshot: true);
        worker.StepRunner.Handler = (request, _) => Task.FromResult(FakeStepRunner.Ok(new StepVerdict(ReplayVerdict.Verified, null, null,
            null, request.StartStateHash!, request.Actions[^1].StateHash, null, [],
            JsonDocument.Parse("""{"floor":0,"floorHash":"abc","rooms":[{"cell":1,"role":"Boss"}]}""").RootElement.Clone(), "", "fake",
            DateTimeOffset.UtcNow)));

        await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);

        Assert.Equal("abc", await worker.ScalarAsync<string>("SELECT digest->>'floorHash' FROM run_floors WHERE run_id = $1 AND floor = 0", run.RunId));
    }

    // ---- battles, pending gems (2.5, F14) ----------------------------------------------------------------------------

    [Fact]
    public async Task ABattleStep_CommitsTheBattleVerdict_AndItsGemsStayPendingUntilThePrefixReachesIt()
    {
        await using var worker = await CreateAsync(stack);
        worker.StepRunner.Facts = BossFacts;
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.NextFloor, snapshot: true);          // step 1: 1 to 2
        await worker.UploadAsync(run, 3, RunActionTypes.Battle, snapshot: true, floor: 1);   // step 2: 2 to 3, the battle

        await worker.Steps.ProcessAsync(StepJobOf(run, 2), Ct);   // the battle's step first: step 1 is still pending

        var battleId = $"{run.RunId:D}/f1/c3";
        Assert.Equal("Verified", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battleId));
        Assert.Equal("pending", await worker.ScalarAsync<string>("SELECT status FROM wallet_ledger WHERE ref_battle_id = $1", battleId));
        Assert.Equal("warrior", await worker.ScalarAsync<string>("SELECT character_id FROM wallet_ledger WHERE ref_battle_id = $1", battleId));
        Assert.Equal(0, await WalletAsync(worker, run));   // the wallet is untouched
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks WHERE battle_id = $1", battleId));   // a pending row holds no mark
        Assert.Contains("RewardPending", await worker.OutboxTypesAsync("redpanda"));
        Assert.DoesNotContain("RewardGranted", await worker.OutboxTypesAsync("redpanda"));
        Assert.Contains("BattleVerified", await worker.OutboxTypesAsync("redpanda"));

        await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);   // the prefix now reaches the battle

        Assert.Equal(3, (await worker.RunStateAsync(run)).VerifiedSeq);
        Assert.Equal("released", await worker.ScalarAsync<string>("SELECT status FROM wallet_ledger WHERE ref_battle_id = $1", battleId));
        Assert.Equal(10, await WalletAsync(worker, run));
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks WHERE battle_id = $1", battleId));   // claimed with the payment
        Assert.Contains("RewardGranted", await worker.OutboxTypesAsync("redpanda"));
        Assert.Equal(await WalletAsync(worker, run),
            await worker.ScalarAsync<long>("SELECT COALESCE(sum(delta), 0) FROM wallet_ledger WHERE status = 'released' AND player_id = $1", run.PlayerId));
    }

    [Fact]
    public async Task ARejectedStep_VoidsTheGemsOfALaterBattle_FreesItsMark_AndArchivesTheTail()
    {
        await using var worker = await CreateAsync(stack);
        worker.StepRunner.Facts = BossFacts;
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2);
        await worker.UploadAsync(run, 3, RunActionTypes.NextFloor, snapshot: true);          // step 1: 1 to 3
        await worker.UploadAsync(run, 4);
        await worker.UploadAsync(run, 5, RunActionTypes.Battle, snapshot: true, floor: 1);   // step 2: 3 to 5, the boss
        await worker.Steps.ProcessAsync(StepJobOf(run, 2), Ct);                               // pending gems, waiting
        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Rejected(StepMismatchReason.ActionRefused, seq: 2));

        var decision = await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);                // F4: the earlier step is rejected

        Assert.Equal("rejected", decision.Result);
        var state = await worker.RunStateAsync(run);
        Assert.Equal(("Active", 1, 1, 1), (state.Status, state.Epoch, state.VerifiedSeq, state.LastSeq));   // back to the verified checkpoint
        var battleId = $"{run.RunId:D}/f1/c5";
        Assert.Equal("voided", await worker.ScalarAsync<string>("SELECT status FROM wallet_ledger WHERE ref_battle_id = $1", battleId));
        Assert.Equal(0, await WalletAsync(worker, run));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks WHERE battle_id = $1", battleId));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM battle_sessions WHERE run_id = $1", run.RunId));   // the id is free again
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM battle_sessions_voided WHERE run_id = $1", run.RunId));
        Assert.Equal(4L, await worker.ScalarAsync<long>("SELECT count(*) FROM run_actions_voided WHERE run_id = $1 AND epoch = 0", run.RunId));
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM run_actions WHERE run_id = $1", run.RunId));
        Assert.Equal(["Verified", "Voided", "Voided"], await worker.StringsAsync("SELECT status FROM run_steps WHERE run_id = $1 ORDER BY step_no", run.RunId));
        var types = await worker.OutboxTypesAsync("redpanda");
        Assert.Contains("RewardVoided", types);
        Assert.Contains("AntiCheatAlert", types);
        Assert.DoesNotContain("RewardGranted", types);
        Assert.Equal(1, worker.Metrics.Count("rpg.step_mismatches", "reason=ActionRefused"));
    }

    [Fact]
    public async Task AReleasedGem_IsNeverVoided()
    {
        await using var worker = await CreateAsync(stack);
        worker.StepRunner.Facts = BossFacts;
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.Battle, snapshot: true);          // step 1: 1 to 2, the boss
        await worker.UploadAsync(run, 3, RunActionTypes.NextFloor, snapshot: true);       // step 2: 2 to 3
        await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);
        Assert.Equal(10, await WalletAsync(worker, run));
        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Rejected(StepMismatchReason.StateHashMismatch, seq: 3));

        await worker.Steps.ProcessAsync(StepJobOf(run, 2), Ct);

        var state = await worker.RunStateAsync(run);
        Assert.Equal(("Active", 1, 2), (state.Status, state.Epoch, state.VerifiedSeq));   // rolled back to the verified battle
        Assert.Equal(10, await WalletAsync(worker, run));
        Assert.Equal("released", await worker.ScalarAsync<string>("SELECT status FROM wallet_ledger WHERE player_id = $1", run.PlayerId));
    }

    // ---- idempotency and retries (F1, F2, F8, F9, F10, F16) ------------------------------------------------------------

    [Fact]
    public async Task TheSameJobTwice_OneVerdict_AndTheSecondIsADuplicate()
    {
        await using var worker = await CreateAsync(stack);
        worker.StepRunner.Facts = BossFacts;
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.Battle, snapshot: true);

        var first = await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);
        var second = await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);

        Assert.Equal("verified", first.Result);
        Assert.Equal("duplicate", second.Result);
        Assert.Equal(2, worker.StepRunner.Calls);   // genesis + the one real step; the duplicate never reached Godot
        Assert.Equal(10, await WalletAsync(worker, run));
    }

    [Fact]
    public async Task TwoWorkersAtOnce_OneVerdict_OneRelease()
    {
        await using var worker = await CreateAsync(stack);
        worker.StepRunner.Facts = BossFacts;
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.Battle, snapshot: true);
        var arrived = new TaskCompletionSource();
        var calls = 0;
        worker.StepRunner.Handler = async (request, _) =>
        {
            if (Interlocked.Increment(ref calls) == 2)
            {
                arrived.TrySetResult();
            }

            await arrived.Task.WaitAsync(TimeSpan.FromSeconds(20));   // both runs finish before either commits
            return worker.StepRunner.Honest(request);
        };

        var results = await Task.WhenAll(worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct), worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct));

        Assert.Equal(["duplicate", "verified"], results.Select(r => r.Result).Order());
        Assert.Equal(10, await WalletAsync(worker, run));
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger WHERE player_id = $1", run.PlayerId));
        Assert.Equal(1, (await worker.OutboxTypesAsync("redpanda")).Count(t => t == "RewardGranted"));
    }

    [Fact]
    public async Task ACrashAfterTheCommit_TheRedeliveredStepIsANoOp()
    {
        await using var worker = await CreateAsync(stack);
        worker.StepRunner.Facts = BossFacts;
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.Battle, snapshot: true);
        worker.Steps.AfterCommit = () => throw new InvalidOperationException("the worker died before the ack");

        await Assert.ThrowsAsync<InvalidOperationException>(() => worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct));
        worker.Steps.AfterCommit = null;
        var redelivered = await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);   // F2

        Assert.Equal("duplicate", redelivered.Result);
        Assert.Equal(10, await WalletAsync(worker, run));
        Assert.Equal(1, (await worker.OutboxTypesAsync("redpanda")).Count(t => t == "RewardGranted"));
    }

    [Fact]
    public async Task RunnerErrors_RetryOnTheTiers_ThenDeadLetter_AndNeverRollTheRunBack()
    {
        await using var worker = await CreateAsync(stack);
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.NextFloor, snapshot: true);
        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Error());

        var decisions = new List<JobDecision>();
        for (var i = 0; i < 5; i++)
        {
            decisions.Add(await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct));
        }

        Assert.Equal([5, 30, 120, 120], decisions.Take(4).Select(d => (int)d.Tier!.Delay.TotalSeconds));   // F8
        Assert.All(decisions.Take(4), d => Assert.Equal(JobAction.Retry, d.Action));
        Assert.Equal((JobAction.DeadLetter, "attempts"), (decisions[4].Action, decisions[4].Reason));
        var state = await worker.RunStateAsync(run);
        Assert.Equal(("Active", 0, 1), (state.Status, state.Epoch, state.VerifiedSeq));   // an infrastructure fault is not a cheat
        Assert.Equal("Pending", await Status(worker, run, 1));
        Assert.NotNull(await worker.ScalarAsync<DateTime?>("SELECT dead_lettered_at FROM run_steps WHERE run_id = $1 AND step_no = 1", run.RunId));
    }

    [Fact]
    public async Task AMalformedStep_IsRejectedAfterOneAttempt_NotRetried()
    {
        await using var worker = await CreateAsync(stack);
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.NextFloor, snapshot: true);
        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Rejected(StepMismatchReason.MalformedRequest));

        var decision = await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);   // F7

        Assert.Equal(new JobDecision(JobAction.Ack, "malformed"), decision);
        Assert.Equal(2, worker.StepRunner.Calls);
        Assert.Equal(1, await worker.ScalarAsync<int>("SELECT epoch FROM runs WHERE run_id = $1", run.RunId));   // rolled back like any rejection
        Assert.Equal(1, worker.Metrics.Count("rpg.step_jobs", "result=malformed"));
    }

    [Fact]
    public async Task AWrongRuleset_DeadLettersTheStep_AndLeavesItPending()
    {
        await using var worker = await CreateAsync(stack);
        var run = await worker.SeedRunAsync();
        await worker.ExecuteAsync("UPDATE runs SET ruleset_version = 'another-build' WHERE run_id = $1", run.RunId);

        var decision = await worker.Steps.ProcessAsync(StepJobOf(run, 0), Ct);   // F9

        Assert.Equal((JobAction.DeadLetter, "ruleset"), (decision.Action, decision.Reason));
        Assert.Equal(0, worker.StepRunner.Calls);
        Assert.Equal("Pending", await Status(worker, run, 0));
    }

    [Fact]
    public async Task AStepOfARolledBackEpoch_IsSuperseded_NotRejected()
    {
        await using var worker = await CreateAsync(stack);
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.NextFloor, snapshot: true);
        await worker.ExecuteAsync("UPDATE run_steps SET status = 'Voided' WHERE run_id = $1 AND step_no = 1", run.RunId);

        var decision = await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);   // F10

        Assert.Equal(new JobDecision(JobAction.Ack, "superseded"), decision);
        Assert.Equal(1, worker.StepRunner.Calls);   // only the genesis run
        Assert.Equal(1, worker.Metrics.Count("rpg.step_jobs", "result=superseded"));
    }

    [Fact]
    public async Task APoisonJob_ForAnUnknownStep_GoesToTheDeadLetterQueue()
    {
        await using var worker = await CreateAsync(stack);

        var decision = await worker.Steps.ProcessAsync(new VerifyStepJob(Guid.NewGuid(), 0, 7, FakeGodotProcess.Version, DateTimeOffset.UtcNow), Ct);

        Assert.Equal(JobAction.DeadLetter, decision.Action);
        Assert.StartsWith("poison", decision.Reason);
    }

    [Fact]
    public async Task PostgresDown_PostponesTheStep_WithoutCountingAnAttempt()
    {
        await using var worker = await CreateAsync(stack,
            postgres: "Host=127.0.0.1;Port=1;Database=x;Username=x;Timeout=2;Command Timeout=2");

        var decision = await worker.Steps.ProcessAsync(new VerifyStepJob(Guid.NewGuid(), 0, 0, FakeGodotProcess.Version, DateTimeOffset.UtcNow), Ct);

        Assert.Equal(JobAction.Retry, decision.Action);   // F16
        Assert.Equal(TimeSpan.FromSeconds(30), decision.Tier!.Delay);
        Assert.Equal(0, decision.Attempt);
    }

    [Fact]
    public async Task RedisDown_StillVerifiesTheStep()
    {
        await using var worker = await CreateAsync(stack, redis: "127.0.0.1:1,abortConnect=false,connectTimeout=500,syncTimeout=500");
        worker.StepRunner.Facts = BossFacts;
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.Battle, snapshot: true);

        var decision = await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);   // F17

        Assert.Equal("verified", decision.Result);
        Assert.Equal(10, await WalletAsync(worker, run));
        Assert.True(worker.Metrics.Count("rpg.cache_errors") > 0);
    }

    // ---- ending the run (2.3, F13, F20) ---------------------------------------------------------------------------

    [Fact]
    public async Task AWonRun_BecomesWon_OnlyWhenEveryStepUpToTheEndIsVerified()
    {
        await using var worker = await CreateAsync(stack);
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.NextFloor, snapshot: true);   // step 1
        await worker.UploadAsync(run, 3, RunActionTypes.End, snapshot: true);         // step 2: the end
        await worker.ExecuteAsync("UPDATE runs SET status = 'Verifying', end_seq = 3 WHERE run_id = $1", run.RunId);

        await worker.Steps.ProcessAsync(StepJobOf(run, 2), Ct);
        Assert.Equal("Verifying", (await worker.RunStateAsync(run)).Status);   // the end alone is not enough

        await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);

        Assert.Equal(("Won", 0, 3), ((await worker.RunStateAsync(run)).Status, (await worker.RunStateAsync(run)).Epoch,
            (await worker.RunStateAsync(run)).VerifiedSeq));
        Assert.NotNull(await worker.ScalarAsync<DateTime?>("SELECT ended_at FROM runs WHERE run_id = $1", run.RunId));
        Assert.Contains("RunVerified", await worker.OutboxTypesAsync("redpanda"));
        Assert.Equal(1, worker.Metrics.Count("rpg.run_verdicts", "result=won"));
    }

    [Fact]
    public async Task AWinWithARejectedStep_GoesBackToActive_NeverAVictory()
    {
        await using var worker = await CreateAsync(stack);
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.End, snapshot: true);
        await worker.ExecuteAsync("UPDATE runs SET status = 'Verifying', end_seq = 2 WHERE run_id = $1", run.RunId);
        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Rejected(StepMismatchReason.NotWon, seq: 2));

        await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);

        var state = await worker.RunStateAsync(run);
        Assert.Equal(("Active", 1, 1, 1), (state.Status, state.Epoch, state.VerifiedSeq, state.LastSeq));
        Assert.DoesNotContain("RunVerified", await worker.OutboxTypesAsync("redpanda"));
        Assert.Null(await worker.ScalarAsync<int?>("SELECT end_seq FROM runs WHERE run_id = $1", run.RunId));
    }

    [Fact]
    public async Task PastTheRollbackLimit_TheRunIsRejected_AndNothingPays()
    {
        await using var worker = await CreateAsync(stack);
        worker.StepRunner.Facts = BossFacts;
        var run = await VerifiedStartAsync(worker);
        await worker.ExecuteAsync("UPDATE runs SET rollbacks = 3 WHERE run_id = $1", run.RunId);   // Verify:MaxRollbacks is 3
        await worker.UploadAsync(run, 2, RunActionTypes.Battle, snapshot: true);
        await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);
        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Rejected(StepMismatchReason.ActionRefused, seq: 3));
        await worker.UploadAsync(run, 3, RunActionTypes.NextFloor, snapshot: true, floor: 1);

        await worker.Steps.ProcessAsync(StepJobOf(run, 2), Ct);   // F20

        var state = await worker.RunStateAsync(run);
        Assert.Equal("Rejected", state.Status);
        Assert.NotNull(await worker.ScalarAsync<DateTime?>("SELECT ended_at FROM runs WHERE run_id = $1", run.RunId));
        var payload = JsonDocument.Parse((await worker.OutboxPayloadsAsync("RunRolledBack")).Single()).RootElement.GetProperty("payload");
        Assert.True(payload.GetProperty("terminal").GetBoolean());
        // The battle was inside the verified prefix before the rejection, so its gems stay released: only the unverified tail is lost.
        Assert.Equal(10, await WalletAsync(worker, run));
    }

    [Fact]
    public async Task ALostRunWithACheatedStep_IsRejected_NotResumed()
    {
        await using var worker = await CreateAsync(stack);
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2, RunActionTypes.NextFloor, snapshot: true);
        await worker.ExecuteAsync("UPDATE runs SET status = 'Lost', ended_at = now() WHERE run_id = $1", run.RunId);
        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Rejected(StepMismatchReason.StateHashMismatch, seq: 2));

        await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);

        Assert.Equal("Rejected", (await worker.RunStateAsync(run)).Status);   // a rollback must never bring a finished run back to life
    }

    [Fact]
    public async Task AWinWithNoEndStep_NeverBecomesWon_EvenWithAVerifiedPrefix()
    {
        await using var worker = await CreateAsync(stack);
        var run = await VerifiedStartAsync(worker);   // verified_seq 1: the start matches the anchor
        await worker.ExecuteAsync("UPDATE runs SET status = 'Verifying', end_seq = 1 WHERE run_id = $1", run.RunId);

        var result = await AggregateAsync(worker, run);

        Assert.NotEqual("won", result.Result);   // nothing proved the victory: the end step is what does
        Assert.Equal("Verifying", (await worker.RunStateAsync(run)).Status);
        Assert.DoesNotContain("RunVerified", await worker.OutboxTypesAsync("redpanda"));
    }

    [Fact]
    public async Task AReplayedBattleAfterARollback_PaysAgain_TheVoidedRowKeepsOnlyAMarkedKey()
    {
        await using var worker = await CreateAsync(stack);
        worker.StepRunner.Facts = BossFacts;
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2);
        await worker.UploadAsync(run, 3, RunActionTypes.NextFloor, snapshot: true);          // step 1: 1 to 3
        await worker.UploadAsync(run, 4);
        await worker.UploadAsync(run, 5, RunActionTypes.Battle, snapshot: true, floor: 1);   // step 2: the boss
        await worker.Steps.ProcessAsync(StepJobOf(run, 2), Ct);
        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Rejected(StepMismatchReason.ActionRefused, seq: 2));
        await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);   // rolled back: the pending gems are voided
        worker.StepRunner.Handler = null;

        // The player replays the same floor: the same deterministic battle id, now in epoch 1.
        await worker.UploadAsync(run, 2);
        await worker.UploadAsync(run, 3, RunActionTypes.NextFloor, snapshot: true, epoch: 1);          // step 3
        await worker.UploadAsync(run, 4);
        await worker.UploadAsync(run, 5, RunActionTypes.Battle, snapshot: true, floor: 1, epoch: 1);   // step 4: the same battle id
        await worker.Steps.ProcessAsync(StepJobOf(run, 3, epoch: 1), Ct);
        await worker.Steps.ProcessAsync(StepJobOf(run, 4, epoch: 1), Ct);

        Assert.Equal(["released", "voided"], await worker.StringsAsync(
            "SELECT status FROM wallet_ledger WHERE player_id = $1 ORDER BY status", run.PlayerId));
        Assert.Equal(1L, await worker.ScalarAsync<long>(
            "SELECT count(*) FROM wallet_ledger WHERE player_id = $1 AND idempotency_key LIKE '%#voided:%'", run.PlayerId));
        Assert.Equal(10, await WalletAsync(worker, run));   // paid once, for the run that stood
    }

    [Fact]
    public async Task WhatAPassVerifiedBeforeARejectedStep_IsSettled_AndTheFloorsDigestSurvivesTheRollback()
    {
        await using var worker = await CreateAsync(stack);
        worker.StepRunner.Facts = BossFacts;
        var run = await VerifiedStartAsync(worker);
        await worker.UploadAsync(run, 2);
        await worker.UploadAsync(run, 3, RunActionTypes.NextFloor, snapshot: true);          // step 1: 1 to 3, leaves floor 0
        await worker.UploadAsync(run, 4);
        await worker.UploadAsync(run, 5, RunActionTypes.Battle, snapshot: true, floor: 1);   // step 2: 3 to 5, the boss
        await worker.UploadAsync(run, 6);
        await worker.UploadAsync(run, 7, RunActionTypes.NextFloor, snapshot: true, floor: 1);   // step 3: 5 to 7, rejected
        var honest = worker.StepRunner.Handler;
        worker.StepRunner.Handler = (request, _) => Task.FromResult(request.ToSeq switch
        {
            7 => FakeStepRunner.Rejected(StepMismatchReason.ActionRefused, seq: 6),
            3 => FakeStepRunner.Ok(new StepVerdict(ReplayVerdict.Verified, null, null, null, request.StartStateHash!,
                request.Actions[^1].StateHash, null, [],
                JsonDocument.Parse("""{"floor":0,"floorHash":"kept"}""").RootElement.Clone(), "", "fake", DateTimeOffset.UtcNow)),
            _ => worker.StepRunner.Honest(request),
        });
        _ = honest;
        await worker.Steps.ProcessAsync(StepJobOf(run, 3), Ct);   // the rejection arrives first and waits for its turn
        await worker.Steps.ProcessAsync(StepJobOf(run, 2), Ct);   // the boss, waiting for step 1
        Assert.Equal(1, (await worker.RunStateAsync(run)).VerifiedSeq);

        await worker.Steps.ProcessAsync(StepJobOf(run, 1), Ct);   // one pass: steps 1 and 2 verify, then step 3 is found rejected

        var state = await worker.RunStateAsync(run);
        Assert.Equal(("Active", 1, 5, 5), (state.Status, state.Epoch, state.VerifiedSeq, state.LastSeq));   // back to the verified battle
        Assert.NotNull(await worker.ScalarAsync<DateTime?>("SELECT verified_at FROM run_floors WHERE run_id = $1 AND floor = 0", run.RunId));
        Assert.Equal(10, await WalletAsync(worker, run));   // the boss was inside the prefix: released, not left pending
        Assert.Equal("released", await worker.ScalarAsync<string>("SELECT status FROM wallet_ledger WHERE player_id = $1", run.PlayerId));
        Assert.Equal("kept", await worker.ScalarAsync<string>("SELECT digest->>'floorHash' FROM run_floors WHERE run_id = $1 AND floor = 0", run.RunId));
        Assert.Contains("FloorVerified", await worker.OutboxTypesAsync("redpanda"));
    }

    /// <summary>A run of <paramref name="player"/> with a verified start, a segment step (1 to 2) left pending and a boss battle step (2 to 3) done: its gems wait.</summary>
    private static async Task<SeededRun> RunWithAPendingClearAsync(WorkerHarness worker, Guid player, string status)
    {
        var run = await VerifiedStartAsync(worker, player, status);
        await worker.UploadAsync(run, 2, RunActionTypes.NextFloor, snapshot: true);          // step 1, left pending
        await worker.UploadAsync(run, 3, RunActionTypes.Battle, snapshot: true, floor: 1);   // step 2, the boss
        await worker.Steps.ProcessAsync(StepJobOf(run, 2), Ct);
        Assert.Equal(1, (await worker.RunStateAsync(run)).VerifiedSeq);   // the boss step waits for step 1
        return run;
    }

    [Fact]
    public async Task TwoRunsOfOnePlayer_BothHoldPendingRows_AndOnlyTheFirstReleasedIsPaid()
    {
        await using var worker = await CreateAsync(stack);
        worker.StepRunner.Facts = BossFacts;
        var player = Guid.NewGuid();
        var first = await RunWithAPendingClearAsync(worker, player, "Abandoned");
        var second = await RunWithAPendingClearAsync(worker, player, "Active");
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger WHERE status = 'pending'"));   // nobody blocks anybody
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));

        await worker.Steps.ProcessAsync(StepJobOf(second, 1), Ct);   // the second run is verified first: it is paid first
        await worker.Steps.ProcessAsync(StepJobOf(first, 1), Ct);    // the first run's row finds the mark held

        Assert.Equal(10, await WalletAsync(worker, second));   // one payment for the player, whichever run fought first
        Assert.Equal(["released", "voided"], await worker.StringsAsync("SELECT status FROM wallet_ledger ORDER BY status"));
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
        Assert.StartsWith(second.RunId.ToString("D"), await worker.ScalarAsync<string>("SELECT battle_id FROM completion_marks"));
        var types = await worker.OutboxTypesAsync("redpanda");
        Assert.Equal(1, types.Count(t => t == "RewardGranted"));
        var voided = JsonDocument.Parse((await worker.OutboxPayloadsAsync("RewardVoided")).Single()).RootElement.GetProperty("payload");
        Assert.Equal("AlreadyPaid", voided.GetProperty("reason").GetString());
        Assert.Equal(10, await worker.ScalarAsync<long>("SELECT COALESCE(sum(gems), 0) FROM wallets WHERE player_id = $1", player));
    }

    [Fact]
    public async Task ARunWhosePendingClearIsLaterRejected_NeverBlockedAnotherRunsPayment()
    {
        await using var worker = await CreateAsync(stack);
        worker.StepRunner.Facts = BossFacts;
        var player = Guid.NewGuid();
        var cheated = await RunWithAPendingClearAsync(worker, player, "Abandoned");   // holds a pending row, not a mark
        var honest = await RunWithAPendingClearAsync(worker, player, "Active");
        await worker.Steps.ProcessAsync(StepJobOf(honest, 1), Ct);                   // the honest clear is paid at once
        Assert.Equal(10, await WalletAsync(worker, honest));

        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Rejected(StepMismatchReason.ActionRefused, seq: 2));
        await worker.Steps.ProcessAsync(StepJobOf(cheated, 1), Ct);                  // the other run's earlier step is rejected

        Assert.Equal(10, await WalletAsync(worker, honest));
        Assert.Equal(["released", "voided"], await worker.StringsAsync("SELECT status FROM wallet_ledger ORDER BY status"));
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
    }

    [Fact]
    public async Task AGenesisTheServerCouldNotRebuild_EndsTheRun_NotLeavesItStuck()
    {
        await using var worker = await CreateAsync(stack);
        var run = await worker.SeedRunAsync();
        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Rejected(StepMismatchReason.MalformedRequest));

        var decision = await worker.Steps.ProcessAsync(StepJobOf(run, 0), Ct);

        Assert.Equal("malformed", decision.Result);
        Assert.Equal("Rejected", (await worker.RunStateAsync(run)).Status);
        Assert.Contains("RunRolledBack", await worker.OutboxTypesAsync("redpanda"));
    }

    // ---- helpers ----------------------------------------------------------------------------------------------------

    /// <summary>What the API does inside the upload transaction that stores seq 1: the aggregator alone.</summary>
    private static async Task<Rpg.Economy.AggregateResult> AggregateAsync(WorkerHarness worker, SeededRun run)
    {
        await using var connection = await worker.Data.OpenConnectionAsync(Ct);
        await using var transaction = await connection.BeginTransactionAsync(Ct);
        var result = await Rpg.Economy.RunAggregator.RunAsync(connection, transaction, run.RunId,
            new Rpg.Economy.RunVerifyOptions(), DateTimeOffset.UtcNow, Ct);
        await transaction.CommitAsync(Ct);
        return result;
    }
}
