using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Economy;
using Rpg.Contracts.Events;
using Rpg.Contracts.Serialization;
using Rpg.Economy;
using Rpg.VerifierWorker.Tests.Infrastructure;
using static Rpg.VerifierWorker.Tests.Infrastructure.WorkerHarness;

namespace Rpg.VerifierWorker.Tests;

/// <summary>
/// Spec economy-challenges (slice 4d), section 4: a challenge is a ladder of tiers, a higher tier pays the difference, each
/// tier once per cycle (C1–C14, C16, C21–C24). The fake runner reports <see cref="CompletionFact"/>s the way a future Godot
/// challenge definition would; Godot emits none yet.
/// </summary>
[Collection(StackCollection.Name)]
public class ChallengeSettlementTests(Stack stack)
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private const string Trial = "event.spring.trial-3";

    private static readonly DateTimeOffset Wednesday = new(2026, 11, 4, 12, 0, 0, TimeSpan.Zero);  // 2026-W45
    private static readonly DateTimeOffset NextWednesday = Wednesday.AddDays(7);                      // 2026-W46

    private static Task<WorkerHarness> CreateAsync(Stack stack, Dictionary<string, string?>? settings = null,
        string environment = "Development") =>
        WorkerHarness.CreateAsync(stack, settings, environment: environment);

    /// <summary>Every battle reports these completions for this party, whichever battle it is.</summary>
    private static void Completes(WorkerHarness worker, string[] party, params (string Id, int Tier)[] completions) =>
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request),
            new BattleFacts("enc.trial", [], party, [.. completions.Select(c => new CompletionFact(c.Id, c.Tier))])));

    /// <summary>The battle with this id reports the tier from <paramref name="tiers"/> (by battle id).</summary>
    private static void CompletesByBattle(WorkerHarness worker, string challenge, string[] party, Dictionary<string, int> tiers) =>
        worker.Runner.Handler = (request, _) =>
        {
            var id = FakeReplayRunner.BattleIdOf(request);
            return Task.FromResult(FakeReplayRunner.Verified(id,
                new BattleFacts("enc.trial", [], party, [new CompletionFact(challenge, tiers[id])])));
        };

    private static async Task<List<DomainEvent<RewardGrantedPayload>>> GrantsAsync(WorkerHarness worker) =>
        [.. (await worker.OutboxPayloadsAsync("RewardGranted"))
            .Select(json => JsonSerializer.Deserialize<DomainEvent<RewardGrantedPayload>>(json, RpgJson.Options)!)];

    private static Task<int> GemsAsync(WorkerHarness worker, Guid player) =>
        worker.ScalarAsync<int?>("SELECT gems FROM wallets WHERE player_id = $1", player).ContinueWith(t => t.Result ?? 0, Ct);

    [Fact]
    public async Task RedeliveredBattle_PaysEachTierOnce()  // C1
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10, 10, 15);
        Completes(worker, ["warrior"], (Trial, 3));
        var battle = await worker.SeedAsync();
        worker.Processor.AfterCommit = () => throw new InvalidOperationException("the worker died before the ack");

        await Assert.ThrowsAsync<InvalidOperationException>(() => worker.Processor.ProcessAsync(JobOf(battle), Ct));
        worker.Processor.AfterCommit = null;
        var redelivered = await worker.Processor.ProcessAsync(JobOf(battle), Ct);
        var again = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(("duplicate", "duplicate"), (redelivered.Result, again.Result));
        Assert.Equal(35, await GemsAsync(worker, battle.PlayerId));
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM outbox WHERE type = 'RewardGranted'"));
    }

    [Fact]
    public async Task TheLedgerKeyPerTier_StopsADoublePayment_EvenWithoutTheMarkOrTheStatusGuard()
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10, 10, 15);
        Completes(worker, ["warrior"], (Trial, 3));
        var battle = await worker.SeedAsync(submittedAt: Wednesday);
        // Tier 2 of this very battle is in the ledger already (and the wallet holds it), but no mark exists.
        await worker.ExecuteAsync("INSERT INTO wallets (player_id, gems, version) VALUES ($1, 10, 1)", battle.PlayerId);
        await worker.ExecuteAsync(
            "INSERT INTO wallet_ledger (player_id, currency, delta, reason, ref_battle_id, idempotency_key) VALUES ($1, 'gems', 10, 'completion_mark', 'x', $2)",
            battle.PlayerId, $"mark:{battle.BattleId}:warrior:{Trial}:2");

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(10 + 10 + 15, await GemsAsync(worker, battle.PlayerId));  // tiers 1 and 3 paid now, tier 2 was already there
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM outbox WHERE type = 'RewardGranted'"));
    }

    [Fact]
    public async Task ThreeStarsAfterOne_PaysTiersTwoAndThree()  // C2
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10, 10, 15);
        var first = await worker.SeedAsync(submittedAt: Wednesday);
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        CompletesByBattle(worker, Trial, ["warrior"], new() { [first.BattleId] = 1, [second.BattleId] = 3 });

        await worker.Processor.ProcessAsync(JobOf(first), Ct);
        await worker.Processor.ProcessAsync(JobOf(second), Ct);

        Assert.Equal(35, await GemsAsync(worker, first.PlayerId));
        Assert.Equal(["1:10:2026-W45", "2:10:2026-W45", "3:15:2026-W45"],
            await worker.StringsAsync("SELECT tier || ':' || delta || ':' || cycle_key FROM wallet_ledger ORDER BY tier"));
        Assert.Equal(3, await worker.ScalarAsync<int>("SELECT best_tier FROM completion_marks"));
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
        var grants = await GrantsAsync(worker);
        Assert.Equal([1, 2, 3], grants.Select(g => g.Payload.Tier));
        Assert.Equal([10, 20, 35], grants.Select(g => g.Payload.BalanceAfter));
        Assert.All(grants, g => Assert.Equal((Trial, "2026-W45", (string?)null), (g.Payload.ChallengeId, g.Payload.CycleKey, g.Payload.BossId)));
        Assert.Equal(1, worker.Metrics.Count("rpg.completion_marks", "result=new"));
        Assert.Equal(1, worker.Metrics.Count("rpg.completion_marks", "result=advanced"));
        Assert.Equal(3, worker.Metrics.Count("rpg.reward_tiers_paid"));
    }

    [Fact]
    public async Task LowerTierAfterHigher_PaysNothing()  // C3
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10, 10, 15);
        var first = await worker.SeedAsync(submittedAt: Wednesday);
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        var third = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(2));
        CompletesByBattle(worker, Trial, ["warrior"], new() { [first.BattleId] = 3, [second.BattleId] = 2, [third.BattleId] = 3 });

        await worker.Processor.ProcessAsync(JobOf(first), Ct);
        await worker.Processor.ProcessAsync(JobOf(second), Ct);
        await worker.Processor.ProcessAsync(JobOf(third), Ct);

        Assert.Equal(35, await GemsAsync(worker, first.PlayerId));
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(3, await worker.ScalarAsync<int>("SELECT best_tier FROM completion_marks"));
        Assert.Equal(2, worker.Metrics.Count("rpg.completion_marks", "result=unchanged"));
        Assert.Equal(2, worker.Metrics.Count("rpg.settlements", "result=already_marked"));
    }

    [Fact]
    public async Task FirstClearAtTop_PaysEveryTier()  // C4
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10, 10, 15, 20, 40);
        Completes(worker, ["warrior"], (Trial, 5));
        var battle = await worker.SeedAsync(submittedAt: Wednesday);

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(95, await GemsAsync(worker, battle.PlayerId));
        Assert.Equal(5L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        var grants = await GrantsAsync(worker);
        Assert.Equal([1, 2, 3, 4, 5], grants.Select(g => g.Payload.Tier));
        Assert.Equal([10, 20, 35, 55, 95], grants.Select(g => g.Payload.BalanceAfter));
        Assert.Equal(5L, await worker.ScalarAsync<long>("SELECT version FROM wallets WHERE player_id = $1", battle.PlayerId));
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));  // one mark, one best tier
    }

    [Fact]
    public async Task TierAboveTheLadder_IsCapped_AndALongerLadderLaterPaysTheRest()  // C5
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10, 10);
        var first = await worker.SeedAsync(submittedAt: Wednesday);
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        CompletesByBattle(worker, Trial, ["warrior"], new() { [first.BattleId] = 9, [second.BattleId] = 9 });

        await worker.Processor.ProcessAsync(JobOf(first), Ct);

        Assert.Equal(20, await GemsAsync(worker, first.PlayerId));
        Assert.Equal(2, await worker.ScalarAsync<int>("SELECT best_tier FROM completion_marks"));  // the capped value, not 9
        Assert.Equal(1, worker.Metrics.Count("rpg.completion_marks", "result=capped"));

        await worker.PutLadderAsync(Trial, 2, RewardCycles.Weekly, null, 10, 10, 15);  // the designer adds a third star
        await worker.Processor.ProcessAsync(JobOf(second), Ct);

        Assert.Equal(35, await GemsAsync(worker, first.PlayerId));
        Assert.Equal(3, await worker.ScalarAsync<int>("SELECT best_tier FROM completion_marks"));
        Assert.Equal((3, 15, 2), (await worker.ScalarAsync<int>("SELECT tier FROM wallet_ledger WHERE rule_version = 2"),
            await worker.ScalarAsync<int>("SELECT delta FROM wallet_ledger WHERE rule_version = 2"),
            await worker.ScalarAsync<int>("SELECT rule_version FROM wallet_ledger WHERE tier = 3")));
    }

    [Fact]
    public async Task BadCompletionFacts_AreDropped_AndTheVerdictCommits()  // C6
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10);
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request),
            new BattleFacts("enc.trial", [], ["warrior"],
            [
                new CompletionFact(Trial, 0), new CompletionFact(Trial, -3), new CompletionFact("bad:id", 1),
                new CompletionFact("bad id", 1), new CompletionFact("", 2),
            ])));
        var battle = await worker.SeedAsync(submittedAt: Wednesday);

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal("verified", decision.Result);
        Assert.Equal("Verified", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=ignored_fact"));
    }

    [Fact]
    public async Task AGoodFactBesideBadOnes_StillPays()
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10);
        Completes(worker, ["warrior"], (Trial, 0), (Trial, 1), ("a:b", 4));
        var battle = await worker.SeedAsync(submittedAt: Wednesday);

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(10, await GemsAsync(worker, battle.PlayerId));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=granted"));
    }

    [Fact]
    public async Task AuthoredFact_CannotUseTheBossPrefix()  // C6
    {
        await using var worker = await CreateAsync(stack);  // boss/boss.lich pays 10 for a real boss clear
        Completes(worker, ["warrior"], ("boss/boss.lich", 1));
        var battle = await worker.SeedAsync();

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=ignored_fact"));
    }

    [Fact]
    public async Task WeeklyChallenge_PaysOncePerWeek_AndAgainInTheNext()  // C7
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10, 10, 15);
        Completes(worker, ["warrior"], (Trial, 2));
        var mondayOfW45 = new DateTimeOffset(2026, 11, 2, 0, 0, 0, TimeSpan.Zero);
        var a = await worker.SeedAsync(submittedAt: mondayOfW45);
        var b = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: mondayOfW45.AddDays(6));
        var c = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: NextWednesday);

        await worker.Processor.ProcessAsync(JobOf(a), Ct);
        await worker.Processor.ProcessAsync(JobOf(b), Ct);
        Assert.Equal(20, await GemsAsync(worker, a.PlayerId));  // the same week: nothing more

        await worker.Processor.ProcessAsync(JobOf(c), Ct);

        Assert.Equal(40, await GemsAsync(worker, a.PlayerId));  // a new week: the ladder pays again
        Assert.Equal(["2026-W45:2", "2026-W46:2"],
            await worker.StringsAsync("SELECT cycle_key || ':' || best_tier FROM completion_marks ORDER BY cycle_key"));
        Assert.Equal(4L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));  // last week's rows are untouched
    }

    [Fact]
    public async Task WeekBoundary_UsesSubmissionTime()  // C8
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10);
        Completes(worker, ["warrior"], (Trial, 1));
        var sundayNight = new DateTimeOffset(2026, 11, 8, 23, 59, 59, TimeSpan.Zero);
        var mondayMidnight = new DateTimeOffset(2026, 11, 9, 0, 0, 0, TimeSpan.Zero);
        var a = await worker.SeedAsync(submittedAt: sundayNight);
        var b = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: mondayMidnight);

        // Verified well after both (now), in the order Monday's battle first: the key still comes from the submission.
        await worker.Processor.ProcessAsync(JobOf(b), Ct);
        await worker.Processor.ProcessAsync(JobOf(a), Ct);

        Assert.Equal(["2026-W45", "2026-W46"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks ORDER BY cycle_key"));
        Assert.Equal(20, await GemsAsync(worker, a.PlayerId));
    }

    [Theory]
    [InlineData("2026-12-31T10:00:00Z", "2026-W53")]   // a 53-week year
    [InlineData("2021-01-01T10:00:00Z", "2020-W53")]   // the calendar year differs from the ISO year
    [InlineData("2024-12-30T00:00:00Z", "2025-W01")]
    [InlineData("2026-01-01T00:00:00Z", "2026-W01")]
    [InlineData("2026-11-08T23:59:59Z", "2026-W45")]
    [InlineData("2026-11-09T00:00:00Z", "2026-W46")]
    public void IsoWeekKey_AtYearEnd(string at, string expected) =>  // C9
        Assert.Equal(expected, RewardCycleKeys.Compute(RewardCycles.Weekly, DateTimeOffset.Parse(at), 0, 0));

    [Fact]
    public void TheCycleKey_UsesUtc_OnceIsFixed_AndResetsAddSuffixes()
    {
        var lateInWashington = new DateTimeOffset(2026, 11, 8, 20, 0, 0, TimeSpan.FromHours(-5));  // Monday 01:00 UTC
        Assert.Equal("2026-W46", RewardCycleKeys.Compute(RewardCycles.Weekly, lateInWashington, 0, 0));
        Assert.Equal("once", RewardCycleKeys.Compute(RewardCycles.Once, lateInWashington, 0, 0));
        Assert.Equal("once.r2", RewardCycleKeys.Compute(RewardCycles.Once, lateInWashington, 2, 0));
        Assert.Equal("2026-W46.p3", RewardCycleKeys.Compute(RewardCycles.Weekly, lateInWashington, 0, 3));
        Assert.Equal("2026-W46.r1.p2", RewardCycleKeys.Compute(RewardCycles.Weekly, lateInWashington, 1, 2));
    }

    [Fact]
    public async Task EndedEvent_PaysNothing_AndWritesNoMark()  // C10
    {
        await using var worker = await CreateAsync(stack);
        var end = Wednesday;
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, end, 10, 10);
        Completes(worker, ["warrior"], (Trial, 2));
        var late = await worker.SeedAsync(submittedAt: end);  // ends_at <= submitted_at: over

        var decision = await worker.Processor.ProcessAsync(JobOf(late), Ct);

        Assert.Equal("verified", decision.Result);
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
        Assert.Equal(1, worker.Metrics.Count("rpg.reward_rule_lookups", "result=expired"));
        Assert.Equal(0, worker.Metrics.Count("rpg.settlements", "result=no_rule"));  // not a missing rule: nothing to fix
    }

    [Fact]
    public async Task BattleSubmittedBeforeTheEnd_StillPays_EvenVerifiedAfterIt()  // C10
    {
        await using var worker = await CreateAsync(stack);
        var end = DateTimeOffset.UtcNow.AddHours(-1);  // the event is over by the time the worker settles
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, end, 10, 10);
        Completes(worker, ["warrior"], (Trial, 2));
        var early = await worker.SeedAsync(submittedAt: end.AddMinutes(-1));

        await worker.Processor.ProcessAsync(JobOf(early), Ct);

        Assert.Equal(20, await GemsAsync(worker, early.PlayerId));
    }

    [Fact]
    public async Task LadderEdit_DoesNotRepayOrLoseProgress()  // C11
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10, 10);
        var first = await worker.SeedAsync(submittedAt: Wednesday);
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        var third = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(2));
        CompletesByBattle(worker, Trial, ["warrior"], new() { [first.BattleId] = 2, [second.BattleId] = 2, [third.BattleId] = 3 });
        await worker.Processor.ProcessAsync(JobOf(first), Ct);

        await worker.PutLadderAsync(Trial, 2, RewardCycles.Weekly, null, 5, 5, 5);  // retuned: lower amounts, a third star
        await worker.Processor.ProcessAsync(JobOf(second), Ct);
        await worker.Processor.ProcessAsync(JobOf(third), Ct);

        Assert.Equal(25, await GemsAsync(worker, first.PlayerId));  // 10 + 10 under v1, then only tier 3 at 5 under v2
        Assert.Equal(["1:10:1", "2:10:1", "3:5:2"], await worker.StringsAsync(
            "SELECT tier || ':' || delta || ':' || rule_version FROM wallet_ledger ORDER BY tier"));  // each row keeps the version it was paid at
        Assert.Equal(3, await worker.ScalarAsync<int>("SELECT best_tier FROM completion_marks"));
    }

    [Fact]
    public async Task CycleSwitch_UsesTheNewKey_AndSwitchingBackReusesTheOldMark()  // C11
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Once, null, 10);
        var a = await worker.SeedAsync(submittedAt: Wednesday);
        var b = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        var c = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(2));
        Completes(worker, ["warrior"], (Trial, 1));
        await worker.Processor.ProcessAsync(JobOf(a), Ct);

        await worker.PutLadderAsync(Trial, 2, RewardCycles.Weekly, null, 10);  // once -> weekly: the weekly key is new
        await worker.Processor.ProcessAsync(JobOf(b), Ct);
        Assert.Equal(20, await GemsAsync(worker, a.PlayerId));

        await worker.PutLadderAsync(Trial, 3, RewardCycles.Once, null, 10);    // and back: the once mark still exists
        await worker.Processor.ProcessAsync(JobOf(c), Ct);

        Assert.Equal(20, await GemsAsync(worker, a.PlayerId));
        Assert.Equal(["2026-W45", "once"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks ORDER BY cycle_key"));
    }

    [Fact]
    public async Task ShrunkLadder_KeepsMarks_AndPaysNothingMore()  // C12
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10, 10, 15);
        var a = await worker.SeedAsync(submittedAt: Wednesday);
        var b = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        Completes(worker, ["warrior"], (Trial, 3));
        await worker.Processor.ProcessAsync(JobOf(a), Ct);

        await worker.PutLadderAsync(Trial, 2, RewardCycles.Weekly, null, 10);  // two stars taken away
        await worker.Processor.ProcessAsync(JobOf(b), Ct);

        Assert.Equal(35, await GemsAsync(worker, a.PlayerId));
        Assert.Equal(3, await worker.ScalarAsync<int>("SELECT best_tier FROM completion_marks"));  // never lowered
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
    }

    [Fact]
    public async Task ConcurrentBattles_NeverPayATierTwice()  // C13
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10, 10, 15);
        var a = await worker.SeedAsync(submittedAt: Wednesday);
        var b = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: Wednesday);
        var gate = new TaskCompletionSource();
        var arrived = 0;
        worker.Runner.Handler = async (request, _) =>
        {
            if (Interlocked.Increment(ref arrived) == 2)
            {
                gate.SetResult();
            }

            await gate.Task;
            return FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request),
                new BattleFacts("enc.trial", [], ["warrior"], [new CompletionFact(Trial, 3)]));
        };

        await Task.WhenAll(worker.Processor.ProcessAsync(JobOf(a), Ct), worker.Processor.ProcessAsync(JobOf(b), Ct));

        Assert.Equal(35, await GemsAsync(worker, a.PlayerId));  // the ladder once, not twice
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM outbox WHERE type = 'RewardGranted'"));
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
    }

    [Fact]
    public async Task DuplicateFacts_AreMergedToTheHighestTier()  // C14
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10, 10, 15, 20);
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request),
            new BattleFacts("enc.trial", ["boss.lich", "boss.lich"], ["warrior", "warrior"],
                [new CompletionFact(Trial, 2), new CompletionFact(Trial, 4), new CompletionFact(Trial, 3)])));
        var battle = await worker.SeedAsync(submittedAt: Wednesday);

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(10 + 10 + 15 + 20 + 10, await GemsAsync(worker, battle.PlayerId));  // the ladder once, plus the boss's own 10
        Assert.Equal(5L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));  // one per challenge, one character
    }

    [Fact]
    public async Task ACompletionWithNoRuleOrARetiredOne_PaysNothing_AndALaterRulePaysTheNextWin()  // C16
    {
        await using var worker = await CreateAsync(stack);
        Completes(worker, ["warrior"], ("event.unruled", 2), ("event.retired", 1));
        await worker.PutLadderAsync("event.retired", 1, 0);
        var first = await worker.SeedAsync(submittedAt: Wednesday);
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));

        await worker.Processor.ProcessAsync(JobOf(first), Ct);

        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
        Assert.Equal(1, worker.Metrics.Count("rpg.reward_rule_lookups", "result=missing"));
        Assert.Equal(1, worker.Metrics.Count("rpg.reward_rule_lookups", "result=retired"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=no_rule"));

        await worker.PutLadderAsync("event.unruled", 1, 7, 8);
        await worker.Processor.ProcessAsync(JobOf(second), Ct);

        Assert.Equal(15, await GemsAsync(worker, first.PlayerId));
    }

    [Fact]
    public async Task PartyCharacters_EachHaveTheirOwnBestTier()
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10, 10);
        var a = await worker.SeedAsync(submittedAt: Wednesday);
        var b = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        worker.Runner.Handler = (request, _) =>
        {
            var id = FakeReplayRunner.BattleIdOf(request);
            return Task.FromResult(FakeReplayRunner.Verified(id, id == a.BattleId
                ? new BattleFacts("enc", [], ["warrior"], [new CompletionFact(Trial, 2)])
                : new BattleFacts("enc", [], ["warrior", "cleric"], [new CompletionFact(Trial, 2)])));
        };

        await worker.Processor.ProcessAsync(JobOf(a), Ct);
        await worker.Processor.ProcessAsync(JobOf(b), Ct);

        Assert.Equal(40, await GemsAsync(worker, a.PlayerId));  // warrior 20, then the cleric's own 20
        Assert.Equal(["cleric:2", "warrior:2"], await worker.StringsAsync("SELECT character_id || ':' || best_tier FROM completion_marks ORDER BY 1"));
    }

    // ---- Resets (C18, C21, C24) ----

    private static Task ResetAsync(WorkerHarness worker, string challenge, Guid? player = null) => worker.ExecuteAsync(
        """
        INSERT INTO reward_cycle_resets (challenge_id, player_id, generation, reset_by)
        VALUES ($1, $2::uuid, (SELECT COALESCE(max(generation), 0) + 1 FROM reward_cycle_resets
                         WHERE challenge_id = $1 AND player_id IS NOT DISTINCT FROM $2::uuid), 'test')
        """, challenge, player is null ? DBNull.Value : player);

    [Fact]
    public async Task Reset_LetsTheNextClearPayAgain_AndKeepsHistory()  // C18
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Once, null, 10, 10);
        Completes(worker, ["warrior"], (Trial, 2));
        var a = await worker.SeedAsync(submittedAt: Wednesday);
        var b = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        var c = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(2));
        await worker.Processor.ProcessAsync(JobOf(a), Ct);
        await worker.Processor.ProcessAsync(JobOf(b), Ct);
        Assert.Equal(20, await GemsAsync(worker, a.PlayerId));

        await ResetAsync(worker, Trial);
        await worker.Processor.ProcessAsync(JobOf(c), Ct);

        Assert.Equal(40, await GemsAsync(worker, a.PlayerId));
        Assert.Equal(["once", "once.r1"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks ORDER BY cycle_key"));  // the old mark stays
        Assert.Equal(4L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
    }

    [Fact]
    public async Task BattleSettledAfterAReset_UsesTheNewGeneration()  // C21
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10);
        Completes(worker, ["warrior"], (Trial, 1));
        var played = await worker.SeedAsync(submittedAt: Wednesday);  // played before the reset, settled after it
        await ResetAsync(worker, Trial);

        await worker.Processor.ProcessAsync(JobOf(played), Ct);

        Assert.Equal(["2026-W45.r1"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks"));
    }

    [Fact]
    public async Task PlayerReset_AffectsOnlyThatPlayer()  // C24
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Once, null, 10);
        Completes(worker, ["warrior"], (Trial, 1));
        var alice1 = await worker.SeedAsync(submittedAt: Wednesday);
        var bob1 = await worker.SeedAsync(submittedAt: Wednesday);
        var alice2 = await worker.SeedAsync(player: alice1.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        var bob2 = await worker.SeedAsync(player: bob1.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        foreach (var battle in new[] { alice1, bob1 })
        {
            await worker.Processor.ProcessAsync(JobOf(battle), Ct);
        }

        await ResetAsync(worker, Trial, alice1.PlayerId);
        await worker.Processor.ProcessAsync(JobOf(alice2), Ct);
        await worker.Processor.ProcessAsync(JobOf(bob2), Ct);

        Assert.Equal(20, await GemsAsync(worker, alice1.PlayerId));  // paid again
        Assert.Equal(10, await GemsAsync(worker, bob1.PlayerId));    // keeps their marks
        Assert.Equal(["once", "once.p1"], await worker.StringsAsync(
            "SELECT cycle_key FROM completion_marks WHERE player_id = $1 ORDER BY cycle_key", alice1.PlayerId));
        Assert.Equal(["once"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks WHERE player_id = $1", bob1.PlayerId));
    }

    [Fact]
    public async Task PlayerAndGlobalReset_Stack()  // C24
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10);
        Completes(worker, ["warrior"], (Trial, 1));
        var first = await worker.SeedAsync(submittedAt: Wednesday);
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        var third = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(2));
        await worker.Processor.ProcessAsync(JobOf(first), Ct);
        await ResetAsync(worker, Trial, first.PlayerId);
        await worker.Processor.ProcessAsync(JobOf(second), Ct);

        await ResetAsync(worker, Trial);  // and now everyone, too
        await worker.Processor.ProcessAsync(JobOf(third), Ct);

        Assert.Equal(30, await GemsAsync(worker, first.PlayerId));
        Assert.Equal(["2026-W45", "2026-W45.p1", "2026-W45.r1.p1"],
            await worker.StringsAsync("SELECT cycle_key FROM completion_marks ORDER BY cycle_key"));
    }

    // ---- The clock offset (C22) ----

    [Fact]
    public async Task ClockOffset_MovesTheWeekAndTheEnd()  // C22
    {
        await using var worker = await CreateAsync(stack, new() { ["Settlement:CycleClockOffset"] = "7.00:00:00" });
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10);
        await worker.PutLadderAsync("event.short", 1, RewardCycles.Weekly, Wednesday.AddDays(3), 10);
        Completes(worker, ["warrior"], (Trial, 1), ("event.short", 1));
        var battle = await worker.SeedAsync(submittedAt: Wednesday);

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(["2026-W46"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks"));  // a week later
        Assert.Equal(10, await GemsAsync(worker, battle.PlayerId));                                         // and the short event is over
        Assert.Equal(1, worker.Metrics.Count("rpg.reward_rule_lookups", "result=expired"));
    }

    [Theory]
    [InlineData("Production")]
    [InlineData("Staging")]
    public async Task ClockOffset_IsIgnoredOutsideDevelopment(string environment)  // C22
    {
        await using var worker = await CreateAsync(stack, new() { ["Settlement:CycleClockOffset"] = "7.00:00:00" }, environment);
        await worker.PutLadderAsync(Trial, 1, RewardCycles.Weekly, null, 10);
        Completes(worker, ["warrior"], (Trial, 1));
        var battle = await worker.SeedAsync(submittedAt: Wednesday);

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(["2026-W45"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks"));
        var options = worker.Services.GetRequiredService<Microsoft.Extensions.Options.IOptions<Rpg.VerifierWorker.SettlementOptions>>().Value;
        Assert.Equal(TimeSpan.Zero, options.CycleClockOffset);
    }

    // ---- Bosses: the derived id (C23) ----

    public static TheoryData<string?, string?> Vectors()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Rpg.slnx")))
        {
            dir = dir.Parent;
        }

        var file = Path.Combine(dir!.FullName, "tests", "Rpg.Contracts.Tests", "golden", "challenge-id-vectors.json");
        var data = new TheoryData<string?, string?>();
        foreach (var vector in JsonDocument.Parse(File.ReadAllText(file)).RootElement.EnumerateArray())
        {
            data.Add(vector.GetProperty("bossId").GetString(), vector.GetProperty("challengeId").GetString());
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(Vectors))]
    public void ForBoss_IsDeterministicAndTotal(string? bossId, string? expected)  // C23, the shared vectors
    {
        Assert.Equal(expected, ChallengeIds.ForBoss(bossId));
        Assert.Equal(expected, ChallengeIds.ForBoss(bossId));
    }

    [Fact]
    public async Task AnInvalidBossId_IsNeverGranted_AndAnOverlongOneNeither()  // C23
    {
        await using var worker = await CreateAsync(stack);
        var tooLong = new string('x', 196);  // boss/ + 196 passes 200
        await worker.PutLadderAsync("boss/" + tooLong[..195], 1, 99);
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request),
            new BattleFacts("enc", ["has:colon", tooLong, "has space"], ["warrior"])));
        var battle = await worker.SeedAsync();

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal("verified", decision.Result);
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=bad_id"));
    }

    [Fact]
    public async Task ABossClear_IsBossSlashId_TierOne_AndTheEventKeepsTheBossId()
    {
        await using var worker = await CreateAsync(stack);
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request),
            new BattleFacts("enc.boss", ["boss.lich"], ["warrior"])));
        var battle = await worker.SeedAsync();

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(["boss/boss.lich:once:1"], await worker.StringsAsync("SELECT challenge_id || ':' || cycle_key || ':' || best_tier FROM completion_marks"));
        var grant = Assert.Single(await GrantsAsync(worker));
        Assert.Equal(("boss.lich", "boss/boss.lich", 1, "once"), (grant.Payload.BossId, grant.Payload.ChallengeId, grant.Payload.Tier, grant.Payload.CycleKey));
    }
}
