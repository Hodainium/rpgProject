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
/// Spec economy-challenges (slice 4d), section 4: a challenge pays its amount once per character per cycle (C1–C14, C16,
/// C21–C24). A content star is a challenge of its own, so a score band is several independent challenges, not tiers. The fake
/// runner reports <see cref="CompletionFact"/>s the way the replay does for earned stars.
/// </summary>
[Collection(StackCollection.Name)]
public class ChallengeSettlementTests(Stack stack)
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private const string Win = "demo.challenge.lich_trial.win";
    private const string Fast = "demo.challenge.lich_trial.fast";
    private const string Flawless = "demo.challenge.lich_trial.flawless";

    private static readonly DateTimeOffset Wednesday = new(2026, 11, 4, 12, 0, 0, TimeSpan.Zero);  // 2026-W45
    private static readonly DateTimeOffset NextWednesday = Wednesday.AddDays(7);                      // 2026-W46

    private static Task<WorkerHarness> CreateAsync(Stack stack, Dictionary<string, string?>? settings = null,
        string environment = "Development") =>
        WorkerHarness.CreateAsync(stack, settings, environment: environment);

    /// <summary>The three star challenges of the demo, weekly: win 5, fast 5, flawless 10.</summary>
    private static async Task PutStarsAsync(WorkerHarness worker, string cycle = RewardCycles.Weekly)
    {
        await worker.PutChallengeAsync(Win, 1, 5, cycle, null);
        await worker.PutChallengeAsync(Fast, 1, 5, cycle, null);
        await worker.PutChallengeAsync(Flawless, 1, 10, cycle, null);
    }

    /// <summary>Every battle reports these completions for this party.</summary>
    private static void Completes(WorkerHarness worker, string[] party, params string[] challenges) =>
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request),
            new BattleFacts("enc.trial", [], party, [.. challenges.Select(c => new CompletionFact(c))])));

    /// <summary>The battle with this id reports its own completions (by battle id).</summary>
    private static void CompletesByBattle(WorkerHarness worker, string[] party, Dictionary<string, string[]> perBattle) =>
        worker.Runner.Handler = (request, _) =>
        {
            var id = FakeReplayRunner.BattleIdOf(request);
            return Task.FromResult(FakeReplayRunner.Verified(id,
                new BattleFacts("enc.trial", [], party, [.. perBattle[id].Select(c => new CompletionFact(c))])));
        };

    private static async Task<List<DomainEvent<RewardGrantedPayload>>> GrantsAsync(WorkerHarness worker) =>
        [.. (await worker.OutboxPayloadsAsync("RewardGranted"))
            .Select(json => JsonSerializer.Deserialize<DomainEvent<RewardGrantedPayload>>(json, RpgJson.Options)!)];

    private static Task<int> GemsAsync(WorkerHarness worker, Guid player) =>
        worker.ScalarAsync<int?>("SELECT gems FROM wallets WHERE player_id = $1", player).ContinueWith(t => t.Result ?? 0, Ct);

    [Fact]
    public async Task RedeliveredBattle_PaysEachChallengeOnce()  // C1
    {
        await using var worker = await CreateAsync(stack);
        await PutStarsAsync(worker);
        Completes(worker, ["warrior"], Win, Fast, Flawless);
        var battle = await worker.SeedAsync();
        worker.Processor.AfterCommit = () => throw new InvalidOperationException("the worker died before the ack");

        await Assert.ThrowsAsync<InvalidOperationException>(() => worker.Processor.ProcessAsync(JobOf(battle), Ct));
        worker.Processor.AfterCommit = null;
        var redelivered = await worker.Processor.ProcessAsync(JobOf(battle), Ct);
        var again = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(("duplicate", "duplicate"), (redelivered.Result, again.Result));
        Assert.Equal(20, await GemsAsync(worker, battle.PlayerId));
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM outbox WHERE type = 'RewardGranted'"));
    }

    [Fact]
    public async Task TheLedgerKey_StopsADoublePayment_EvenWithoutTheMarkOrTheStatusGuard()
    {
        await using var worker = await CreateAsync(stack);
        await PutStarsAsync(worker);
        Completes(worker, ["warrior"], Win, Fast);
        var battle = await worker.SeedAsync(submittedAt: Wednesday);
        // The fast star of this very battle is in the ledger already (and the wallet holds it), but no mark exists.
        await worker.ExecuteAsync("INSERT INTO wallets (player_id, gems, version) VALUES ($1, 5, 1)", battle.PlayerId);
        await worker.ExecuteAsync(
            "INSERT INTO wallet_ledger (player_id, currency, delta, reason, ref_battle_id, idempotency_key) VALUES ($1, 'gems', 5, 'completion_mark', 'x', $2)",
            battle.PlayerId, $"mark:{battle.BattleId}:warrior:{Fast}");

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(5 + 5, await GemsAsync(worker, battle.PlayerId));  // win paid now, fast was already there
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(1L, await worker.ScalarAsync<long>("SELECT count(*) FROM outbox WHERE type = 'RewardGranted'"));
    }

    [Fact]
    public async Task EachStarIsItsOwnChallenge_PaidOnItsOwn_InAnyOrder()
    {
        await using var worker = await CreateAsync(stack);
        await PutStarsAsync(worker);
        var first = await worker.SeedAsync(submittedAt: Wednesday);
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        var third = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(2));
        CompletesByBattle(worker, ["warrior"], new()
        {
            [first.BattleId] = [Flawless],         // the third star without the first two
            [second.BattleId] = [Win, Flawless],   // the first adds itself; the third is already held
            [third.BattleId] = [Fast, Win, Flawless],
        });

        await worker.Processor.ProcessAsync(JobOf(first), Ct);
        Assert.Equal(10, await GemsAsync(worker, first.PlayerId));
        await worker.Processor.ProcessAsync(JobOf(second), Ct);
        Assert.Equal(15, await GemsAsync(worker, first.PlayerId));
        await worker.Processor.ProcessAsync(JobOf(third), Ct);

        Assert.Equal(20, await GemsAsync(worker, first.PlayerId));  // each star once: 5 + 5 + 10
        Assert.Equal([Fast, Flawless, Win], await worker.StringsAsync("SELECT challenge_id FROM completion_marks ORDER BY challenge_id"));
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        var grants = await GrantsAsync(worker);
        Assert.Equal([Flawless, Win, Fast], grants.Select(g => g.Payload.ChallengeId));
        Assert.Equal([10, 15, 20], grants.Select(g => g.Payload.BalanceAfter));
        Assert.All(grants, g => Assert.Equal(("2026-W45", (string?)null), (g.Payload.CycleKey, g.Payload.BossId)));
        Assert.Equal(3, worker.Metrics.Count("rpg.completion_marks", "result=new"));
        Assert.Equal(3, worker.Metrics.Count("rpg.completion_marks", "result=existing"));  // the second battle's flawless; the third's win + flawless... counted per character
    }

    [Fact]
    public async Task OneBattle_PaysEveryStarItEarned_AtEachOwnAmount()
    {
        await using var worker = await CreateAsync(stack);
        await PutStarsAsync(worker);
        Completes(worker, ["warrior", "cleric"], Win, Fast, Flawless);
        var battle = await worker.SeedAsync(submittedAt: Wednesday);

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(40, await GemsAsync(worker, battle.PlayerId));  // 20 each for two characters
        Assert.Equal(6L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal([5, 5, 5, 5, 10, 10], await worker.IntsAsync("SELECT delta FROM wallet_ledger ORDER BY id"));  // challenge by challenge, each for both characters
    }

    [Fact]
    public async Task BadCompletionFacts_AreDropped_AndTheVerdictCommits()  // C6
    {
        await using var worker = await CreateAsync(stack);
        await PutStarsAsync(worker);
        Completes(worker, ["warrior"], "bad:id", "bad id", "");
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
        await PutStarsAsync(worker);
        Completes(worker, ["warrior"], "a:b", Win, "");
        var battle = await worker.SeedAsync(submittedAt: Wednesday);

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(5, await GemsAsync(worker, battle.PlayerId));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=granted"));
    }

    [Fact]
    public async Task AuthoredFact_CannotUseTheBossPrefix()  // C6
    {
        await using var worker = await CreateAsync(stack);  // boss/boss.lich pays 10 for a real boss clear
        Completes(worker, ["warrior"], "boss/boss.lich");
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
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Weekly, null);
        Completes(worker, ["warrior"], Win);
        var mondayOfW45 = new DateTimeOffset(2026, 11, 2, 0, 0, 0, TimeSpan.Zero);
        var a = await worker.SeedAsync(submittedAt: mondayOfW45);
        var b = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: mondayOfW45.AddDays(6));
        var c = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: NextWednesday);

        await worker.Processor.ProcessAsync(JobOf(a), Ct);
        await worker.Processor.ProcessAsync(JobOf(b), Ct);
        Assert.Equal(10, await GemsAsync(worker, a.PlayerId));  // the same week: nothing more

        await worker.Processor.ProcessAsync(JobOf(c), Ct);

        Assert.Equal(20, await GemsAsync(worker, a.PlayerId));  // a new week: it pays again
        Assert.Equal(["2026-W45", "2026-W46"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks ORDER BY cycle_key"));
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));  // last week's rows are untouched
    }

    [Fact]
    public async Task OnceChallenge_PaysOnlyTheFirstTime()
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutChallengeAsync(Win, 1, 10);
        Completes(worker, ["warrior"], Win);
        var a = await worker.SeedAsync(submittedAt: Wednesday);
        var b = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: NextWednesday.AddDays(60));

        await worker.Processor.ProcessAsync(JobOf(a), Ct);
        await worker.Processor.ProcessAsync(JobOf(b), Ct);

        Assert.Equal(10, await GemsAsync(worker, a.PlayerId));
        Assert.Equal(["once"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=already_marked"));
    }

    [Fact]
    public async Task WeekBoundary_UsesSubmissionTime()  // C8
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Weekly, null);
        Completes(worker, ["warrior"], Win);
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
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Weekly, end);
        Completes(worker, ["warrior"], Win);
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
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Weekly, end);
        Completes(worker, ["warrior"], Win);
        var early = await worker.SeedAsync(submittedAt: end.AddMinutes(-1));

        await worker.Processor.ProcessAsync(JobOf(early), Ct);

        Assert.Equal(10, await GemsAsync(worker, early.PlayerId));
    }

    [Fact]
    public async Task RuleEdit_PaysTheNewAmount_OnlyWhereNothingWasPaid()  // C11
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Weekly, null);
        var first = await worker.SeedAsync(submittedAt: Wednesday);
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        var third = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: NextWednesday);
        Completes(worker, ["warrior"], Win);
        await worker.Processor.ProcessAsync(JobOf(first), Ct);

        await worker.PutChallengeAsync(Win, 2, 99, RewardCycles.Weekly, null);  // retuned
        await worker.Processor.ProcessAsync(JobOf(second), Ct);                  // same week: the mark is held, nothing repaid
        Assert.Equal(10, await GemsAsync(worker, first.PlayerId));
        await worker.Processor.ProcessAsync(JobOf(third), Ct);                   // a new week pays under the new version

        Assert.Equal(109, await GemsAsync(worker, first.PlayerId));
        Assert.Equal(["10:1", "99:2"], await worker.StringsAsync("SELECT delta || ':' || rule_version FROM wallet_ledger ORDER BY id"));
    }

    [Fact]
    public async Task CycleSwitch_UsesTheNewKey_AndSwitchingBackReusesTheOldMark()  // C11
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Once, null);
        var a = await worker.SeedAsync(submittedAt: Wednesday);
        var b = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        var c = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(2));
        Completes(worker, ["warrior"], Win);
        await worker.Processor.ProcessAsync(JobOf(a), Ct);

        await worker.PutChallengeAsync(Win, 2, 10, RewardCycles.Weekly, null);  // once -> weekly: the weekly key is new
        await worker.Processor.ProcessAsync(JobOf(b), Ct);
        Assert.Equal(20, await GemsAsync(worker, a.PlayerId));

        await worker.PutChallengeAsync(Win, 3, 10, RewardCycles.Once, null);    // and back: the once mark still exists
        await worker.Processor.ProcessAsync(JobOf(c), Ct);

        Assert.Equal(20, await GemsAsync(worker, a.PlayerId));
        Assert.Equal(["2026-W45", "once"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks ORDER BY cycle_key"));
    }

    [Fact]
    public async Task ConcurrentBattles_NeverPayTheSameChallengeTwice()  // C13
    {
        await using var worker = await CreateAsync(stack);
        await PutStarsAsync(worker);
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
                new BattleFacts("enc.trial", [], ["warrior"], [new CompletionFact(Win), new CompletionFact(Flawless)]));
        };

        await Task.WhenAll(worker.Processor.ProcessAsync(JobOf(a), Ct), worker.Processor.ProcessAsync(JobOf(b), Ct));

        Assert.Equal(15, await GemsAsync(worker, a.PlayerId));  // each challenge once, not twice
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM outbox WHERE type = 'RewardGranted'"));
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
    }

    [Fact]
    public async Task DuplicateFacts_AreMerged_AndABossAndACompletionAreSeparateChallenges()  // C14
    {
        await using var worker = await CreateAsync(stack);
        await PutStarsAsync(worker);
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request),
            new BattleFacts("enc.trial", ["boss.lich", "boss.lich"], ["warrior", "warrior"],
                [new CompletionFact(Win), new CompletionFact(Win), new CompletionFact(Fast)])));
        var battle = await worker.SeedAsync(submittedAt: Wednesday);

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(5 + 5 + 10, await GemsAsync(worker, battle.PlayerId));  // win and fast once each, plus the boss's own 10
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(3L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));  // one per challenge, one character
    }

    [Fact]
    public async Task ACompletionWithNoRuleOrARetiredOne_PaysNothing_AndALaterRulePaysTheNextWin()  // C16
    {
        await using var worker = await CreateAsync(stack);
        Completes(worker, ["warrior"], "event.unruled", "event.retired");
        await worker.PutChallengeAsync("event.retired", 1, 0);
        var first = await worker.SeedAsync(submittedAt: Wednesday);
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));

        await worker.Processor.ProcessAsync(JobOf(first), Ct);

        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM completion_marks"));
        Assert.Equal(1, worker.Metrics.Count("rpg.reward_rule_lookups", "result=missing"));
        Assert.Equal(1, worker.Metrics.Count("rpg.reward_rule_lookups", "result=retired"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=no_rule"));

        await worker.PutChallengeAsync("event.unruled", 1, 7);
        await worker.Processor.ProcessAsync(JobOf(second), Ct);

        Assert.Equal(7, await GemsAsync(worker, first.PlayerId));
    }

    [Fact]
    public async Task PartyCharacters_EachHaveTheirOwnMark()
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Weekly, null);
        var a = await worker.SeedAsync(submittedAt: Wednesday);
        var b = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        worker.Runner.Handler = (request, _) =>
        {
            var id = FakeReplayRunner.BattleIdOf(request);
            return Task.FromResult(FakeReplayRunner.Verified(id, id == a.BattleId
                ? new BattleFacts("enc", [], ["warrior"], [new CompletionFact(Win)])
                : new BattleFacts("enc", [], ["warrior", "cleric"], [new CompletionFact(Win)])));
        };

        await worker.Processor.ProcessAsync(JobOf(a), Ct);
        await worker.Processor.ProcessAsync(JobOf(b), Ct);

        Assert.Equal(20, await GemsAsync(worker, a.PlayerId));  // the warrior once, the cleric on the second battle
        Assert.Equal(["cleric", "warrior"], await worker.StringsAsync("SELECT character_id FROM completion_marks ORDER BY 1"));
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
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Once, null);
        Completes(worker, ["warrior"], Win);
        var a = await worker.SeedAsync(submittedAt: Wednesday);
        var b = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        var c = await worker.SeedAsync(player: a.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(2));
        await worker.Processor.ProcessAsync(JobOf(a), Ct);
        await worker.Processor.ProcessAsync(JobOf(b), Ct);
        Assert.Equal(10, await GemsAsync(worker, a.PlayerId));

        await ResetAsync(worker, Win);
        await worker.Processor.ProcessAsync(JobOf(c), Ct);

        Assert.Equal(20, await GemsAsync(worker, a.PlayerId));
        Assert.Equal(["once", "once.r1"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks ORDER BY cycle_key"));  // the old mark stays
        Assert.Equal(2L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
    }

    [Fact]
    public async Task BattleSettledAfterAReset_UsesTheNewGeneration()  // C21
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Weekly, null);
        Completes(worker, ["warrior"], Win);
        var played = await worker.SeedAsync(submittedAt: Wednesday);  // played before the reset, settled after it
        await ResetAsync(worker, Win);

        await worker.Processor.ProcessAsync(JobOf(played), Ct);

        Assert.Equal(["2026-W45.r1"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks"));
    }

    [Fact]
    public async Task PlayerReset_AffectsOnlyThatPlayer()  // C24
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Once, null);
        Completes(worker, ["warrior"], Win);
        var alice1 = await worker.SeedAsync(submittedAt: Wednesday);
        var bob1 = await worker.SeedAsync(submittedAt: Wednesday);
        var alice2 = await worker.SeedAsync(player: alice1.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        var bob2 = await worker.SeedAsync(player: bob1.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        foreach (var battle in new[] { alice1, bob1 })
        {
            await worker.Processor.ProcessAsync(JobOf(battle), Ct);
        }

        await ResetAsync(worker, Win, alice1.PlayerId);
        await worker.Processor.ProcessAsync(JobOf(alice2), Ct);
        await worker.Processor.ProcessAsync(JobOf(bob2), Ct);

        Assert.Equal(20, await GemsAsync(worker, alice1.PlayerId));  // paid again
        Assert.Equal(10, await GemsAsync(worker, bob1.PlayerId));    // keeps their mark
        Assert.Equal(["once", "once.p1"], await worker.StringsAsync(
            "SELECT cycle_key FROM completion_marks WHERE player_id = $1 ORDER BY cycle_key", alice1.PlayerId));
        Assert.Equal(["once"], await worker.StringsAsync("SELECT cycle_key FROM completion_marks WHERE player_id = $1", bob1.PlayerId));
    }

    [Fact]
    public async Task PlayerAndGlobalReset_Stack()  // C24
    {
        await using var worker = await CreateAsync(stack);
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Weekly, null);
        Completes(worker, ["warrior"], Win);
        var first = await worker.SeedAsync(submittedAt: Wednesday);
        var second = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(1));
        var third = await worker.SeedAsync(player: first.PlayerId, runStatus: "Won", submittedAt: Wednesday.AddHours(2));
        await worker.Processor.ProcessAsync(JobOf(first), Ct);
        await ResetAsync(worker, Win, first.PlayerId);
        await worker.Processor.ProcessAsync(JobOf(second), Ct);

        await ResetAsync(worker, Win);  // and now everyone, too
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
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Weekly, null);
        await worker.PutChallengeAsync("event.short", 1, 50, RewardCycles.Weekly, Wednesday.AddDays(3));
        Completes(worker, ["warrior"], Win, "event.short");
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
        await worker.PutChallengeAsync(Win, 1, 10, RewardCycles.Weekly, null);
        Completes(worker, ["warrior"], Win);
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
        await worker.PutChallengeAsync("boss/" + tooLong[..195], 1, 99);
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request),
            new BattleFacts("enc", ["has:colon", tooLong, "has space"], ["warrior"])));
        var battle = await worker.SeedAsync();

        var decision = await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal("verified", decision.Result);
        Assert.Equal(0L, await worker.ScalarAsync<long>("SELECT count(*) FROM wallet_ledger"));
        Assert.Equal(1, worker.Metrics.Count("rpg.settlements", "result=bad_id"));
    }

    [Fact]
    public async Task ABossClear_IsBossSlashId_AndTheEventKeepsTheBossId()
    {
        await using var worker = await CreateAsync(stack);
        worker.Runner.Handler = (request, _) => Task.FromResult(FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request),
            new BattleFacts("enc.boss", ["boss.lich"], ["warrior"])));
        var battle = await worker.SeedAsync();

        await worker.Processor.ProcessAsync(JobOf(battle), Ct);

        Assert.Equal(["boss/boss.lich:once"], await worker.StringsAsync("SELECT challenge_id || ':' || cycle_key FROM completion_marks"));
        var grant = Assert.Single(await GrantsAsync(worker));
        Assert.Equal(("boss.lich", "boss/boss.lich", "once"), (grant.Payload.BossId, grant.Payload.ChallengeId, grant.Payload.CycleKey));
    }
}
