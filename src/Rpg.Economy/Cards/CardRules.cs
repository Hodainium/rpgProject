using Rpg.Contracts.Cards;

namespace Rpg.Economy.Cards;

public enum CardFailure
{
    RuleInvalid, InsufficientCurrency, CardLockedByRun, CardNotCollectible, CardAlreadyOwned, CardNotOwned, RequestKeyReused,
    PackUnavailable, CharacterLocked, RunVerifying,
    NoPackOwned,   // spec pack-shop 2.2
    SessionReplaced, AccountVersionStale,   // spec account-session 2.2
}

/// <summary>
/// Spec account-session 2.2: what an account-changing call carries. Session: the player's account session the client holds;
/// ExpectedAccountVersion: the account version the screen showed, for a player decision (buy, open, dust, craft), null for a
/// call that is fenced but not versioned (refunds, the run start and abandon).
/// </summary>
public sealed record AccountFence(long Session, long? ExpectedAccountVersion);

/// <summary>Why an account action or a rule write is refused; the API maps <see cref="Failure"/> to a code and a status.</summary>
/// <param name="Current">Spec account-session: the player's current session (SessionReplaced) or account version (AccountVersionStale).</param>
public sealed record CardProblem(CardFailure Failure, string Detail, string? RunId = null, string? RunStatus = null, long? Current = null);

/// <summary>An account action's outcome: a value, or a problem. <see cref="Replayed"/>: the stored answer of an earlier identical request.</summary>
public sealed record CardResult<T>(T? Value, CardProblem? Problem, bool Replayed = false) where T : class
{
    public static CardResult<T> Ok(T value, bool replayed = false) => new(value, null, replayed);

    public static CardResult<T> Fail(CardFailure failure, string detail, string? runId = null, string? runStatus = null) =>
        new(null, new CardProblem(failure, detail, runId, runStatus));

    public static CardResult<T> Fail(CardProblem problem) => new(null, problem);
}

/// <summary>One version of a rarity's rates (spec card-collection 3.2).</summary>
public sealed record CardRate(string Rarity, int DustValue, int CraftCost, int Version, DateTimeOffset EffectiveFrom, string CreatedBy)
{
    public CardRateResponse ToResponse() => new(Rarity, DustValue, CraftCost, Version, EffectiveFrom, CreatedBy);
}

/// <summary>One version of a pack type.</summary>
public sealed record PackType(string PackId, string Name, int Version, int PriceGems, int CardCount,
    IReadOnlyDictionary<string, int> Odds, IReadOnlyList<string> SetIds, bool Retired, IReadOnlyDictionary<string, int> Pity,
    IReadOnlyDictionary<string, int> FirstGuarantees, string? MinRarity, DateTimeOffset EffectiveFrom, string CreatedBy,
    bool RefundUnopened = false)
{
    public PackConfig Config => new(CardCount, Odds, MinRarity, Pity);

    /// <summary>Spec pack-shop 2.5: retired with a refund, so its unopened packs are paid back and none of them opens.</summary>
    public bool Refunding => IsRefunding(Retired, RefundUnopened);

    /// <summary>The one definition of "this version refunds" (the save and the store both use it).</summary>
    public static bool IsRefunding(bool retired, bool? refundUnopened) => retired && refundUnopened == true;

    public PackTypeResponse ToResponse() => new(PackId, Name, Version, PriceGems, CardCount, Odds, SetIds, Retired, Pity,
        FirstGuarantees, MinRarity, EffectiveFrom, CreatedBy, RefundUnopened ? true : null);
}

/// <summary>Request validation for the admin writes (spec card-collection 2.7). Null = fine.</summary>
public static class CardRules
{
    /// <summary>
    /// The one rule for "can a pack with these settings be opened right now" (spec pack-shop), used when a pack-type version
    /// is saved (retired ones too: owned packs open with the latest version), when a pack is bought and when one is opened.
    /// Two things: some rarity with odds above 0 still has an eligible card (the draw spreads the odds over the rarities that
    /// have cards), and every rarity the pack can give (by its odds, a pity timer or a first-pack guarantee) has a card rate,
    /// the dust a duplicate of it is worth. Null = it can be opened; otherwise why not.
    /// </summary>
    public static string? OpenProblem(IReadOnlyDictionary<string, int> odds, IReadOnlyDictionary<string, int>? pity,
        IReadOnlyDictionary<string, int>? firstGuarantees, IReadOnlyDictionary<string, IReadOnlyList<string>> eligible,
        IReadOnlyDictionary<string, CardRate> rates)
    {
        if (!PackDrawer.CanDraw(odds, eligible))
        {
            return "no rarity with odds above 0 has an eligible card (non-core, not retired) in the pack's sets";
        }

        var reachable = odds.Concat(pity ?? new Dictionary<string, int>()).Concat(firstGuarantees ?? new Dictionary<string, int>())
            .Where(entry => entry.Value > 0).Select(entry => entry.Key);
        return reachable.Order(StringComparer.Ordinal).FirstOrDefault(rarity => !rates.ContainsKey(rarity)) is { } unrated
            ? $"rarity '{unrated}' can come out of the pack but has no card rate (the dust a duplicate is worth): put its rate first"
            : null;
    }

    /// <summary>Every pack holds this many cards (the user, 2026-11-15: "packs will always have 5 cards").</summary>
    public const int CardsPerPack = 5;

    /// <summary>The size bound before the 5-card rule (slice 5), kept for retired versions of older pack types.</summary>
    public const int MaxRetiredCardCount = 20;
    public const int MaxIdLength = 128;

    public static string? ValidateRate(CardRateRequest? request, int maxCost)
    {
        if (request is null || !CardRarities.Order.Contains(request.Rarity))
        {
            return "rarity must be one of: " + string.Join(", ", CardRarities.Order) + ".";
        }

        if (request.DustValue < 1 || request.DustValue > maxCost || request.CraftCost > maxCost)
        {
            return $"dustValue and craftCost take whole numbers up to {maxCost}; dustValue is at least 1.";
        }

        return request.CraftCost <= request.DustValue ? "craftCost must be above dustValue (otherwise dust and craft loop for free)." : null;
    }

    public static string? ValidatePackType(PackTypeRequest? request, int maxPrice)
    {
        if (request is null || string.IsNullOrWhiteSpace(request.PackId) || request.PackId.Length > MaxIdLength
            || request.PackId.Any(c => c is ':' || char.IsWhiteSpace(c)))
        {
            return "packId takes 1–128 characters with no ':' and no whitespace.";
        }

        if (string.IsNullOrWhiteSpace(request.Name) || request.Name.Length > MaxIdLength)
        {
            return "name takes 1–128 characters.";
        }

        if (request.PriceGems < 1 || request.PriceGems > maxPrice)
        {
            return $"priceGems takes 1–{maxPrice}.";
        }

        // A retired version never sells, so an old pack type saved with another size can still be retired (or refunded) as it is,
        // within the old bound (owned packs of a retired type still open with it).
        if (request.Retired ? request.CardCount is < 1 or > MaxRetiredCardCount : request.CardCount != CardsPerPack)
        {
            return request.Retired
                ? $"cardCount takes 1–{MaxRetiredCardCount} on a retired version."
                : $"cardCount must be {CardsPerPack}: every pack holds {CardsPerPack} cards.";
        }

        if (request.RefundUnopened == true && !request.Retired)
        {
            return "refundUnopened needs retired: a refund is how a pack type is retired when its packs cannot be kept.";
        }

        if (request.OddsPer10000 is null || request.OddsPer10000.Keys.Any(k => !CardRarities.Order.Contains(k))
            || request.OddsPer10000.Values.Any(v => v < 0) || request.OddsPer10000.Values.Sum() != PackDrawer.OddsTotal)
        {
            return $"oddsPer10000 takes known rarities with whole weights that sum to exactly {PackDrawer.OddsTotal}.";
        }

        if (request.SetIds is not { Count: > 0 } || request.SetIds.Any(string.IsNullOrWhiteSpace))
        {
            return "setIds takes at least one set.";
        }

        var pity = request.PityPacks ?? new Dictionary<string, int>();
        if (pity.Any(p => !CardRarities.Order.Contains(p.Key) || p.Value < 0))
        {
            return "pityPacks takes known rarities with N of 0 or more.";
        }

        var first = request.FirstGuarantees ?? new Dictionary<string, int>();
        if (first.Any(f => !pity.TryGetValue(f.Key, out var n) || n < 1 || f.Value < 1 || f.Value > n))
        {
            return "firstGuarantees needs a pityPacks entry for the rarity and 1 <= within <= pity.";
        }

        if (request.MinRarityPerPack is { } min)
        {
            var rank = PackDrawer.Rank(min);
            if (rank < 0 || !CardRarities.Order.Skip(rank).Any(r => request.OddsPer10000.TryGetValue(r, out var w) && w > 0))
            {
                return "minRarityPerPack must be a known rarity with odds above 0 at or above it.";
            }
        }

        return null;
    }
}
