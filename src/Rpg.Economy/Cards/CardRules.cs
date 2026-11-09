using Rpg.Contracts.Cards;

namespace Rpg.Economy.Cards;

public enum CardFailure
{
    RuleInvalid, InsufficientCurrency, CardLockedByRun, CardNotCollectible, CardAlreadyOwned, CardNotOwned, RequestKeyReused,
    PackUnavailable, CharacterLocked, RunVerifying,
}

/// <summary>Why an account action or a rule write is refused; the API maps <see cref="Failure"/> to a code and a status.</summary>
public sealed record CardProblem(CardFailure Failure, string Detail, string? RunId = null, string? RunStatus = null);

/// <summary>An account action's outcome: a value, or a problem. <see cref="Replayed"/>: the stored answer of an earlier identical request.</summary>
public sealed record CardResult<T>(T? Value, CardProblem? Problem, bool Replayed = false) where T : class
{
    public static CardResult<T> Ok(T value, bool replayed = false) => new(value, null, replayed);

    public static CardResult<T> Fail(CardFailure failure, string detail, string? runId = null, string? runStatus = null) =>
        new(null, new CardProblem(failure, detail, runId, runStatus));
}

/// <summary>One version of a rarity's rates (spec card-collection 3.2).</summary>
public sealed record CardRate(string Rarity, int DustValue, int CraftCost, int Version, DateTimeOffset EffectiveFrom, string CreatedBy)
{
    public CardRateResponse ToResponse() => new(Rarity, DustValue, CraftCost, Version, EffectiveFrom, CreatedBy);
}

/// <summary>One version of a pack type.</summary>
public sealed record PackType(string PackId, string Name, int Version, int PriceGems, int CardCount,
    IReadOnlyDictionary<string, int> Odds, IReadOnlyList<string> SetIds, bool Retired, IReadOnlyDictionary<string, int> Pity,
    IReadOnlyDictionary<string, int> FirstGuarantees, string? MinRarity, DateTimeOffset EffectiveFrom, string CreatedBy)
{
    public PackConfig Config => new(CardCount, Odds, MinRarity, Pity);

    public PackTypeResponse ToResponse() => new(PackId, Name, Version, PriceGems, CardCount, Odds, SetIds, Retired, Pity,
        FirstGuarantees, MinRarity, EffectiveFrom, CreatedBy);
}

/// <summary>Request validation for the admin writes (spec card-collection 2.7). Null = fine.</summary>
public static class CardRules
{
    public const int MaxCardCount = 20;
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

        if (request.CardCount is < 1 or > MaxCardCount)
        {
            return $"cardCount takes 1–{MaxCardCount}.";
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
