using System.Text.Json;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Events;
using Rpg.Contracts.Serialization;
using Rpg.Verification;
using Rpg.VerifierWorker.Tests.Infrastructure;
using static Rpg.VerifierWorker.Tests.Infrastructure.WorkerHarness;

namespace Rpg.VerifierWorker.Tests;

/// <summary>
/// Spec settlement-outbox 2.2 and 4 (F1–F8, F15, F16): the verdict, the completion marks, the gems and the events in one
/// transaction, exactly once. The fake runner supplies <see cref="BattleFacts"/> as the Godot runner would.
/// </summary>
[Collection(StackCollection.Name)]
public class SettlementTests(Stack stack)
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static BattleFacts BossFacts(params string[] party) => new("enc.boss", ["boss.lich"], party);

    private static void WinsAgainstABoss(WorkerHarness worker, params string[] party) =>
        worker.Runner.Handler = (request, _) =>
            Task.FromResult(FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request), BossFacts(party)));

    [Fact]
    public async Task ABossVictory_GrantsOneMarkPerCharacter_AndWritesTheLedgerWalletAndEventsTogether()
    {
        await using var worker = await CreateAsync(stack);
        WinsAgainstABoss(worker, "warrior", "cleric");
        var battle = await worker.SeedAsync();

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal("verified", decision.Result);
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks WHERE player_id = $1", battle.PlayerId));
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger WHERE player_id = $1", battle.PlayerId));
        Assert.Equal(20, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", battle.PlayerId));
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT version FROM wallets WHERE player_id = $1", battle.PlayerId));
        Assert.Equal(20, await worker.ScalarAsync<int>("SELECT sum(delta)::int FROM wallet_ledger WHERE player_id = $1", battle.PlayerId));
        Assert.Equal(["BattleVerified", "RewardGranted", "RewardGranted"],
            await worker.OutboxTypesAsync("redpanda"));

        var rewards = (await worker.OutboxPayloadsAsync("RewardGranted"))
            .Select(json => JsonSerializer.Deserialize<DomainEvent<RewardGrantedPayload>>(json, RpgJson.Options)!).ToList();
        Assert.Equal([10, 20], rewards.Select(r => r.Payload.BalanceAfter));
        Assert.Equal(["warrior", "cleric"], rewards.Select(r => r.Payload.CharacterId));
        Assert.All(rewards, r =>
        {
            Assert.Equal(battle.PlayerId, r.PlayerId);
            Assert.Equal(battle.RunId, r.RunId);
            Assert.Equal("boss.lich", r.Payload.BossId);
            Assert.Equal(EventTypes.RewardGranted, r.Type);
            Assert.Equal(1, r.SchemaVersion);
        });
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=granted"));
        Assert.Equal(20, worker.Metrics.Count("rpg.gems_granted", "reason=completion_mark"));
        Assert.Equal(EventTopics.Economy, await worker.ScalarAsync<string>("SELECT topic FROM outbox WHERE type = 'RewardGranted' LIMIT 1"));
        Assert.Equal(battle.PlayerId.ToString("D"), await worker.ScalarAsync<string>("SELECT key FROM outbox WHERE type = 'BattleVerified'"));
    }

    [Fact]
    public async Task SameJobTwice_OneSettlement()
    {
        await using var worker = await CreateAsync(stack);
        WinsAgainstABoss(worker, "warrior");
        var battle = await worker.SeedAsync();

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);
        var second = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal("duplicate", second.Result);  // F1, scenario 1
        Assert.Equal(10, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", battle.PlayerId));
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM outbox"));
    }

    [Fact]
    public async Task CrashAfterTheCommit_RedeliveryGrantsNothingTwice()
    {
        await using var worker = await CreateAsync(stack);
        WinsAgainstABoss(worker, "warrior", "cleric");
        var battle = await worker.SeedAsync();
        worker.Processor.AfterCommit = () => throw new InvalidOperationException("the worker died before the ack");

        await Assert.ThrowsAsync<InvalidOperationException>(() => worker.Processor.ProcessAsync(JobOf(battle), Ct));
        worker.Processor.AfterCommit = null;
        var redelivered = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal("duplicate", redelivered.Result);  // F2, scenario 2 (settlement half)
        Assert.Equal(20, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", battle.PlayerId));
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM outbox"));
        Assert.Equal(1, worker.Runner.Calls);
    }

    [Fact]
    public async Task CrashBeforeTheCommit_LeavesNoVerdictNoLedgerNoOutbox()
    {
        await using var worker = await CreateAsync(stack);
        WinsAgainstABoss(worker, "warrior");
        var battle = await worker.SeedAsync();
        // The wallet write fails inside the transaction, after the verdict update and the first event were written.
        await worker.ExecuteAsync("ALTER TABLE wallets ADD CONSTRAINT never_paid CHECK (gems = 0) NOT VALID");

        await Assert.ThrowsAsync<Npgsql.PostgresException>(() => worker.Processor.ProcessAsync(JobOf(battle), Ct));

        Assert.Equal("Submitted", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId));  // F3
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM outbox"));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
        Assert.Equal(0, await worker.ScalarAsync<int>("SELECT attempts FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
    }

    [Fact]
    public async Task ConcurrentWorkers_OneSettlement()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        var gate = new TaskCompletionSource();
        var arrived = 0;
        worker.Runner.Handler = async (request, _) =>
        {
            if (Interlocked.Increment(ref arrived) == 2)
            {
                gate.SetResult();
            }

            await gate.Task;
            return FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request), BossFacts("warrior", "cleric"));
        };

        await Task.WhenAll(worker.Processor.ProcessAsync(JobOf(battle), Ct), worker.Processor.ProcessAsync(JobOf(battle), Ct));

        Assert.Equal(2, worker.Runner.Calls);  // F4: both replayed, one transaction won
        Assert.Equal(20, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", battle.PlayerId));
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM outbox"));
    }

    [Fact]
    public async Task TheLedgerKey_AndTheMarkKey_RefuseADoubleGrant_EvenWithoutTheStatusGuard()
    {
        await using var worker = await CreateAsync(stack);
        WinsAgainstABoss(worker, "warrior", "cleric");
        var battle = await worker.SeedAsync();
        // As if the status guard had been bypassed: a ledger row for warrior's grant exists already (no mark), and cleric
        // already holds this mark from an earlier battle.
        await worker.ExecuteAsync("INSERT INTO wallets (player_id, gems, version) VALUES ($1, 10, 1)", battle.PlayerId);
        await worker.ExecuteAsync(
            "INSERT INTO wallet_ledger (player_id, currency, delta, reason, ref_battle_id, idempotency_key) VALUES ($1, 'gems', 10, 'completion_mark', 'x', $2)",
            battle.PlayerId, $"mark:{battle.BattleId}:warrior:boss/boss.lich");
        var earlier = await worker.SeedAsync(player: battle.PlayerId, runStatus: "Won");
        await worker.ExecuteAsync(
            "INSERT INTO completion_marks (player_id, character_id, challenge_id, battle_id) VALUES ($1, 'cleric', 'boss/boss.lich', $2)",
            battle.PlayerId, earlier.BattleId);

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(10, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", battle.PlayerId));  // F5: no money moved
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Empty(await worker.OutboxPayloadsAsync("RewardGranted"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=already_marked"));
    }

    [Fact]
    public async Task ARejection_SettlesNothing_AndPublishesBattleRejected()
    {
        await using var worker = await CreateAsync(stack);
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Rejected(FakeReplayRunner.BattleIdOf(request)));
        var battle = await worker.SeedAsync();

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(["BattleRejected"], await worker.OutboxTypesAsync("redpanda"));  // F6, scenario 5
        var rejected = JsonSerializer.Deserialize<DomainEvent<BattleRejectedPayload>>(
            Assert.Single(await worker.OutboxPayloadsAsync("BattleRejected")), RpgJson.Options)!;
        Assert.Equal(2002, rejected.Payload.ErrorCode);
        Assert.Equal(MismatchReason.FinalHashMismatch, rejected.Payload.Reason);
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallets"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=rejected"));
    }

    [Theory]
    [InlineData("no facts")]
    [InlineData("no boss")]
    [InlineData("defeat")]
    public async Task AVerifiedBattleWithoutABossVictory_GrantsNothing(string kind)
    {
        await using var worker = await CreateAsync(stack);
        worker.Runner.Handler = (request, _) => Task.FromResult(kind switch
        {
            "no facts" => FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request)),
            "no boss" => FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request), new BattleFacts("enc.slimes", [], ["warrior"])),
            _ => FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request), BossFacts("warrior"), BattleOutcome.Defeat),
        });
        var battle = await worker.SeedAsync();

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(["BattleVerified"], await worker.OutboxTypesAsync("redpanda"));  // F7
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=no_reward"));
    }

    [Fact]
    public async Task ASecondWinOverTheSameBoss_PaysNothing()
    {
        await using var worker = await CreateAsync(stack);
        WinsAgainstABoss(worker, "warrior");
        var first = await worker.SeedAsync();
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won");

        await worker.Processor.ProcessAsync(JobOf(first), Ct);
        await worker.Processor.ProcessAsync(JobOf(second), Ct);

        Assert.Equal(10, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", first.PlayerId));  // F8
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
        Assert.Equal(["BattleVerified", "RewardGranted", "BattleVerified"], await worker.OutboxTypesAsync("redpanda"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=already_marked"));
    }

    [Fact]
    public async Task ADifferentCharacterOrBoss_IsAnotherMark()
    {
        await using var worker = await CreateAsync(stack);
        var first = await worker.SeedAsync();
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won");
        worker.Runner.Handler = (request, _) =>
        {
            var id = FakeReplayRunner.BattleIdOf(request);
            return Task.FromResult(FakeReplayRunner.Verified(id, id == first.BattleId
                ? BossFacts("warrior") : new BattleFacts("enc.other", ["boss.golem"], ["warrior", "cleric"])));
        };

        await worker.Processor.ProcessAsync(JobOf(first), Ct);
        await worker.Processor.ProcessAsync(JobOf(second), Ct);

        Assert.Equal(30, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", first.PlayerId));
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
    }

    [Fact]
    public async Task SettlementDisabled_StillWritesTheVerdictAndItsEvent()
    {
        await using var worker = await CreateAsync(stack, new() { ["Settlement:Enabled"] = "false" });
        WinsAgainstABoss(worker, "warrior");
        var battle = await worker.SeedAsync();

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(["BattleVerified"], await worker.OutboxTypesAsync("redpanda"));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
    }

    [Fact]
    public async Task ASettlement_ClearsTheCachedWallet()
    {
        await using var worker = await CreateAsync(stack);
        WinsAgainstABoss(worker, "warrior");
        var battle = await worker.SeedAsync();
        var redis = await worker.RedisAsync();
        await redis.StringSetAsync(VerifyPolicy.WalletKey(battle.PlayerId), "stale");

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.False(await redis.KeyExistsAsync(VerifyPolicy.WalletKey(battle.PlayerId)));
    }

    [Fact]
    public async Task RedisDown_StillSettles_AndCountsTheErrors()
    {
        await using var worker = await CreateAsync(stack, redis: "127.0.0.1:1,abortConnect=false,connectTimeout=500,syncTimeout=500");
        WinsAgainstABoss(worker, "warrior");
        var battle = await worker.SeedAsync();

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal("verified", decision.Result);  // F15
        Assert.Equal(10, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", battle.PlayerId));
        Assert.True(worker.Metrics.Count("rpg.cache_errors") >= 1);
    }

    [Fact]
    public async Task APostCommitFailure_NeverChangesTheDecision_OrTheMoney()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        worker.Runner.Handler = (_, _) => Task.FromResult(FakeReplayRunner.Verified(battle.BattleId, BossFacts("warrior")));
        // The cached session cannot be built from these conditions: the post-commit work throws.
        await worker.ExecuteAsync("UPDATE battle_sessions SET conditions = '{\"battleId\": 5}'::jsonb WHERE battle_id = $1", battle.BattleId);

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal("verified", decision.Result);  // F16
        Assert.Equal(10, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", battle.PlayerId));
    }

    [Fact]
    public async Task RandomInterleavings_KeepTheLedgerEqualToTheWallet_AndEveryFactOnce()
    {
        await using var worker = await CreateAsync(stack);
        var players = new[] { Guid.NewGuid(), Guid.NewGuid() };
        var battles = new List<SeededBattle>();
        foreach (var player in players)
        {
            for (var n = 0; n < 4; n++)
            {
                battles.Add(await worker.SeedAsync(player: player, runStatus: n == 0 ? "Active" : "Won"));
            }
        }

        // Each battle faces one of two bosses with one of two parties; every job is delivered three times at once.
        worker.Runner.Handler = async (request, ct) =>
        {
            await Task.Delay(Random.Shared.Next(1, 30), ct);
            var id = FakeReplayRunner.BattleIdOf(request);
            var n = battles.FindIndex(b => b.BattleId == id);
            return FakeReplayRunner.Verified(id, new BattleFacts("enc", [n % 2 == 0 ? "boss.a" : "boss.b"],
                n % 3 == 0 ? ["warrior", "cleric"] : ["warrior"]));
        };

        var deliveries = battles.SelectMany(b => Enumerable.Repeat(b, 3)).OrderBy(_ => Random.Shared.Next()).ToList();
        await Task.WhenAll(deliveries.Select(b => Task.Run(() => worker.Processor.ProcessAsync(JobOf(b), Ct), Ct)));

        foreach (var player in players)
        {
            var gems = await worker.ScalarAsync<int?>("SELECT gems FROM wallets WHERE player_id = $1", player) ?? 0;
            var ledger = await worker.ScalarAsync<int?>("SELECT sum(delta)::int FROM wallet_ledger WHERE player_id = $1", player) ?? 0;
            var marks = await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks WHERE player_id = $1", player);
            Assert.Equal(gems, ledger);
            Assert.Equal(marks * 10, gems);
        }

        Assert.Equal(battles.Count, await worker.ScalarAsync<long>("SELECT count(*) FROM outbox WHERE type = 'BattleVerified'"));
        Assert.Equal(await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"),
            await worker.ScalarAsync<long>("SELECT count(*) FROM outbox WHERE type = 'RewardGranted'"));
        Assert.All(battles, b => Assert.Equal("Verified", worker.ScalarAsync<string>(
            "SELECT status FROM battle_sessions WHERE battle_id = $1", b.BattleId).Result));
    }

    // ---- Spec economy-rewards: the amount is the rule in force, recorded on every ledger row ----

    [Fact]
    public async Task ARuleOf25_PaysEachPartyCharacter25_AndTheLedgerAndEventRecordTheVersion()
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutRuleAsync("boss.lich", 25, version: 2);
        WinsAgainstABoss(worker, "warrior", "cleric");
        var battle = await worker.SeedAsync();

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(50, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", battle.PlayerId));
        Assert.Equal(2L, await worker.ScalarAsync<long>(
            "SELECT count(*) FROM wallet_ledger WHERE delta = 25 AND rule_version = 2 AND challenge_id = 'boss/boss.lich'"));
        var rewards = (await worker.OutboxPayloadsAsync("RewardGranted"))
            .Select(json => JsonSerializer.Deserialize<DomainEvent<RewardGrantedPayload>>(json, RpgJson.Options)!).ToList();
        Assert.All(rewards, r => Assert.Equal((25, 2), (r.Payload.Amount, r.Payload.RuleVersion)));
        Assert.Equal(1, worker.Metrics.Count("rpg.reward_rule_lookups", "result=found"));
        Assert.Equal(50, worker.Metrics.Count("rpg.gems_granted", "reason=completion_mark"));
    }

    [Fact]
    public async Task TwoBossesWithDifferentRules_EachPaysItsOwnAmount()
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutRuleAsync("boss.a", 7, version: 2);
        await worker.PutRuleAsync("boss.b", 30, version: 2);
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(
            FakeReplayRunner.BattleIdOf(request), new BattleFacts("enc", ["boss.a", "boss.b"], ["warrior"])));
        var battle = await worker.SeedAsync();

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(37, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", battle.PlayerId));
        Assert.Equal(7, await worker.ScalarAsync<int>("SELECT delta FROM wallet_ledger WHERE challenge_id = 'boss/boss.a'"));
        Assert.Equal(30, await worker.ScalarAsync<int>("SELECT delta FROM wallet_ledger WHERE challenge_id = 'boss/boss.b'"));
    }

    [Fact]
    public async Task NoRule_GrantsNothing_WritesNoMark_AndALaterRulePaysTheNextWin()
    {
        await using var worker = await CreateAsync(stack);
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(
            FakeReplayRunner.BattleIdOf(request), new BattleFacts("enc", ["boss.new"], ["warrior"])));
        var first = await worker.SeedAsync();
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won");

        var decision = await worker.Processor.ProcessAsync(JobOf(first), Ct);  // F1

        Assert.Equal("verified", decision.Result);
        Assert.Equal("Verified", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", first.BattleId));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=no_rule"));
        Assert.Equal(1, worker.Metrics.Count("rpg.reward_rule_lookups", "result=missing"));

        await worker.PutRuleAsync("boss.new", 40, version: 1);
        await worker.Processor.ProcessAsync(JobOf(second), Ct);

        Assert.Equal(40, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", first.PlayerId));
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
    }

    [Fact]
    public async Task AMarkedBossAndAnUnruledBoss_ReportNoRule_NotAlreadyMarked()
    {
        await using var worker = await CreateAsync(stack);
        var first = await worker.SeedAsync();
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won");
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(
            FakeReplayRunner.BattleIdOf(request),
            new BattleFacts("enc", FakeReplayRunner.BattleIdOf(request) == first.BattleId ? ["boss.lich"] : ["boss.lich", "boss.new"], ["warrior"])));
        await worker.Processor.ProcessAsync(JobOf(first), Ct);

        await worker.Processor.ProcessAsync(JobOf(second), Ct);

        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=no_rule"));
        Assert.Equal(0, worker.Metrics.Count("rpg.settlements", "result=already_marked"));
    }

    [Fact]
    public async Task RetiredRule_PaysNothing()
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutRuleAsync("boss.lich", 0, version: 2);
        WinsAgainstABoss(worker, "warrior");
        var battle = await worker.SeedAsync();

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);  // F2

        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(1, worker.Metrics.Count("rpg.reward_rule_lookups", "result=retired"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=no_rule"));
    }

    [Fact]
    public async Task ARuleWhoseEffectiveTimeIsInTheFuture_IsIgnored()
    {
        await using var worker = await CreateAsync(stack);
        await worker.ExecuteAsync(
            "INSERT INTO reward_rules (challenge_id, currency, amount, version, effective_from, created_by) VALUES ('boss/boss.lich','gems',99,2, now() + interval '1 hour','t')");
        WinsAgainstABoss(worker, "warrior");
        var battle = await worker.SeedAsync();

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(10, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", battle.PlayerId));
        Assert.Equal(1, await worker.ScalarAsync<int>("SELECT rule_version FROM wallet_ledger"));
    }

    [Fact]
    public async Task RuleChangedBetweenTwoBattles_EachLedgerRowRecordsItsVersion()
    {
        await using var worker = await CreateAsync(stack);
        var first = await worker.SeedAsync();
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won");
        worker.Runner.Handler = (request, _) =>
            Task.FromResult(FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request),
                BossFacts(FakeReplayRunner.BattleIdOf(request) == first.BattleId ? "warrior" : "cleric")));

        await worker.Processor.ProcessAsync(JobOf(first), Ct);
        await worker.PutRuleAsync("boss.lich", 25, version: 2);  // F3
        await worker.Processor.ProcessAsync(JobOf(second), Ct);

        Assert.Equal(10, await worker.ScalarAsync<int>("SELECT delta FROM wallet_ledger WHERE ref_battle_id = $1", first.BattleId));
        Assert.Equal(1, await worker.ScalarAsync<int>("SELECT rule_version FROM wallet_ledger WHERE ref_battle_id = $1", first.BattleId));
        Assert.Equal(25, await worker.ScalarAsync<int>("SELECT delta FROM wallet_ledger WHERE ref_battle_id = $1", second.BattleId));
        Assert.Equal(2, await worker.ScalarAsync<int>("SELECT rule_version FROM wallet_ledger WHERE ref_battle_id = $1", second.BattleId));
        Assert.Equal(35, await worker.ScalarAsync<int>("SELECT gems FROM wallets WHERE player_id = $1", first.PlayerId));
    }

    [Theory]
    [InlineData("warr:ior", "boss.lich")]
    [InlineData("warrior", "boss lich")]
    public async Task AnIdWithAColonOrASpace_IsNeverGranted_AndTheVerdictStillCommits(string character, string boss)
    {
        await using var worker = await CreateAsync(stack);
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(
            FakeReplayRunner.BattleIdOf(request), new BattleFacts("enc", [boss], [character])));
        var battle = await worker.SeedAsync();

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);  // F10

        Assert.Equal("verified", decision.Result);
        Assert.Equal("Verified", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=bad_id"));
    }

    [Fact]
    public void TwoColonIds_NeverShareALedgerKey()
    {
        // a:b + c and a + b:c would both build "mark:<battle>:a:b:c"; the id check refuses either colon id, so only a clean
        // pair can ever reach the ledger key.
        Assert.False(Economy.ChallengeIds.IsKeySafe("a:b"));
        Assert.False(Economy.ChallengeIds.IsKeySafe("b:c"));
        Assert.False(Economy.ChallengeIds.IsKeySafe(" "));
        Assert.True(Economy.ChallengeIds.IsKeySafe("boss/boss.lich"));
    }

    [Fact]
    public async Task TheEventRowsOfASettlement_CarryTheWorkersTraceParent()
    {
        using var listener = new System.Diagnostics.ActivityListener
        {
            ShouldListenTo = _ => true,
            Sample = (ref System.Diagnostics.ActivityCreationOptions<System.Diagnostics.ActivityContext> _) =>
                System.Diagnostics.ActivitySamplingResult.AllDataAndRecorded,
        };
        System.Diagnostics.ActivitySource.AddActivityListener(listener);
        await using var worker = await CreateAsync(stack);
        WinsAgainstABoss(worker, "warrior");
        var battle = await worker.SeedAsync();
        using var source = new System.Diagnostics.ActivitySource("test.job");
        using var job = source.StartActivity("verify.battle")!;

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        foreach (var type in new[] { "BattleVerified", "RewardGranted" })
        {
            var parent = await worker.ScalarAsync<string>("SELECT traceparent FROM outbox WHERE type = $1", type) ?? "";
            Assert.True(System.Diagnostics.ActivityContext.TryParse(parent, null, out var context), parent);
            Assert.Equal(job.TraceId, context.TraceId);  // the worker's trace, continued from the job
            Assert.NotEqual(job.SpanId, context.SpanId);  // the replay span, a child of the job
        }
    }

    private static Task<WorkerHarness> CreateAsync(Stack stack, Dictionary<string, string?>? settings = null,
        string? postgres = null, string? redis = null) =>
        WorkerHarness.CreateAsync(stack, settings, postgres, redis);
}
