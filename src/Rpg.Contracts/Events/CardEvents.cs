using Rpg.Contracts.Cards;

namespace Rpg.Contracts.Events;

// Spec card-collection 3.1. Economy topic (EventTopics.Economy); the account events are keyed by the player id, the rule
// events by "rule:pack:{id}" / "rule:rate:{rarity}".

public sealed record PackOpenedPayload(string OpeningId, string PlayerId, string PackId, int PackVersion, int GemsSpent,
    IReadOnlyList<PackCardDto> Cards, int DustGained, int NewCards, string DrawSeed, int CatalogVersion, int PityTriggers);

public sealed record CardDustedPayload(string PlayerId, string CardId, string Rarity, int DustGained, int RateVersion);

public sealed record CardCraftedPayload(string PlayerId, string CardId, string Rarity, int DustSpent, int RateVersion);

public sealed record PackTypeChangedPayload(string PackId, int Version, int PriceGems, bool Retired, string ChangedBy);

public sealed record CardRatesChangedPayload(string Rarity, int DustValue, int CraftCost, int Version, string ChangedBy);
