using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using Rpg.Contracts.Cards;
using Rpg.Economy.Cards;
using Rpg.GameServerApi.Tests.Infrastructure;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// The card fixtures of the server tests (spec card-collection 6): a small catalog with a core set and one expansion, every
/// rarity, and the seed economy of spec 3.4b. Never the demo's content: the tests do not depend on the user's design.
/// </summary>
public static class CardFixtures
{
    public const string Core = "core";
    public const string Descent = "descent";
    public const string StarterPack = "descent-pack";

    private static CatalogFileCard Character(string id, string set, bool core) =>
        new(id, CardKinds.Character, CardRarities.Mythic, set, core, []);

    private static CatalogFileCard Item(string id, string rarity, string set, bool core, params string[] pools) =>
        new(id, CardKinds.Item, rarity, set, core, pools);

    /// <summary>Three core characters, two collectible Mythics, three core items, eleven collectible items.</summary>
    public static CardCatalogFile Catalog(string hash = "fixture-1") => new(hash,
    [
        Character("hero.a", Core, true), Character("hero.b", Core, true), Character("hero.c", Core, true),
        Character("hero.m1", Descent, false), Character("hero.m2", Descent, false),
        Item("item.core1", CardRarities.Common, Core, true, "Pool.Treasure", "Pool.Shop"),
        Item("item.core2", CardRarities.Rare, Core, true, "Pool.Treasure"),
        Item("item.food", CardRarities.Common, Core, true, "Pool.Food"),
        Item("item.k1", CardRarities.Common, Descent, false, "Pool.Treasure"),
        Item("item.k2", CardRarities.Common, Descent, false, "Pool.Treasure"),
        Item("item.k3", CardRarities.Common, Descent, false, "Pool.Shop"),
        Item("item.r1", CardRarities.Rare, Descent, false, "Pool.Treasure"),
        Item("item.r2", CardRarities.Rare, Descent, false, "Pool.Shop"),
        Item("item.e1", CardRarities.Epic, Descent, false, "Pool.Treasure"),
        Item("item.l1", CardRarities.Legendary, Descent, false, "Pool.Cache"),
        Item("item.l2", CardRarities.Legendary, Descent, false, "Pool.Treasure"),
    ]);

    public static readonly string[] CoreItems = ["item.core1", "item.core2", "item.food"];

    public static readonly string[] CoreCharacters = ["hero.a", "hero.b", "hero.c"];

    /// <summary>The seed numbers of spec 3.4b.</summary>
    public static CardEconomySeed Economy() => new(
    [
        new CardRateRequest(CardRarities.Common, 5, 40), new CardRateRequest(CardRarities.Rare, 20, 100),
        new CardRateRequest(CardRarities.Epic, 100, 400), new CardRateRequest(CardRarities.Legendary, 400, 1600),
        new CardRateRequest(CardRarities.Mythic, 800, 3200),
    ],
    [
        Pack(StarterPack, 100, 5,
            new Dictionary<string, int>
            {
                [CardRarities.Common] = 7210, [CardRarities.Rare] = 2200, [CardRarities.Epic] = 450, [CardRarities.Legendary] = 100,
                [CardRarities.Mythic] = 40,
            },
            pity: new Dictionary<string, int> { [CardRarities.Epic] = 10, [CardRarities.Legendary] = 20, [CardRarities.Mythic] = 30 },
            first: new Dictionary<string, int> { [CardRarities.Epic] = 5, [CardRarities.Legendary] = 10, [CardRarities.Mythic] = 15 },
            min: CardRarities.Rare),
    ]);

    public static PackTypeRequest Pack(string id, int price, int count, Dictionary<string, int> odds,
        Dictionary<string, int>? pity = null, Dictionary<string, int>? first = null, string? min = null, bool retired = false,
        string set = Descent) =>
        new(id, id, price, count, odds, [set], retired, pity ?? new Dictionary<string, int>(), first ?? new Dictionary<string, int>(), min);

    /// <summary>Common cards only: three distinct cards, so duplicates are certain in a large pack.</summary>
    public static PackTypeRequest CommonsOnly(string id, int price = 10, int count = 5) =>
        Pack(id, price, count, new Dictionary<string, int> { [CardRarities.Common] = 10_000 });

    public static async Task SeedAsync(ApiFactory factory, CardCatalogFile? catalog = null)
    {
        var store = factory.Services.GetRequiredService<CardStore>();
        var ct = TestContext.Current.CancellationToken;
        await factory.Services.GetRequiredService<Rpg.GameServerApi.Migrations.MigrationRunner>().EnsureMigratedAsync(ct);
        await store.SeedCatalogAsync(catalog ?? Catalog(), DateTimeOffset.UtcNow, ct);
        await store.SeedEconomyAsync(Economy(), 100_000, 100_000, DateTimeOffset.UtcNow, ct);
    }

    /// <summary>Sets a player's gems and dust straight in the table (the wallet's own writers are other slices).</summary>
    public static async Task GrantAsync(ApiFactory factory, string playerId, int gems = 0, int dust = 0)
    {
        var source = factory.Services.GetRequiredService<NpgsqlDataSource>();
        var ct = TestContext.Current.CancellationToken;
        await using (var player = source.CreateCommand(
            $"INSERT INTO players (player_id, display_name, created_at) VALUES ('{playerId}', 'p-{playerId[..8]}', now()) ON CONFLICT DO NOTHING"))
        {
            await player.ExecuteNonQueryAsync(ct);
        }

        await using var wallet = source.CreateCommand(
            $"INSERT INTO wallets (player_id, gems, dust) VALUES ('{playerId}', {gems}, {dust}) ON CONFLICT (player_id) DO UPDATE SET gems = {gems}, dust = {dust}");
        await wallet.ExecuteNonQueryAsync(ct);
    }

    /// <summary>Gives a player a card directly (acquired now), as a pack would.</summary>
    public static async Task OwnAsync(ApiFactory factory, string playerId, string cardId, DateTimeOffset? at = null)
    {
        var source = factory.Services.GetRequiredService<NpgsqlDataSource>();
        var ct = TestContext.Current.CancellationToken;
        await using var command = source.CreateCommand(
            $"""
            INSERT INTO players (player_id, display_name, created_at) VALUES ('{playerId}', 'p-{playerId[..8]}', now()) ON CONFLICT DO NOTHING;
            INSERT INTO card_holdings (player_id, card_id, acquired_at, source) VALUES ('{playerId}', '{cardId}', '{(at ?? DateTimeOffset.UtcNow):O}', 'pack');
            INSERT INTO card_ledger (player_id, card_id, delta, reason, idempotency_key) VALUES ('{playerId}', '{cardId}', 1, 'pack', 'own:{playerId}:{cardId}');
            """);
        await command.ExecuteNonQueryAsync(ct);
    }
}
