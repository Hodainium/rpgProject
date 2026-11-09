using Rpg.Contracts.Cards;
using Rpg.Economy.Cards;

namespace Rpg.GameServerApi.Tests;

/// <summary>Spec card-collection 3.4, 3.4a, 3.4b, 6: the pack RNG, the pity timers and the Rare guarantee (pure, no stack).</summary>
public class PackDrawerTests
{
    private static readonly IReadOnlyDictionary<string, IReadOnlyList<string>> Eligible = new Dictionary<string, IReadOnlyList<string>>
    {
        [CardRarities.Common] = ["c1", "c2", "c3", "c4", "c5"],
        [CardRarities.Rare] = ["r1", "r2", "r3"],
        [CardRarities.Epic] = ["e1", "e2"],
        [CardRarities.Legendary] = ["l1", "l2"],
        [CardRarities.Mythic] = ["m1", "m2", "m3"],
    };

    /// <summary>Spec 3.4b: the seed odds, per 10000 per card.</summary>
    private static readonly IReadOnlyDictionary<string, int> SeedOdds = new Dictionary<string, int>
    {
        [CardRarities.Common] = 7210, [CardRarities.Rare] = 2200, [CardRarities.Epic] = 450, [CardRarities.Legendary] = 100,
        [CardRarities.Mythic] = 40,
    };

    private static readonly IReadOnlyDictionary<string, int> SeedPity = new Dictionary<string, int>
    {
        [CardRarities.Epic] = 10, [CardRarities.Legendary] = 20, [CardRarities.Mythic] = 30,
    };

    private static readonly IReadOnlyDictionary<string, int> NoCounters = new Dictionary<string, int>();

    private static PackConfig Seed(string? min = CardRarities.Rare, IReadOnlyDictionary<string, int>? pity = null) =>
        new(5, SeedOdds, min, pity ?? SeedPity);

    [Fact]
    public void SplitMix64_SeedZero_GivesTheReferenceSequence()
    {
        var rng = new SplitMix64(0);

        Assert.Equal(0xE220A8397B1DCDAFUL, rng.Next());
        Assert.Equal(0x6E789E6AA1B965F4UL, rng.Next());
        Assert.Equal(0x06C45D188009454FUL, rng.Next());
    }

    [Fact]
    public void Draw_IsAPureFunction_OfSeedConfigPoolAndCounters()
    {
        var first = PackDrawer.Draw(123456789, Seed(), Eligible, NoCounters);
        var second = PackDrawer.Draw(123456789, Seed(), Eligible, NoCounters);

        Assert.Equal(first.Cards, second.Cards);
        Assert.Equal(first.MissedAfter, second.MissedAfter);
        Assert.NotEqual(first.Cards, PackDrawer.Draw(123456790, Seed(), Eligible, NoCounters).Cards);
    }

    [Fact]
    public void Draw_GoldenVector_SeedOne_IsPinned()
    {
        // Pins the draw algorithm (walk order, modulo, card pick) so a refactor cannot change stored openings' meaning.
        var result = PackDrawer.Draw(1, Seed(), Eligible, NoCounters);

        Assert.Equal(5, result.Cards.Count);
        Assert.All(result.Cards, c => Assert.Contains(c.CardId, Eligible[c.Rarity]));
        Assert.Equal(GoldenSeedOne, string.Join(",", result.Cards.Select(c => c.CardId)));
    }

    private const string GoldenSeedOne = "c5,c1,r3,c4,c1";

    [Fact]
    public void Pity_TheNthPackSinceTheLastDropHoldsThatRarity_ForcedIntoTheLowestSlot()
    {
        var config = new PackConfig(3, new Dictionary<string, int> { [CardRarities.Common] = 10_000 }, null,
            new Dictionary<string, int> { [CardRarities.Legendary] = 3 });

        var early = PackDrawer.Draw(7, config, Eligible, new Dictionary<string, int> { [CardRarities.Legendary] = 1 });
        var due = PackDrawer.Draw(7, config, Eligible, new Dictionary<string, int> { [CardRarities.Legendary] = 2 });

        Assert.DoesNotContain(early.Cards, c => c.Pity);
        Assert.Equal(2, early.MissedAfter[CardRarities.Legendary]);
        var forced = Assert.Single(due.Cards, c => c.Pity);
        Assert.Equal(CardRarities.Legendary, forced.Rarity);
        Assert.Equal(0, due.MissedAfter[CardRarities.Legendary]);
    }

    [Fact]
    public void Pity_ANaturalDrop_ResetsTheCounter_AndForcesNothing()
    {
        var config = new PackConfig(5, new Dictionary<string, int> { [CardRarities.Legendary] = 10_000 }, null,
            new Dictionary<string, int> { [CardRarities.Legendary] = 3 });

        var result = PackDrawer.Draw(7, config, Eligible, new Dictionary<string, int> { [CardRarities.Legendary] = 2 });

        Assert.DoesNotContain(result.Cards, c => c.Pity);
        Assert.Equal(0, result.MissedAfter[CardRarities.Legendary]);
    }

    [Fact]
    public void Pity_TwoGuaranteesInOnePack_TakeDistinctSlots_AndNeitherUndoesTheOther()
    {
        var config = new PackConfig(3, new Dictionary<string, int> { [CardRarities.Common] = 10_000 }, null,
            new Dictionary<string, int> { [CardRarities.Legendary] = 1, [CardRarities.Mythic] = 1 });

        var result = PackDrawer.Draw(99, config, Eligible, NoCounters);

        Assert.Single(result.Cards, c => c.Rarity == CardRarities.Mythic && c.Pity);
        Assert.Single(result.Cards, c => c.Rarity == CardRarities.Legendary && c.Pity);
        Assert.Equal(1, result.Cards.Count(c => c.Rarity == CardRarities.Common));
        Assert.All(result.MissedAfter.Values, v => Assert.Equal(0, v));
    }

    [Fact]
    public void Pity_NeverReplacesTheOnlyHolderOfAnotherTrackedRarity()
    {
        // One slot is a natural Epic (tracked, the only one); a Legendary guarantee must take a Common slot instead.
        var config = new PackConfig(3, new Dictionary<string, int> { [CardRarities.Epic] = 5000, [CardRarities.Common] = 5000 }, null,
            new Dictionary<string, int> { [CardRarities.Legendary] = 1, [CardRarities.Epic] = 50 });
        for (long seed = 0; seed < 300; seed++)
        {
            var natural = PackDrawer.Draw(seed, config with { Pity = new Dictionary<string, int>() }, Eligible, NoCounters);
            var result = PackDrawer.Draw(seed, config, Eligible, NoCounters);
            if (natural.Cards.Count(c => c.Rarity == CardRarities.Epic) == 1 && natural.Cards.Any(c => c.Rarity == CardRarities.Common))
            {
                Assert.Equal(1, result.Cards.Count(c => c.Rarity == CardRarities.Epic));
                Assert.Single(result.Cards, c => c.Rarity == CardRarities.Legendary);
            }
        }
    }

    [Fact]
    public void InitialMissed_StartsEachGuaranteedRarityAt_PityMinusWithin()
    {
        var initial = PackDrawer.InitialMissed(SeedPity,
            new Dictionary<string, int> { [CardRarities.Epic] = 5, [CardRarities.Legendary] = 10, [CardRarities.Mythic] = 15 });

        Assert.Equal(5, initial[CardRarities.Epic]);
        Assert.Equal(10, initial[CardRarities.Legendary]);
        Assert.Equal(15, initial[CardRarities.Mythic]);
        Assert.Equal(0, PackDrawer.InitialMissed(SeedPity, new Dictionary<string, int>())[CardRarities.Mythic]);
    }

    [Fact]
    public void FirstGuarantee_LandsWithinTheFirstNPacks_OnEverySeed()
    {
        var first = new Dictionary<string, int> { [CardRarities.Legendary] = 10 };
        for (long seed = 0; seed < 50; seed++)
        {
            var missed = PackDrawer.InitialMissed(SeedPity, first).ToDictionary(kv => kv.Key, kv => kv.Value);
            var packs = 0;
            var rng = new SplitMix64(seed);
            while (packs < 10)
            {
                var result = PackDrawer.Draw(unchecked((long)rng.Next()), Seed(), Eligible, missed);
                missed = result.MissedAfter.ToDictionary(kv => kv.Key, kv => kv.Value);
                packs++;
                if (result.Cards.Any(c => c.Rarity == CardRarities.Legendary))
                {
                    break;
                }
            }

            Assert.True(missed[CardRarities.Legendary] == 0, $"seed {seed}: no Legendary within 10 packs");
        }
    }

    [Fact]
    public void Pity_TheTimerNeverLetsMoreThanNMinusOnePacksPassWithoutTheRarity()
    {
        var rng = new SplitMix64(2026);
        var missed = new Dictionary<string, int>();
        var worst = 0;
        for (var pack = 0; pack < 5_000; pack++)
        {
            var result = PackDrawer.Draw(unchecked((long)rng.Next()), Seed(), Eligible, missed);
            missed = result.MissedAfter.ToDictionary(kv => kv.Key, kv => kv.Value);
            worst = Math.Max(worst, missed[CardRarities.Legendary]);
            Assert.True(missed[CardRarities.Legendary] <= 19);
            Assert.True(missed[CardRarities.Mythic] <= 29);
            Assert.True(missed[CardRarities.Epic] <= 9);
        }

        Assert.True(worst > 0);
    }

    [Fact]
    public void RareGuarantee_NoPackIsAllCommon_AndItIsDeterministic()
    {
        var odds = new Dictionary<string, int> { [CardRarities.Common] = 9000, [CardRarities.Rare] = 800, [CardRarities.Epic] = 200 };
        var withMin = new PackConfig(5, odds, CardRarities.Rare, new Dictionary<string, int>());
        var without = withMin with { MinRarity = null };
        var sawAllCommonWithout = false;
        for (long seed = 0; seed < 2_000; seed++)
        {
            var result = PackDrawer.Draw(seed, withMin, Eligible, NoCounters);
            Assert.Contains(result.Cards, c => PackDrawer.Rank(c.Rarity) >= PackDrawer.Rank(CardRarities.Rare));
            Assert.Equal(result.Cards, PackDrawer.Draw(seed, withMin, Eligible, NoCounters).Cards);
            sawAllCommonWithout |= PackDrawer.Draw(seed, without, Eligible, NoCounters).Cards.All(c => c.Rarity == CardRarities.Common);
        }

        Assert.True(sawAllCommonWithout);
    }

    [Fact]
    public void RareGuarantee_NeverUndoesAPityWin_ByRedrawingTheOnlyHolderOfATrackedRarity()
    {
        // Rare is tracked and due; Epic is the minimum. A natural pack whose only Rare sits in the last slot must keep it.
        var odds = new Dictionary<string, int> { [CardRarities.Common] = 9500, [CardRarities.Rare] = 500, [CardRarities.Epic] = 100 };
        odds[CardRarities.Common] = 10_000 - 500 - 100;
        var config = new PackConfig(5, odds, CardRarities.Epic, new Dictionary<string, int> { [CardRarities.Rare] = 2 });
        var due = new Dictionary<string, int> { [CardRarities.Rare] = 1 };
        for (long seed = 0; seed < 3_000; seed++)
        {
            var result = PackDrawer.Draw(seed, config, Eligible, due);
            Assert.Contains(result.Cards, c => c.Rarity == CardRarities.Rare);   // the Nth pack always holds the tracked rarity
            Assert.Equal(0, result.MissedAfter[CardRarities.Rare]);
        }
    }

    [Fact]
    public void Pity_AForcedCardIsNeverSilentlyDropped_WhenEverySlotIsATrackedRaritysOnlyCard()
    {
        // Two slots: a natural Epic and a natural Rare, each the only card of a tracked rarity; Legendary is due. The Rare slot gives
        // way (Rare is below Legendary and gets its own check afterwards), so the Legendary guarantee is kept and the Epic stays.
        var odds = new Dictionary<string, int> { [CardRarities.Epic] = 5000, [CardRarities.Rare] = 5000 };
        var config = new PackConfig(2, odds, null, new Dictionary<string, int>
        {
            [CardRarities.Legendary] = 1, [CardRarities.Epic] = 50, [CardRarities.Rare] = 50,
        });
        var seen = 0;
        for (long seed = 0; seed < 500; seed++)
        {
            var natural = PackDrawer.Draw(seed, config with { Pity = new Dictionary<string, int>() }, Eligible, NoCounters);
            if (natural.Cards.Count(c => c.Rarity == CardRarities.Epic) != 1 || natural.Cards.Count(c => c.Rarity == CardRarities.Rare) != 1)
            {
                continue;
            }

            seen++;
            var result = PackDrawer.Draw(seed, config, Eligible, NoCounters);
            Assert.Contains(result.Cards, c => c.Rarity == CardRarities.Legendary && c.Pity);
            Assert.Contains(result.Cards, c => c.Rarity == CardRarities.Epic);
            Assert.Equal(0, result.MissedAfter[CardRarities.Legendary]);
            Assert.Equal(1, result.MissedAfter[CardRarities.Rare]);   // its natural card gave way: the counter keeps counting
        }

        Assert.True(seen > 50);
    }

    [Fact]
    public void CanDraw_NeedsARarityWithBothOddsAndCards()
    {
        Assert.True(PackDrawer.CanDraw(SeedOdds, Eligible));
        Assert.False(PackDrawer.CanDraw(new Dictionary<string, int> { [CardRarities.Legendary] = 10_000 },
            new Dictionary<string, IReadOnlyList<string>> { [CardRarities.Common] = ["c1"] }));
    }

    [Fact]
    public void RareGuarantee_ARareAlreadyThere_LeavesThePackUntouched_AndTheRedrawIsNotPity()
    {
        var odds = new Dictionary<string, int> { [CardRarities.Common] = 9000, [CardRarities.Rare] = 1000 };
        var withMin = new PackConfig(5, odds, CardRarities.Rare, new Dictionary<string, int>());
        var without = withMin with { MinRarity = null };
        for (long seed = 0; seed < 500; seed++)
        {
            var natural = PackDrawer.Draw(seed, without, Eligible, NoCounters);
            var guaranteed = PackDrawer.Draw(seed, withMin, Eligible, NoCounters);
            if (natural.Cards.Any(c => c.Rarity != CardRarities.Common))
            {
                Assert.Equal(natural.Cards, guaranteed.Cards);
            }

            Assert.DoesNotContain(guaranteed.Cards, c => c.Pity);
        }
    }

    [Fact]
    public void Draw_ARarityWithNoEligibleCards_IsRenormalisedAway()
    {
        var eligible = Eligible.Where(kv => kv.Key != CardRarities.Legendary).ToDictionary(kv => kv.Key, kv => kv.Value);
        var config = new PackConfig(20, new Dictionary<string, int> { [CardRarities.Common] = 5000, [CardRarities.Legendary] = 5000 },
            null, new Dictionary<string, int>());

        for (long seed = 0; seed < 100; seed++)
        {
            Assert.All(PackDrawer.Draw(seed, config, eligible, NoCounters).Cards, c => Assert.Equal(CardRarities.Common, c.Rarity));
        }
    }

    [Fact]
    public void Draw_IsIndependentOfWhatThePlayerOwns()
    {
        // The draw has no ownership input at all: duplicates are decided afterwards by the store (spec 3.4a).
        var a = PackDrawer.Draw(5, Seed(), Eligible, NoCounters);
        var b = PackDrawer.Draw(5, Seed(), Eligible, NoCounters);
        Assert.Equal(a.Cards, b.Cards);
    }

    [Fact]
    public void Draw_PerCardOddsAndPerPackChances_MatchTheSeedTable()
    {
        // Spec 3.4b, per-card odds with no guarantee: 72.10 / 22.00 / 4.50 / 1.00 / 0.40 %.
        var plain = Seed(min: null, pity: new Dictionary<string, int>());
        var rng = new SplitMix64(31337);
        var perCard = new Dictionary<string, int>();
        const int packs = 100_000;
        for (var i = 0; i < packs; i++)
        {
            foreach (var card in PackDrawer.Draw(unchecked((long)rng.Next()), plain, Eligible, NoCounters).Cards)
            {
                perCard[card.Rarity] = perCard.GetValueOrDefault(card.Rarity) + 1;
            }
        }

        foreach (var (rarity, odds) in SeedOdds)
        {
            Assert.InRange(perCard[rarity] / (packs * 5.0) * 100, odds / 100.0 - 0.25, odds / 100.0 + 0.25);
        }

        // With the Rare guarantee (and no pity): the chance a pack holds one is 86.5 / 23.7 / 5.6 / 2.26 % (rare..mythic).
        var guaranteed = Seed(pity: new Dictionary<string, int>());
        var holds = new Dictionary<string, int>();
        for (var i = 0; i < packs; i++)
        {
            foreach (var rarity in PackDrawer.Draw(unchecked((long)rng.Next()), guaranteed, Eligible, NoCounters).Cards
                         .Select(c => c.Rarity).Distinct())
            {
                holds[rarity] = holds.GetValueOrDefault(rarity) + 1;
            }
        }

        Assert.InRange(holds[CardRarities.Rare] / (double)packs * 100, 86.5 - 0.6, 86.5 + 0.6);
        Assert.InRange(holds[CardRarities.Epic] / (double)packs * 100, 23.7 - 0.6, 23.7 + 0.6);
        Assert.InRange(holds[CardRarities.Legendary] / (double)packs * 100, 5.6 - 0.4, 5.6 + 0.4);
        Assert.InRange(holds[CardRarities.Mythic] / (double)packs * 100, 2.26 - 0.3, 2.26 + 0.3);
    }
}
