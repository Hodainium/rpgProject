using Rpg.Contracts.Cards;

namespace Rpg.Economy.Cards;

/// <summary>
/// The pack RNG (spec card-collection 3.4): integer-only SplitMix64, separate from combat RNG. A pure function of its
/// inputs, so any stored opening can be re-derived byte for byte.
/// </summary>
public sealed class SplitMix64(long seed)
{
    private ulong _state = unchecked((ulong)seed);

    public ulong Next()
    {
        unchecked
        {
            _state += 0x9E3779B97F4A7C15UL;
            var z = _state;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            return z ^ (z >> 31);
        }
    }
}

/// <param name="Odds">Rarity to weight per 10000; a missing or 0 rarity only ever comes from pity.</param>
/// <param name="MinRarity">Every pack holds at least one card of this rarity or better (spec 3.4a), or null.</param>
/// <param name="Pity">Rarity to N: the Nth pack since that rarity last dropped holds one. 0 or absent = no timer.</param>
public sealed record PackConfig(int CardCount, IReadOnlyDictionary<string, int> Odds, string? MinRarity,
    IReadOnlyDictionary<string, int> Pity);

public sealed record DrawnCard(string CardId, string Rarity, bool Pity);

/// <param name="MissedAfter">The pity counters after this pack, for every tracked rarity.</param>
public sealed record DrawResult(IReadOnlyList<DrawnCard> Cards, IReadOnlyDictionary<string, int> MissedAfter);

public static class PackDrawer
{
    public const int OddsTotal = 10_000;

    public static int Rank(string rarity) => Array.IndexOf(CardRarities.Order, rarity);

    /// <summary>
    /// A player's first open of a pack type starts each guaranteed rarity at <c>pity - within</c> misses (spec 3.4a).
    /// </summary>
    public static IReadOnlyDictionary<string, int> InitialMissed(IReadOnlyDictionary<string, int> pity,
        IReadOnlyDictionary<string, int> firstGuarantees)
    {
        var missed = new Dictionary<string, int>();
        foreach (var (rarity, n) in pity.Where(p => p.Value > 0))
        {
            missed[rarity] = firstGuarantees.TryGetValue(rarity, out var within) && within > 0 ? Math.Max(0, n - within) : 0;
        }

        return missed;
    }

    /// <param name="eligible">Rarity to the eligible card ids, sorted by id (ordinal): the catalog at the opening's version,
    /// in the pack's sets, not core, not retired.</param>
    /// <param name="missedBefore">The counters the draw starts from (<see cref="InitialMissed"/> for a first open).</param>
    public static DrawResult Draw(long seed, PackConfig config, IReadOnlyDictionary<string, IReadOnlyList<string>> eligible,
        IReadOnlyDictionary<string, int> missedBefore)
    {
        var rng = new SplitMix64(seed);
        var slots = new DrawnCard?[config.CardCount];
        var forced = new bool[config.CardCount];
        int Count(string rarity) => eligible.TryGetValue(rarity, out var ids) ? ids.Count : 0;

        // 1. The natural draw: one rarity walk and one card pick per slot.
        for (var i = 0; i < slots.Length; i++)
        {
            var rarity = PickRarity(rng, config.Odds, eligible, 0);
            slots[i] = new DrawnCard(PickCard(rng, eligible[rarity]), rarity, false);
        }

        var tracked = config.Pity.Where(p => p.Value > 0).Select(p => p.Key)
            .OrderByDescending(Rank).ToList();

        // 2. Pity, highest rarity first: the Nth pack since the last drop holds that rarity.
        foreach (var rarity in tracked)
        {
            var missed = missedBefore.TryGetValue(rarity, out var m) ? m : 0;
            if (missed + 1 < config.Pity[rarity] || slots.Any(s => s!.Rarity == rarity) || Count(rarity) == 0)
            {
                continue;
            }

            // First a slot that is nobody's only card of a tracked rarity; if every slot is, the lowest one whose rarity is
            // below the one being forced (that one's own timer is checked later in this loop). Never silently drop the card.
            var slot = ChooseSlot(slots, forced, tracked, -1);
            if (slot < 0)
            {
                slot = ChooseSlot(slots, forced, tracked, Rank(rarity));
            }

            if (slot < 0)
            {
                continue;
            }

            slots[slot] = new DrawnCard(PickCard(rng, eligible[rarity]), rarity, true);
            forced[slot] = true;
        }

        // 3. The minimum rarity: redraw the last unforced slot among that rarity and above, by the pack's odds.
        if (config.MinRarity is { } min && Rank(min) >= 0 && !slots.Any(s => Rank(s!.Rarity) >= Rank(min)))
        {
            var slot = LastFreeSlot(slots, forced, tracked);
            if (slot < 0)
            {
                slot = Array.FindLastIndex(forced, f => !f);   // the minimum rarity wins over a natural drop of a tracked rarity
            }

            if (slot >= 0 && OddsAtOrAbove(config.Odds, eligible, Rank(min)) > 0)
            {
                var rarity = PickRarity(rng, config.Odds, eligible, Rank(min));
                slots[slot] = new DrawnCard(PickCard(rng, eligible[rarity]), rarity, false);
            }
        }

        var after = new Dictionary<string, int>();
        foreach (var rarity in tracked)
        {
            var missed = missedBefore.TryGetValue(rarity, out var m) ? m : 0;
            after[rarity] = slots.Any(s => s!.Rarity == rarity) ? 0 : missed + 1;
        }

        return new DrawResult([.. slots.Select(s => s!)], after);
    }

    /// <summary>
    /// The slot a forced card replaces: the lowest-rarity unforced slot (ties: the last), but never the only holder of a
    /// tracked rarity, so a guarantee never undoes another one.
    /// </summary>
    private static int ChooseSlot(DrawnCard?[] slots, bool[] forced, List<string> tracked, int protectAbove)
    {
        var best = -1;
        for (var i = 0; i < slots.Length; i++)
        {
            if (forced[i])
            {
                continue;
            }

            var rarity = slots[i]!.Rarity;
            if (tracked.Contains(rarity) && Rank(rarity) > protectAbove && slots.Count(s => s!.Rarity == rarity) == 1)
            {
                continue;
            }

            if (best < 0 || Rank(rarity) <= Rank(slots[best]!.Rarity))
            {
                best = i;
            }
        }

        return best;
    }

    /// <summary>The last unforced slot that is not the only holder of a tracked rarity (the minimum-rarity redraw must not undo a pity win).</summary>
    private static int LastFreeSlot(DrawnCard?[] slots, bool[] forced, List<string> tracked)
    {
        for (var i = slots.Length - 1; i >= 0; i--)
        {
            var rarity = slots[i]!.Rarity;
            if (!forced[i] && !(tracked.Contains(rarity) && slots.Count(s => s!.Rarity == rarity) == 1))
            {
                return i;
            }
        }

        return -1;
    }

    /// <summary>Whether some rarity has both odds above 0 and eligible cards: the pack can be drawn at all.</summary>
    public static bool CanDraw(IReadOnlyDictionary<string, int> odds, IReadOnlyDictionary<string, IReadOnlyList<string>> eligible) =>
        OddsAtOrAbove(odds, eligible, 0) > 0;

    private static int OddsAtOrAbove(IReadOnlyDictionary<string, int> odds, IReadOnlyDictionary<string, IReadOnlyList<string>> eligible,
        int fromRank)
    {
        var total = 0;
        for (var r = fromRank; r < CardRarities.Order.Length; r++)
        {
            var rarity = CardRarities.Order[r];
            if (eligible.TryGetValue(rarity, out var ids) && ids.Count > 0 && odds.TryGetValue(rarity, out var weight))
            {
                total += weight;
            }
        }

        return total;
    }

    /// <summary>One draw over the cumulative odds of the rarities that have eligible cards (renormalised).</summary>
    private static string PickRarity(SplitMix64 rng, IReadOnlyDictionary<string, int> odds,
        IReadOnlyDictionary<string, IReadOnlyList<string>> eligible, int fromRank)
    {
        var total = OddsAtOrAbove(odds, eligible, fromRank);
        if (total <= 0)
        {
            throw new InvalidOperationException("The pack has no rarity with both odds and eligible cards.");
        }

        var x = (long)(rng.Next() % (ulong)total);
        for (var r = fromRank; r < CardRarities.Order.Length; r++)
        {
            var rarity = CardRarities.Order[r];
            if (!eligible.TryGetValue(rarity, out var ids) || ids.Count == 0 || !odds.TryGetValue(rarity, out var weight))
            {
                continue;
            }

            if (x < weight)
            {
                return rarity;
            }

            x -= weight;
        }

        throw new InvalidOperationException("unreachable");
    }

    private static string PickCard(SplitMix64 rng, IReadOnlyList<string> ids) => ids[(int)(rng.Next() % (ulong)ids.Count)];
}
