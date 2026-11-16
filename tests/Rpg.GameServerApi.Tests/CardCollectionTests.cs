using System.Net;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using Rpg.Client;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Auth;
using Rpg.Contracts.Cards;
using Rpg.Contracts.Runs;
using Rpg.Economy.Cards;
using Rpg.GameServerApi.Tests.Infrastructure;
using static Rpg.GameServerApi.Tests.CardFixtures;
using static Rpg.GameServerApi.Tests.RunTests;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Spec card-collection (slice 5): the catalog, pack opening with pity, dust and the run lock, craft, the rules admin, the run's
/// pool, idempotency and the ledger invariants. Real Postgres, Redis and RabbitMQ; the card fixtures, never the demo content.
/// </summary>
[Collection(StackCollection.Name)]
public class CardCollectionTests(StackFixture stack)
{
    private static readonly Dictionary<string, string?> Cards = new()
    {
        ["Cards:Enabled"] = "true",
        ["Outbox:Enabled"] = "false",
        ["Monitors:Interval"] = "01:00:00",
        ["Auth:DevAdmins:0"] = "designer",
    };

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    /// <summary>A player name of this test's own: the wallet cache in the shared Redis is keyed by player.</summary>
    private static string Name([System.Runtime.CompilerServices.CallerMemberName] string test = "") =>
        "c" + Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(System.Text.Encoding.UTF8.GetBytes(test)))[..16];

    private async Task<ApiFactory> FactoryAsync(string? redis = null)
    {
        var factory = await ApiFactory.RunsAsync(stack, redis, settings: Cards);
        await SeedAsync(factory);
        if (redis is null)
        {
            // The catalog caches are keyed by name, and the tests share one Redis: start each test from empty caches.
            await ReadyProbe.WaitUntilAsync(factory.CreateClient(), r => r.StatusOf("redis") == "Healthy");
            await factory.Services.GetRequiredService<Rpg.GameServerApi.Cards.CatalogCache>()
                .InvalidateAsync(Rpg.GameServerApi.Cards.CatalogCache.CardsKey, Rpg.GameServerApi.Cards.CatalogCache.PacksKey);
        }

        return factory;
    }

    private static async Task<(GameServerClient Client, string PlayerId)> PlayerAsync(ApiFactory factory, string name)
    {
        var client = new GameServerClient(factory.CreateClient());
        var token = await client.GetDevTokenAsync(new DevTokenRequest(name), Ct);
        client.AccessToken = token.AccessToken;
        return (client, token.PlayerId);
    }

    private static async Task<GameServerApiException> RefusedAsync(Func<Task> call) =>
        await Assert.ThrowsAsync<GameServerApiException>(call);

    private static async Task AddPackAsync(ApiFactory factory, PackTypeRequest pack)
    {
        var (admin, _) = await PlayerAsync(factory, "designer");
        await admin.PutPackTypeAsync(pack, Ct);
    }

    private static Task<PackOpenResponse> OpenAsync(GameServerClient client, string pack = StarterPack, Guid? key = null) =>
        client.OpenPackAsync(pack, key ?? Guid.NewGuid(), Ct);

    /// <summary>Spec pack-shop 2.1: buys unopened packs (the gems are spent here, not at the open).</summary>
    private static Task<PackBuyResponse> BuyAsync(GameServerClient client, string pack = StarterPack, int count = 1, Guid? key = null) =>
        client.BuyPackAsync(pack, new PackBuyRequest(key ?? Guid.NewGuid(), count), Ct);

    /// <summary>Buys one pack, then opens it: what slice 5's single open did.</summary>
    private static async Task<PackOpenResponse> BuyAndOpenAsync(GameServerClient client, string pack = StarterPack)
    {
        await BuyAsync(client, pack);
        return await OpenAsync(client, pack);
    }

    /// <summary>Spec pack-shop 3.2: the inventory equals the pack ledger's sum per (player, pack), and never goes below 0.</summary>
    private static async Task AssertPackLedgerAsync(ApiFactory factory) =>
        Assert.Equal(0L, await CountAsync(factory,
            """
            SELECT count(*) FROM (
              SELECT player_id, pack_id, sum(delta) AS owned FROM pack_ledger GROUP BY player_id, pack_id) l
            FULL JOIN pack_inventory i USING (player_id, pack_id)
            WHERE COALESCE(l.owned, 0) <> COALESCE(i.count, 0) OR COALESCE(i.count, 0) < 0
            """));

    /// <summary>The holdings equal the card ledger's sum per card, always 0 or 1 (spec 6, ledger invariants).</summary>
    private static async Task AssertCardLedgerAsync(ApiFactory factory)
    {
        var data = factory.Services.GetRequiredService<NpgsqlDataSource>();
        await using var command = data.CreateCommand(
            """
            SELECT count(*) FROM (
              SELECT player_id, card_id, sum(delta) AS owned FROM card_ledger GROUP BY player_id, card_id) l
            FULL JOIN card_holdings h USING (player_id, card_id)
            WHERE COALESCE(l.owned, 0) <> (CASE WHEN h.card_id IS NULL THEN 0 ELSE 1 END)
            """);
        Assert.Equal(0L, await command.ExecuteScalarAsync(Ct));
    }

    /// <summary>Dust in the wallet equals the released dust ledger, for accounts whose dust only came through the ledger.</summary>
    private static async Task AssertDustLedgerAsync(ApiFactory factory)
    {
        var data = factory.Services.GetRequiredService<NpgsqlDataSource>();
        await using var command = data.CreateCommand(
            """
            SELECT count(*) FROM wallets w
            WHERE w.dust <> COALESCE((SELECT sum(delta) FROM wallet_ledger l WHERE l.player_id = w.player_id AND l.currency = 'dust' AND l.status = 'released'), 0)
            """);
        Assert.Equal(0L, await command.ExecuteScalarAsync(Ct));
    }

    private static async Task<long> CountAsync(ApiFactory factory, string sql) => await ScalarAsync(factory, sql);

    // ---- catalog -----------------------------------------------------------------------------------------------------

    [Fact]
    public async Task Catalog_IsServedWithTheRatesInForce_AndReseedingTheSameFileChangesNothing()
    {
        await using var factory = await FactoryAsync();
        var (client, _) = await PlayerAsync(factory, Name());

        var catalog = await client.GetCardCatalogAsync(Ct);
        await SeedAsync(factory);   // the same file again: the same version, no rows added

        Assert.Equal(1, catalog.CatalogVersion);
        Assert.Equal(Catalog().Cards.Count, catalog.Cards.Count);
        var legendary = catalog.Cards.Single(c => c.Id == "item.l1");
        Assert.Equal((400, 1600, false), (legendary.DustValue, legendary.CraftCost, legendary.Core));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM catalog_versions"));
        Assert.Equal(CardRarities.Mythic, catalog.Cards.Single(c => c.Id == "hero.m1").Rarity);
    }

    [Fact]
    public async Task Catalog_AChangedFile_IsANewVersion_AndAMissingCardIsRetired_ButStaysOwned()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await OwnAsync(factory, player, "item.k1");
        var smaller = new CardCatalogFile("fixture-2", [.. Catalog().Cards.Where(c => c.Id != "item.k1")]);

        await SeedAsync(factory, smaller);

        var catalog = await client.GetCardCatalogAsync(Ct);
        Assert.Equal(2, catalog.CatalogVersion);
        Assert.True(catalog.Cards.Single(c => c.Id == "item.k1").Retired);
        Assert.Contains((await client.GetCollectionAsync(Ct)).Owned, c => c.CardId == "item.k1");
        Assert.Equal(2L, await CountAsync(factory, "SELECT count(*) FROM catalog_versions"));
    }

    [Fact]
    public async Task Seeder_ACoreCardThatWouldStopBeingCore_RefusesTheWholeFile()
    {
        await using var factory = await FactoryAsync();
        var demoted = new CardCatalogFile("fixture-bad", [.. Catalog().Cards.Select(c => c.Id == "item.core1" ? c with { Core = false } : c)]);
        var removed = new CardCatalogFile("fixture-bad2", [.. Catalog().Cards.Where(c => c.Id != "hero.a")]);
        var store = factory.Services.GetRequiredService<CardStore>();

        var first = await Assert.ThrowsAsync<CatalogDemotionException>(() => store.SeedCatalogAsync(demoted, DateTimeOffset.UtcNow, Ct));
        await Assert.ThrowsAsync<CatalogDemotionException>(() => store.SeedCatalogAsync(removed, DateTimeOffset.UtcNow, Ct));

        Assert.Contains("item.core1", first.Message);
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM catalog_versions"));
    }

    /// <summary>
    /// Review fix: a reader that read the catalog before an admin's change cannot cache it after the change (the writer bumps
    /// the generation the refill is conditional on); and the keys are per database, so another database's catalog is never served.
    /// </summary>
    [Fact]
    public async Task Catalog_ARefillAfterAWrite_CachesNothing_AndEachDatabaseHasItsOwnKeys()
    {
        await using var factory = await FactoryAsync();
        await using var other = await FactoryAsync();
        var cache = factory.Services.GetRequiredService<Rpg.GameServerApi.Cards.CatalogCache>();
        var otherCache = other.Services.GetRequiredService<Rpg.GameServerApi.Cards.CatalogCache>();
        var stale = new PackListResponse([]);

        var generation = await cache.GenerationAsync();                         // a reader starts, reads the old catalog...
        await cache.InvalidateAsync(Rpg.GameServerApi.Cards.CatalogCache.PacksKey);   // ...an admin's change commits
        await cache.SetAsync(Rpg.GameServerApi.Cards.CatalogCache.PacksKey, stale, generation);

        Assert.Null(await cache.GetAsync<PackListResponse>(Rpg.GameServerApi.Cards.CatalogCache.PacksKey));
        await cache.SetAsync(Rpg.GameServerApi.Cards.CatalogCache.PacksKey, stale, await cache.GenerationAsync());
        Assert.NotNull(await cache.GetAsync<PackListResponse>(Rpg.GameServerApi.Cards.CatalogCache.PacksKey));   // a fresh refill caches
        Assert.Null(await otherCache.GetAsync<PackListResponse>(Rpg.GameServerApi.Cards.CatalogCache.PacksKey));   // not another database's
        Assert.NotEqual(cache.Scoped(Rpg.GameServerApi.Cards.CatalogCache.PacksKey),
            otherCache.Scoped(Rpg.GameServerApi.Cards.CatalogCache.PacksKey));
    }

    [Fact]
    public async Task Catalog_WithRedisUnreachable_StillReadsFromPostgres_AndPacksStillOpen()
    {
        await using var factory = await FactoryAsync("127.0.0.1:1,abortConnect=false,connectTimeout=200");
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);

        var catalog = await client.GetCardCatalogAsync(Ct);
        var opened = await BuyAndOpenAsync(client);

        Assert.Equal(1, catalog.CatalogVersion);
        Assert.Equal(5, opened.Cards.Count);
    }

    [Fact]
    public async Task Packs_ListTheirOddsPityRulesAndEligibleCards_NeverCoreOnes()
    {
        await using var factory = await FactoryAsync();
        var (client, _) = await PlayerAsync(factory, Name());

        var pack = Assert.Single((await client.GetPacksAsync(Ct)).Packs);

        Assert.Equal((StarterPack, 100, 5), (pack.PackId, pack.PriceGems, pack.CardCount));
        Assert.Equal(20, pack.PityPacks[CardRarities.Legendary]);
        Assert.Equal(15, pack.FirstGuarantees[CardRarities.Mythic]);
        Assert.Equal(CardRarities.Rare, pack.MinRarityPerPack);
        Assert.DoesNotContain(pack.CardIds, id => id.StartsWith("hero.") && CoreCharacters.Contains(id) || CoreItems.Contains(id));
        Assert.Contains("hero.m1", pack.CardIds);
    }

    // ---- opening packs -----------------------------------------------------------------------------------------------

    [Fact]
    public async Task OpenPack_SpendsAnOwnedPack_GrantsNewCards_AndWritesEveryLedger()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 250);

        var bought = await BuyAsync(client);
        var opened = await OpenAsync(client);

        Assert.Equal((100, 150, 1), (bought.GemsSpent, bought.Gems, bought.Owned));
        Assert.Equal(5, opened.Cards.Count);
        Assert.Equal((0, 150, 0), (opened.GemsSpent, opened.Gems, opened.PacksLeft));   // spec pack-shop 2.2: gems spent at the buy
        var collection = await client.GetCollectionAsync(Ct);
        var fresh = opened.Cards.Where(c => !c.Duplicate).Select(c => c.CardId).Distinct().Order().ToList();
        Assert.Equal(fresh, collection.Owned.Select(o => o.CardId).Order().ToList());
        Assert.Equal(opened.Cards.Sum(c => c.DustGained), collection.Dust);
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM pack_openings"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM outbox WHERE type = 'PackOpened'"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM wallet_ledger WHERE reason = 'pack_buy' AND delta = -100"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM wallet_ledger WHERE currency = 'gems'"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM pack_ledger WHERE reason = 'open' AND delta = -1 AND opening_id IS NOT NULL"));
        Assert.Empty((await client.GetCollectionAsync(Ct)).OwnedPacks);   // a zero count is left out
        await AssertCardLedgerAsync(factory);
        await AssertDustLedgerAsync(factory);
        await AssertPackLedgerAsync(factory);
    }

    [Fact]
    public async Task OpenPack_NeverDrawsACoreCard_OrACardOutsideThePacksSets()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100 * 40);
        for (var i = 0; i < 4; i++)
        {
            await BuyAsync(client, count: 10);
        }

        var drawn = new HashSet<string>();
        for (var i = 0; i < 40; i++)
        {
            foreach (var card in (await OpenAsync(client)).Cards)
            {
                drawn.Add(card.CardId);
            }
        }

        Assert.Empty(drawn.Intersect(CoreItems.Concat(CoreCharacters)));
        Assert.All(drawn, id => Assert.Contains(id, Catalog().Cards.Where(c => c.SetId == Descent).Select(c => c.Id)));
    }

    [Fact]
    public async Task OpenPack_Replayed_SpendsOnce_AndReturnsTheSameCards()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 250);
        await BuyAsync(client, count: 2);
        var key = Guid.NewGuid();

        var first = await OpenAsync(client, key: key);
        var again = await OpenAsync(client, key: key);

        Assert.Equal(first, again with { Cards = first.Cards });
        Assert.Equal(first.Cards, again.Cards);
        Assert.Equal(1, again.PacksLeft);
        var collection = await client.GetCollectionAsync(Ct);
        Assert.Equal(50, collection.Gems);
        Assert.Equal([new OwnedPackDto(StarterPack, 1)], collection.OwnedPacks);   // one pack spent, not two
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM pack_openings"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM outbox WHERE type = 'PackOpened'"));
    }

    [Fact]
    public async Task RequestKey_ReusedForAnotherAction_IsRejected()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 250);
        await OwnAsync(factory, player, "item.k1");
        var key = Guid.NewGuid();
        await BuyAsync(client);
        await OpenAsync(client, key: key);

        var error = await RefusedAsync(() => client.DustCardAsync("item.k1", key, Ct));

        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.RequestKeyReused), (error.StatusCode, error.ErrorCode));
    }

    [Fact]
    public async Task OpenPack_BodyWithoutAKey_IsABadRequest()
    {
        await using var factory = await FactoryAsync();
        var (client, _) = await PlayerAsync(factory, Name());

        var error = await RefusedAsync(() => client.OpenPackAsync(StarterPack, Guid.Empty, Ct));

        Assert.Equal(HttpStatusCode.BadRequest, error.StatusCode);
    }

    [Fact]
    public async Task BuyPack_Concurrent_NeverOverdraws()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);

        var results = await Task.WhenAll(Enumerable.Range(0, 6).Select(async _ =>
        {
            try
            {
                await BuyAsync(client);
                return (Ok: true, Code: 0);
            }
            catch (GameServerApiException error)
            {
                return (Ok: false, Code: error.ErrorCode ?? 0);
            }
        }));

        Assert.Equal(1, results.Count(r => r.Ok));
        Assert.All(results.Where(r => !r.Ok), r => Assert.Equal(ApiErrors.InsufficientCurrency, r.Code));
        var collection = await client.GetCollectionAsync(Ct);
        Assert.Equal(0, collection.Gems);
        Assert.Equal([new OwnedPackDto(StarterPack, 1)], collection.OwnedPacks);
        await AssertPackLedgerAsync(factory);
    }

    [Fact]
    public async Task OpenPack_ADuplicate_IsAutoDusted_NeverASecondHolding()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        await AddPackAsync(factory, CommonsOnly("commons", price: 10));   // three commons, five draws: at least two duplicates

        var opened = await BuyAndOpenAsync(client, "commons");

        var fresh = opened.Cards.Count(c => !c.Duplicate);
        var duplicates = opened.Cards.Count(c => c.Duplicate);
        Assert.Equal(5, opened.Cards.Count);
        Assert.Equal(opened.Cards.Select(c => c.CardId).Distinct().Count(), fresh);   // each card is new once, then a duplicate
        Assert.True(duplicates >= 2, $"five draws from three cards hold at least two duplicates, got {duplicates}");
        Assert.All(opened.Cards.Where(c => c.Duplicate), c => Assert.Equal(5, c.DustGained));
        var collection = await client.GetCollectionAsync(Ct);
        Assert.Equal(fresh, collection.Owned.Count);
        Assert.Equal(duplicates * 5, collection.Dust);
        Assert.Equal((long)duplicates, await CountAsync(factory, "SELECT count(*) FROM wallet_ledger WHERE reason = 'duplicate'"));
        await AssertCardLedgerAsync(factory);
        await AssertDustLedgerAsync(factory);
    }

    [Fact]
    public async Task OpenPack_ADuplicateDuringARun_NeverTouchesTheLockedCopy()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        await OwnAsync(factory, player, "item.k1", DateTimeOffset.UtcNow.AddMinutes(-5));
        await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"]), Ct);
        await AddPackAsync(factory, CommonsOnly("commons", price: 10));

        await BuyAndOpenAsync(client, "commons");

        var held = (await client.GetCollectionAsync(Ct)).Owned.Single(o => o.CardId == "item.k1");
        Assert.NotNull(held.LockedByRunId);
    }

    [Fact]
    public async Task BuyPack_PriceChangedAfterTheListing_ChargesTheCurrentPrice()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 500);
        var listed = (await client.GetPacksAsync(Ct)).Packs.Single();   // fills the pack cache at 100 gems
        await AddPackAsync(factory, FromListing(listed) with { PriceGems = 150 });

        var bought = await BuyAsync(client);

        Assert.Equal(150, bought.GemsSpent);
        Assert.Equal(2, bought.PackVersion);
        Assert.Equal(350, bought.Gems);
        // Spec pack-shop 6: the buy's ledger row carries the version bought.
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM pack_ledger WHERE reason = 'buy' AND pack_version = 2 AND delta = 1"));
        Assert.Equal(150, (await (await PlayerAsync(factory, Name())).Client.GetPacksAsync(Ct)).Packs.Single().PriceGems);   // the put deleted the cache
    }

    private static PackTypeRequest FromListing(PackTypeDto p) =>
        new(p.PackId, p.PackId, p.PriceGems, p.CardCount, p.OddsPer10000, p.SetIds, false, p.PityPacks, p.FirstGuarantees, p.MinRarityPerPack);

    // ---- pity --------------------------------------------------------------------------------------------------------

    [Fact]
    public async Task Pity_TheNthPackHoldsTheRarity_FlaggedAndTheCounterResets()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 1000);
        await AddPackAsync(factory, Pack("pity3", 10, 5, new Dictionary<string, int> { [CardRarities.Common] = 10_000 },
            pity: new Dictionary<string, int> { [CardRarities.Legendary] = 3 }));

        await BuyAsync(client, "pity3", 3);
        var first = await OpenAsync(client, "pity3");
        var second = await OpenAsync(client, "pity3");
        var counters = (await client.GetCollectionAsync(Ct)).Pity.Single(p => p.PackId == "pity3").MissedPacks[CardRarities.Legendary];
        var third = await OpenAsync(client, "pity3");

        Assert.DoesNotContain(first.Cards.Concat(second.Cards), c => c.Rarity == CardRarities.Legendary);
        Assert.Equal(2, counters);
        var forced = Assert.Single(third.Cards, c => c.Pity);
        Assert.Equal(CardRarities.Legendary, forced.Rarity);
        Assert.Equal(0, (await client.GetCollectionAsync(Ct)).Pity.Single(p => p.PackId == "pity3").MissedPacks[CardRarities.Legendary]);
    }

    [Fact]
    public async Task Pity_FirstGuarantee_LandsWithinTheFirstNPacks()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 1000);
        await AddPackAsync(factory, Pack("first2", 10, 5, new Dictionary<string, int> { [CardRarities.Common] = 10_000 },
            pity: new Dictionary<string, int> { [CardRarities.Mythic] = 30 }, first: new Dictionary<string, int> { [CardRarities.Mythic] = 2 }));

        var before = (await client.GetCollectionAsync(Ct)).Pity.SingleOrDefault(p => p.PackId == "first2");
        await BuyAsync(client, "first2", 2);
        var one = await OpenAsync(client, "first2");
        var two = await OpenAsync(client, "first2");

        Assert.Equal(28, before!.MissedPacks[CardRarities.Mythic]);   // a new player starts at pity - within
        Assert.Contains(one.Cards.Concat(two.Cards), c => c.Rarity == CardRarities.Mythic && c.Pity);
    }

    [Fact]
    public async Task Pity_CountersArePerPackType_AndAReplayCountsOnce()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 1000);
        var pity = new Dictionary<string, int> { [CardRarities.Legendary] = 50 };
        await AddPackAsync(factory, Pack("pa", 10, 5, new Dictionary<string, int> { [CardRarities.Common] = 10_000 }, pity: pity));
        await AddPackAsync(factory, Pack("pb", 10, 5, new Dictionary<string, int> { [CardRarities.Common] = 10_000 }, pity: pity));
        var key = Guid.NewGuid();
        await BuyAsync(client, "pa", 3);

        await OpenAsync(client, "pa", key);
        await OpenAsync(client, "pa", key);   // the same request again
        await OpenAsync(client, "pa");

        var counters = (await client.GetCollectionAsync(Ct)).Pity.ToDictionary(p => p.PackId, p => p.MissedPacks[CardRarities.Legendary]);
        Assert.Equal((2, 0), (counters["pa"], counters["pb"]));
    }

    /// <summary>
    /// Review fix (spec 3.4a): the first-open head start is for a player's first open of a pack type. A pack type that gains
    /// pity later gives players who already opened it counters at 0, not the head start.
    /// </summary>
    [Fact]
    public async Task Pity_APackTypeThatGainsPityLater_GivesItsVeteransNoFirstOpenHeadStart()
    {
        await using var factory = await FactoryAsync();
        var (veteran, veteranId) = await PlayerAsync(factory, Name() + "v");
        var (newcomer, _) = await PlayerAsync(factory, Name() + "n");
        await GrantAsync(factory, veteranId, gems: 1000);
        await AddPackAsync(factory, Pack("late", 10, 5, new Dictionary<string, int> { [CardRarities.Common] = 10_000 }));
        await BuyAndOpenAsync(veteran, "late");
        await BuyAndOpenAsync(veteran, "late");
        await AddPackAsync(factory, Pack("late", 10, 5, new Dictionary<string, int> { [CardRarities.Common] = 10_000 },
            pity: new Dictionary<string, int> { [CardRarities.Legendary] = 20 },
            first: new Dictionary<string, int> { [CardRarities.Legendary] = 10 }));

        var veterans = (await veteran.GetCollectionAsync(Ct)).Pity.Single(p => p.PackId == "late").MissedPacks[CardRarities.Legendary];
        var newcomers = (await newcomer.GetCollectionAsync(Ct)).Pity.Single(p => p.PackId == "late").MissedPacks[CardRarities.Legendary];

        Assert.Equal(0, veterans);
        Assert.Equal(10, newcomers);   // a player who never opened it still gets the head start: 20 - 10
    }

    /// <summary>
    /// Review fix: a rarity with no card rate is a rules gap, never a 500. A pack that can draw it is unavailable (nothing
    /// charged), a card of it cannot be dusted or crafted, and a pack type with odds on it is refused.
    /// </summary>
    [Fact]
    public async Task ARarityWithNoCardRate_RefusesTheAction_NeverA500()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100, dust: 10_000);
        await OwnAsync(factory, player, "item.e1");
        await AddPackAsync(factory, Pack("epics", 10, 5, new Dictionary<string, int> { [CardRarities.Epic] = 10_000 }));
        await BuyAsync(client, "epics");
        await using (var delete = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(
                         "DELETE FROM card_rates WHERE rarity = 'epic'"))
        {
            await delete.ExecuteNonQueryAsync(Ct);
        }

        var open = await RefusedAsync(() => OpenAsync(client, "epics"));
        var buy = await RefusedAsync(() => BuyAsync(client, "epics"));   // review fix: not sold while it cannot open
        var dust = await RefusedAsync(() => client.DustCardAsync("item.e1", Guid.NewGuid(), Ct));
        var put = await RefusedAsync(() => admin.PutPackTypeAsync(Pack("epics2", 10, 5,
            new Dictionary<string, int> { [CardRarities.Epic] = 10_000 }), Ct));

        Assert.Equal((HttpStatusCode.NotFound, ApiErrors.PackUnavailable), (open.StatusCode, open.ErrorCode));
        Assert.Equal((HttpStatusCode.NotFound, ApiErrors.PackUnavailable), (buy.StatusCode, buy.ErrorCode));
        Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.CardNotCollectible), (dust.StatusCode, dust.ErrorCode));
        Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.CardRuleInvalid), (put.StatusCode, put.ErrorCode));
        var collection = await client.GetCollectionAsync(Ct);
        Assert.Equal(90, collection.Gems);   // only the buy
        Assert.Equal([new OwnedPackDto("epics", 1)], collection.OwnedPacks);   // the refused open spent nothing
    }

    [Fact]
    public async Task OpenPack_NeverReturnsAPackWithoutARareOrBetter_WhenTheGuaranteeIsOn()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100 * 30);
        for (var i = 0; i < 3; i++)
        {
            await BuyAsync(client, count: 10);
        }

        for (var i = 0; i < 30; i++)
        {
            var opened = await OpenAsync(client);
            Assert.Contains(opened.Cards, c => c.Rarity != CardRarities.Common);
        }
    }

    [Fact]
    public async Task OpenPack_IsReproducibleFromTheStoredSeed()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);

        var opened = await BuyAndOpenAsync(client);

        var data = factory.Services.GetRequiredService<NpgsqlDataSource>();
        await using var command = data.CreateCommand("SELECT draw_seed, pity_before::text, catalog_version FROM pack_openings");
        await using var reader = await command.ExecuteReaderAsync(Ct);
        Assert.True(await reader.ReadAsync(Ct));
        var seed = reader.GetInt64(0);
        var before = System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, int>>(reader.GetString(1))!;
        var pack = (await client.GetPacksAsync(Ct)).Packs.Single();
        var eligible = (await client.GetCardCatalogAsync(Ct)).Cards.Where(c => !c.Core && !c.Retired && c.SetId == Descent)
            .GroupBy(c => c.Rarity).ToDictionary(g => g.Key, g => (IReadOnlyList<string>)[.. g.Select(c => c.Id).Order(StringComparer.Ordinal)]);

        var redrawn = PackDrawer.Draw(seed, new PackConfig(pack.CardCount, pack.OddsPer10000, pack.MinRarityPerPack, pack.PityPacks),
            eligible, before);

        Assert.Equal(seed.ToString(), opened.DrawSeed);
        Assert.Equal(opened.Cards.Select(c => c.CardId), redrawn.Cards.Select(c => c.CardId));
    }

    // ---- buying and owning packs (spec pack-shop) ---------------------------------------------------------------------

    [Fact]
    public async Task Buy_same_key_buys_once()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 1000);
        var key = Guid.NewGuid();

        var first = await BuyAsync(client, count: 3, key: key);
        var again = await BuyAsync(client, count: 3, key: key);

        Assert.Equal(first, again);
        Assert.Equal((3, 300, 700L, 3), (first.Count, first.GemsSpent, first.Gems, first.Owned));
        var collection = await client.GetCollectionAsync(Ct);
        Assert.Equal(700, collection.Gems);
        Assert.Equal([new OwnedPackDto(StarterPack, 3)], collection.OwnedPacks);
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM wallet_ledger WHERE reason = 'pack_buy' AND delta = -300"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM pack_ledger WHERE reason = 'buy' AND delta = 3"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM outbox WHERE type = 'PackPurchased'"));
        // The same key with another count is another request.
        var other = await RefusedAsync(() => BuyAsync(client, count: 2, key: key));
        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.RequestKeyReused), (other.StatusCode, other.ErrorCode));
        // Review fix: a retry that lost its count (it reads as 0) is a bad request, not "key reused".
        var countless = await RefusedAsync(() => BuyAsync(client, count: 0, key: key));
        Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.CardRuleInvalid), (countless.StatusCode, countless.ErrorCode));
        await AssertPackLedgerAsync(factory);
    }

    /// <summary>
    /// Acceptance scenario 2: the buy committed but its response never reached the client (the API crashed, the connection
    /// dropped). The client retries with the key it kept, on a new server instance, and gets the stored answer; gems are spent once.
    /// </summary>
    [Fact]
    public async Task Buy_replayed_after_commit_spends_once()
    {
        await using var factory = await FactoryAsync();
        var (_, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 250);
        var key = Guid.NewGuid();
        var store = factory.Services.GetRequiredService<CardStore>();

        // The commit, with no HTTP response: straight through the store, as the crashed request did.
        var committed = await store.BuyPacksAsync(Guid.Parse(player), Name(), StarterPack, 2, 10, key, DateTimeOffset.UtcNow, Ct);
        var (retrying, _) = await PlayerAsync(factory, Name());
        var retried = await BuyAsync(retrying, count: 2, key: key);

        Assert.Equal(committed.Value, retried);
        Assert.Equal(50, (await retrying.GetCollectionAsync(Ct)).Gems);
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM wallet_ledger WHERE reason = 'pack_buy'"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM outbox WHERE type = 'PackPurchased'"));
    }

    [Fact]
    public async Task Buy_key_reused_for_open_is_refused()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 250);
        var key = Guid.NewGuid();
        await BuyAsync(client, key: key);

        var error = await RefusedAsync(() => OpenAsync(client, key: key));

        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.RequestKeyReused), (error.StatusCode, error.ErrorCode));
        Assert.Equal(0L, await CountAsync(factory, "SELECT count(*) FROM pack_openings"));
        Assert.Equal([new OwnedPackDto(StarterPack, 1)], (await client.GetCollectionAsync(Ct)).OwnedPacks);
    }

    [Fact]
    public async Task Buy_refusals_write_nothing()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 250);
        await AddPackAsync(factory, CommonsOnly("old") with { Retired = true });

        var poor = await RefusedAsync(() => BuyAsync(client, count: 3));        // 300 > 250
        var none = await RefusedAsync(() => BuyAsync(client, count: 0));
        var many = await RefusedAsync(() => BuyAsync(client, count: 11));       // Cards:MaxPacksPerBuy is 10
        var unknown = await RefusedAsync(() => BuyAsync(client, "nope"));
        var retired = await RefusedAsync(() => BuyAsync(client, "old"));
        var keyless = await RefusedAsync(() => client.BuyPackAsync(StarterPack, new PackBuyRequest(Guid.Empty, 1), Ct));

        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.InsufficientCurrency), (poor.StatusCode, poor.ErrorCode));
        Assert.All([none, many], e => Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.CardRuleInvalid), (e.StatusCode, e.ErrorCode)));
        Assert.All([unknown, retired], e => Assert.Equal((HttpStatusCode.NotFound, ApiErrors.PackUnavailable), (e.StatusCode, e.ErrorCode)));
        Assert.Equal(HttpStatusCode.BadRequest, keyless.StatusCode);
        var collection = await client.GetCollectionAsync(Ct);
        Assert.Equal(250, collection.Gems);
        Assert.Empty(collection.OwnedPacks);
        Assert.Equal(0L, await CountAsync(factory,
            "SELECT (SELECT count(*) FROM pack_ledger) + (SELECT count(*) FROM pack_inventory) + (SELECT count(*) FROM account_requests)" +
            " + (SELECT count(*) FROM wallet_ledger) + (SELECT count(*) FROM outbox WHERE type = 'PackPurchased')"));
    }

    [Fact]
    public async Task Open_without_owned_pack_is_refused()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 1000);   // gems alone no longer open a pack

        var error = await RefusedAsync(() => OpenAsync(client));
        var unknown = await RefusedAsync(() => OpenAsync(client, "nope"));

        Assert.All([error, unknown], e => Assert.Equal((HttpStatusCode.Conflict, ApiErrors.NoPackOwned), (e.StatusCode, e.ErrorCode)));
        Assert.Equal(1000, (await client.GetCollectionAsync(Ct)).Gems);
        Assert.Equal(0L, await CountAsync(factory,
            "SELECT (SELECT count(*) FROM pack_openings) + (SELECT count(*) FROM pack_pity) + (SELECT count(*) FROM account_requests)"));
        var metrics = await factory.CreateClient().GetStringAsync("/metrics", Ct);
        Assert.Contains(metrics.Split('\n'), line => line.StartsWith("rpg_card_actions_refused_total{") && line.Contains("reason=\"NoPackOwned\""));
    }

    [Fact]
    public async Task Concurrent_opens_spend_one_pack_each()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 200);
        await BuyAsync(client, count: 2);

        var results = await Task.WhenAll(Enumerable.Range(0, 6).Select(async _ =>
        {
            try
            {
                await OpenAsync(client);
                return (Ok: true, Code: 0);
            }
            catch (GameServerApiException error)
            {
                return (Ok: false, Code: error.ErrorCode ?? 0);
            }
        }));

        Assert.Equal(2, results.Count(r => r.Ok));
        Assert.All(results.Where(r => !r.Ok), r => Assert.Equal(ApiErrors.NoPackOwned, r.Code));
        Assert.Empty((await client.GetCollectionAsync(Ct)).OwnedPacks);
        Assert.Equal(2L, await CountAsync(factory, "SELECT count(*) FROM pack_openings"));
        Assert.Equal(0L, await CountAsync(factory, "SELECT count(*) FROM pack_inventory WHERE count <> 0"));
        await AssertPackLedgerAsync(factory);
        await AssertCardLedgerAsync(factory);
    }

    [Fact]
    public async Task Retired_pack_type_still_opens_owned_packs()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        var commons = new Dictionary<string, int> { [CardRarities.Common] = 10_000 };
        var pity = new Dictionary<string, int> { [CardRarities.Legendary] = 50 };
        await AddPackAsync(factory, Pack("old", 10, 5, commons, pity: pity));
        await BuyAsync(client, "old", 2);
        await AddPackAsync(factory, Pack("old", 10, 5, commons, pity: pity, retired: true));   // version 2, retired

        var opened = await OpenAsync(client, "old");
        var buy = await RefusedAsync(() => BuyAsync(client, "old"));

        Assert.Equal((2, 5, 1), (opened.PackVersion, opened.Cards.Count, opened.PacksLeft));   // its last version
        Assert.Equal(ApiErrors.PackUnavailable, buy.ErrorCode);   // but it is no longer sold
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM pack_ledger WHERE reason = 'buy' AND pack_version = 1"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM pack_ledger WHERE reason = 'open' AND pack_version = 2"));
        // Its pity counters stay listed while the player still owns one (review fix).
        Assert.Equal(1, (await client.GetCollectionAsync(Ct)).Pity.Single(p => p.PackId == "old").MissedPacks[CardRarities.Legendary]);
    }

    [Fact]
    public async Task Undrawable_owned_pack_stays_owned()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        await AddPackAsync(factory, Pack("epics", 10, 5, new Dictionary<string, int> { [CardRarities.Epic] = 10_000 }));
        await BuyAsync(client, "epics");
        await SeedAsync(factory, new CardCatalogFile("fixture-3", [.. Catalog().Cards.Where(c => c.Id != "item.e1")]));   // no epic left

        var error = await RefusedAsync(() => OpenAsync(client, "epics"));

        Assert.Equal((HttpStatusCode.NotFound, ApiErrors.PackUnavailable), (error.StatusCode, error.ErrorCode));
        Assert.Equal([new OwnedPackDto("epics", 1)], (await client.GetCollectionAsync(Ct)).OwnedPacks);
        Assert.Equal(0L, await CountAsync(factory, "SELECT count(*) FROM pack_ledger WHERE reason = 'open'"));
        // Review fix: an undrawable pack is not sold either, so nobody pays for packs that cannot open.
        var buy = await RefusedAsync(() => BuyAsync(client, "epics"));
        Assert.Equal((HttpStatusCode.NotFound, ApiErrors.PackUnavailable), (buy.StatusCode, buy.ErrorCode));
        Assert.Equal(90, (await client.GetCollectionAsync(Ct)).Gems);
    }

    [Fact]
    public async Task Inventory_equals_ledger_sum()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 2000);
        await AddPackAsync(factory, CommonsOnly("commons", price: 10));
        await AddPackAsync(factory, CommonsOnly("alpha", price: 10));

        await BuyAsync(client, count: 3);
        await BuyAsync(client, "commons", 5);
        await OpenAsync(client);
        await BuyAsync(client, "alpha", 1);
        await OpenAsync(client, "commons");
        await OpenAsync(client, "commons");
        await BuyAsync(client, count: 1);
        await OpenAsync(client, "alpha");
        await RefusedAsync(() => OpenAsync(client, "alpha"));

        // Sorted by pack id, the empty "alpha" left out.
        Assert.Equal([new OwnedPackDto("commons", 3), new OwnedPackDto(StarterPack, 3)], (await client.GetCollectionAsync(Ct)).OwnedPacks);
        Assert.Equal(8L, await CountAsync(factory, "SELECT count(*) FROM pack_ledger"));   // 4 buys, 4 opens; the refusal wrote none
        await AssertPackLedgerAsync(factory);
    }

    [Fact]
    public async Task Buys_MoveTheBoughtCounter_AndTheOwnedGauge()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>(Cards)
        {
            ["Monitors:Interval"] = "00:00:00.200",
        });
        await SeedAsync(factory);
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 500);

        await BuyAsync(client, count: 3);
        await BuyAsync(client, count: 1);
        await OpenAsync(client);

        var metrics = await PollMetricsAsync(factory, text => Series(text, "rpg_packs_owned") == "3");
        Assert.Equal("3", Series(metrics, "rpg_packs_owned"));
        Assert.Equal("4", Series(metrics, "rpg_packs_bought_total", $"pack=\"{StarterPack}\""));
        Assert.Equal("2", Series(metrics, "rpg_account_action_duration_seconds_count", "action=\"buy_pack\""));
    }

    /// <summary>The value of the series <paramref name="name"/> carrying every one of <paramref name="labels"/>, or null.</summary>
    private static string? Series(string metrics, string name, params string[] labels) =>
        metrics.Split('\n')
            .Where(line => (line.StartsWith(name + "{", StringComparison.Ordinal) || line.StartsWith(name + " ", StringComparison.Ordinal))
                           && labels.All(line.Contains))
            .Select(line => line[(Math.Max(line.LastIndexOf('}'), name.Length - 1) + 1)..].Trim().Split(' ')[0])
            .FirstOrDefault();

    // ---- retiring with a refund (spec pack-shop 2.5) -----------------------------------------------------------------

    /// <summary>The Open packs page opening: the one call that settles the player's refunds (spec pack-shop 2.5).</summary>
    private static Task<PackRefundsResponse> OpenPacksPageAsync(GameServerClient client) => client.RefundPacksAsync(Ct);

    private static Task<long> RefundRowsAsync(ApiFactory factory) =>
        CountAsync(factory, "SELECT count(*) FROM pack_ledger WHERE reason = 'refund'");

    [Fact]
    public async Task RetireWithRefund_PaysEachOwnerWhatTheyPaid_OnTheOpenPacksPage()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var (alice, a) = await PlayerAsync(factory, Name() + "a");
        var (bob, b) = await PlayerAsync(factory, Name() + "b");
        await GrantAsync(factory, a, gems: 200);
        await GrantAsync(factory, b, gems: 100);
        var commons = new Dictionary<string, int> { [CardRarities.Common] = 10_000 };
        await AddPackAsync(factory, Pack("old", 10, 5, commons));
        await BuyAsync(alice, "old", 3);                                   // 3 at 10
        await AddPackAsync(factory, Pack("old", 30, 5, commons));          // version 2: 30 gems
        await BuyAsync(alice, "old", 2);                                   // 2 at 30: alice paid 90, has 110 left
        await BuyAsync(bob, "old", 1);                                     // 1 at 30: bob has 70 left
        await OpenAsync(alice, "old");                                     // opens spend the oldest first: 4 left = 2 at 30 + 2 at 10

        // The refund version may break the openability rule (a set with no cards): nobody opens it.
        var retired = await admin.PutPackTypeAsync(Pack("old", 30, 5, commons, set: "no-such-set", retired: true) with { RefundUnopened = true }, Ct);
        var pending = await RefusedAsync(() => OpenAsync(alice, "old"));   // not paid yet, and not opened
        await PlayerAsync(factory, Name() + "a");                          // a login pays nothing
        var read = await bob.GetCollectionAsync(Ct);                       // nor does the collection read
        var before = await RefundRowsAsync(factory);
        var aliceRefunds = await OpenPacksPageAsync(alice);                // the Open packs page pays, and says what it paid
        var bobRefunds = await OpenPacksPageAsync(bob);
        var aliceAgain = await OpenPacksPageAsync(alice);                  // a second visit finds nothing due
        var bobNow = await bob.GetCollectionAsync(Ct);
        var aliceNow = await alice.GetCollectionAsync(Ct);

        Assert.True(retired.RefundUnopened);
        Assert.Equal((HttpStatusCode.NotFound, ApiErrors.PackUnavailable), (pending.StatusCode, pending.ErrorCode));
        Assert.Contains("Open packs page", pending.Problem?.Detail);
        Assert.Equal(0L, before);
        Assert.Equal([new OwnedPackDto("old", 1)], read.OwnedPacks);
        Assert.Equal([new PackRefundDto("old", 4, 80)], aliceRefunds.Refunded);
        Assert.Equal([new PackRefundDto("old", 1, 30)], bobRefunds.Refunded);
        Assert.Empty(aliceAgain.Refunded);
        Assert.Equal((190L, 100L), (aliceNow.Gems, bobNow.Gems));          // 110 + 80, 70 + 30
        Assert.Empty(aliceNow.OwnedPacks);
        Assert.Empty(bobNow.OwnedPacks);
        Assert.Equal(2L, await CountAsync(factory, "SELECT count(*) FROM pack_ledger WHERE reason = 'refund' AND pack_version = 3"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM wallet_ledger WHERE reason = 'pack_refund' AND delta = 80"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM wallet_ledger WHERE reason = 'pack_refund' AND delta = 30"));
        Assert.Equal(2L, await CountAsync(factory,
            "SELECT count(*) FROM outbox WHERE type = 'PackRefunded' AND (payload->'payload'->>'gemsRefunded')::int IN (80, 30)"));
        await AssertPackLedgerAsync(factory);
        var metrics = await factory.CreateClient().GetStringAsync("/metrics", Ct);
        Assert.Equal("5", Series(metrics, "rpg_packs_refunded_total", "pack=\"old\""));
        Assert.Equal("110", Series(metrics, "rpg_pack_refund_gems_total"));
    }

    /// <summary>Postgres is a hard dependency (the user): with it down, a login answers 503, never a token.</summary>
    [Fact]
    public async Task Login_WithPostgresUnreachable_Is503()
    {
        await using var factory = new ApiFactory(StackFixture.Unreachable.Postgres, stack.RedisConnectionString, stack.RabbitMqUri,
            "Development", Cards);
        var client = new GameServerClient(factory.CreateClient());

        var error = await RefusedAsync(() => client.GetDevTokenAsync(new DevTokenRequest(Name()), Ct));

        Assert.Equal(HttpStatusCode.ServiceUnavailable, error.StatusCode);
    }

    [Fact]
    public async Task Refund_TwoVisitsAtOnce_PayOnce()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        var commons = new Dictionary<string, int> { [CardRarities.Common] = 10_000 };
        await AddPackAsync(factory, Pack("old", 10, 5, commons));
        await BuyAsync(client, "old", 4);
        await admin.PutPackTypeAsync(Pack("old", 10, 5, commons, retired: true) with { RefundUnopened = true }, Ct);

        // Two devices open the page at once, then once more: the account lock and the unique keys pay once.
        var visits = await Task.WhenAll(OpenPacksPageAsync(client), OpenPacksPageAsync(client));
        var again = await OpenPacksPageAsync(client);

        Assert.Equal(1, visits.Sum(v => v.Refunded.Count));
        Assert.Empty(again.Refunded);
        Assert.Equal(100, (await client.GetCollectionAsync(Ct)).Gems);
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM wallet_ledger WHERE reason = 'pack_refund'"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM outbox WHERE type = 'PackRefunded'"));
        await AssertPackLedgerAsync(factory);
    }

    /// <summary>
    /// Security review fix: the refund's ledger key is derived from public values, so a player could buy with that very key.
    /// Refund rows have a key space of their own (the reason is part of the unique key), and an owner that still fails never
    /// stops the pass for everyone else.
    /// </summary>
    [Fact]
    public async Task Refund_APlayersOwnKeyCannotBlockIt()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var (mallory, m) = await PlayerAsync(factory, Name() + "m");
        var (other, o) = await PlayerAsync(factory, Name() + "o");
        await GrantAsync(factory, m, gems: 100);
        await GrantAsync(factory, o, gems: 100);
        var commons = new Dictionary<string, int> { [CardRarities.Common] = 10_000 };
        await AddPackAsync(factory, Pack("old", 10, 5, commons));
        await BuyAsync(mallory, "old", 1, CardStore.RefundKey(Guid.Parse(m), "old", 2, 0));   // the key the refund will use
        await BuyAsync(other, "old", 1);
        await admin.PutPackTypeAsync(Pack("old", 10, 5, commons, retired: true) with { RefundUnopened = true }, Ct);   // version 2

        var paid = await OpenPacksPageAsync(mallory);
        await OpenPacksPageAsync(other);

        Assert.Equal([new PackRefundDto("old", 1, 10)], paid.Refunded);
        Assert.Equal(2L, await RefundRowsAsync(factory));
        Assert.Equal((100L, 100L), ((await mallory.GetCollectionAsync(Ct)).Gems, (await other.GetCollectionAsync(Ct)).Gems));
        await AssertPackLedgerAsync(factory);
    }

    /// <summary>
    /// Spec pack-shop 2.5: packs no buy row prices (a damaged ledger) are never refunded for nothing nor taken away. What the
    /// buys prove is paid, the rest stays in the inventory held for a support check: the collection flags it, the open says so,
    /// later visits leave it alone, and the failure metric moves.
    /// </summary>
    [Fact]
    public async Task Refund_UnpricedPacks_AreHeldForASupportCheck_AndThePricedOnesPaid()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        var commons = new Dictionary<string, int> { [CardRarities.Common] = 10_000 };
        await AddPackAsync(factory, Pack("old", 10, 5, commons));
        await BuyAsync(client, "old", 3);
        await using (var damage = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(
                         $"UPDATE pack_ledger SET delta = 1 WHERE player_id = '{player}' AND reason = 'buy'"))   // the ledger now prices 1 of 3
        {
            await damage.ExecuteNonQueryAsync(Ct);
        }

        await admin.PutPackTypeAsync(Pack("old", 10, 5, commons, retired: true) with { RefundUnopened = true }, Ct);
        var first = await OpenPacksPageAsync(client);
        var second = await OpenPacksPageAsync(client);   // a later visit leaves the held packs alone
        var collection = await client.GetCollectionAsync(Ct);
        var open = await RefusedAsync(() => OpenAsync(client, "old"));

        Assert.Equal([new PackRefundDto("old", 1, 10)], first.Refunded);
        Assert.Empty(second.Refunded);
        Assert.Equal(80, collection.Gems);                                         // 70 after the buy + the one priced pack
        Assert.Equal([new OwnedPackDto("old", 2, RefundHeld: true)], collection.OwnedPacks);
        Assert.Equal(ApiErrors.PackUnavailable, open.ErrorCode);
        Assert.Contains("support check", open.Problem?.Detail);
        Assert.Equal(1L, await RefundRowsAsync(factory));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM wallet_ledger WHERE reason = 'pack_refund' AND delta = 10"));
        var metrics = await factory.CreateClient().GetStringAsync("/metrics", Ct);
        Assert.Equal("1", Series(metrics, "rpg_pack_refund_failures_total", "pack=\"old\"", "reason=\"held\""));

        // Review fix: operations repairs the ledger and clears the hold; the next visit pays the rest, once, without paying the
        // already refunded pack again (it gets keys of its own).
        await using (var repair = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(
                         $"UPDATE pack_ledger SET delta = 3 WHERE player_id = '{player}' AND reason = 'buy';" +
                         $"UPDATE pack_inventory SET refund_held = false WHERE player_id = '{player}'"))
        {
            await repair.ExecuteNonQueryAsync(Ct);
        }

        var settled = await OpenPacksPageAsync(client);
        await OpenPacksPageAsync(client);
        var after = await client.GetCollectionAsync(Ct);

        Assert.Equal([new PackRefundDto("old", 2, 20)], settled.Refunded);
        Assert.Equal(100, after.Gems);                                             // 80 + the two packs at 10
        Assert.Empty(after.OwnedPacks);
        Assert.Equal(2L, await RefundRowsAsync(factory));
        await AssertPackLedgerAsync(factory);
    }

    [Fact]
    public async Task Refund_SkipsATypeUnretiredBeforeThePlayerVisits()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        var commons = new Dictionary<string, int> { [CardRarities.Common] = 10_000 };
        await AddPackAsync(factory, Pack("old", 10, 5, commons));
        await BuyAsync(client, "old", 2);
        await admin.PutPackTypeAsync(Pack("old", 10, 5, commons, retired: true) with { RefundUnopened = true }, Ct);
        await admin.PutPackTypeAsync(Pack("old", 10, 5, commons), Ct);   // changed their mind in the same maintenance window

        var visit = await OpenPacksPageAsync(client);
        var opened = await OpenAsync(client, "old");

        Assert.Empty(visit.Refunded);

        Assert.Equal((3, 1), (opened.PackVersion, opened.PacksLeft));   // v1, the refund retirement, then v3 back on sale
        Assert.Equal(80, (await client.GetCollectionAsync(Ct)).Gems);
        Assert.Equal(0L, await RefundRowsAsync(factory));
    }

    [Fact]
    public async Task RetireWithRefund_ARefundNeedsARetiredVersion()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var commons = new Dictionary<string, int> { [CardRarities.Common] = 10_000 };

        var error = await RefusedAsync(() => admin.PutPackTypeAsync(Pack("p", 10, 5, commons) with { RefundUnopened = true }, Ct));
        var listed = await admin.PutPackTypeAsync(Pack("p", 10, 5, commons), Ct);

        Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.CardRuleInvalid), (error.StatusCode, error.ErrorCode));
        Assert.Null(listed.RefundUnopened);   // left off the JSON unless true
        // A pack type saved before the 5-card rule can still be retired, or refunded, at its own size, within the old 1-20 bound.
        var oldSize = await admin.PutPackTypeAsync(Pack("p", 10, 3, commons, retired: true) with { RefundUnopened = true }, Ct);
        Assert.Equal(3, oldSize.CardCount);
        foreach (var size in new[] { 0, -1, 21 })
        {
            var bad = await RefusedAsync(() => admin.PutPackTypeAsync(Pack("p", 10, size, commons, retired: true), Ct));
            Assert.Equal(ApiErrors.CardRuleInvalid, bad.ErrorCode);
        }
    }

    // ---- dust and the run lock ---------------------------------------------------------------------------------------

    [Fact]
    public async Task Dust_RemovesTheCard_PaysTheFlatRate_AndReplayPaysOnce()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await OwnAsync(factory, player, "item.e1");
        var key = Guid.NewGuid();

        var dusted = await client.DustCardAsync("item.e1", key, Ct);
        var again = await client.DustCardAsync("item.e1", key, Ct);

        Assert.Equal((100, 1, 100), (dusted.DustGained, dusted.RateVersion, dusted.Dust));
        Assert.Equal(dusted, again);
        var collection = await client.GetCollectionAsync(Ct);
        Assert.Empty(collection.Owned);
        Assert.Equal(100, collection.Dust);
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM outbox WHERE type = 'CardDusted'"));
        await AssertCardLedgerAsync(factory);
        await AssertDustLedgerAsync(factory);
    }

    [Fact]
    public async Task Dust_ACoreCard_AnUnknownCard_AndACardNotHeld_AreRefused()
    {
        await using var factory = await FactoryAsync();
        var (client, _) = await PlayerAsync(factory, Name());

        var core = await RefusedAsync(() => client.DustCardAsync("item.core1", Guid.NewGuid(), Ct));
        var unknown = await RefusedAsync(() => client.DustCardAsync("item.nope", Guid.NewGuid(), Ct));
        var notHeld = await RefusedAsync(() => client.DustCardAsync("item.e1", Guid.NewGuid(), Ct));

        Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.CardNotCollectible), (core.StatusCode, core.ErrorCode));
        Assert.Equal(ApiErrors.CardNotCollectible, unknown.ErrorCode);
        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.CardNotOwned), (notHeld.StatusCode, notHeld.ErrorCode));
    }

    [Fact]
    public async Task Dust_ACardOwnedWhenTheRunStarted_IsLockedUntilTheRunEnds()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await OwnAsync(factory, player, "item.k1", DateTimeOffset.UtcNow.AddMinutes(-5));
        var run = await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"]), Ct);

        var locked = await RefusedAsync(() => client.DustCardAsync("item.k1", Guid.NewGuid(), Ct));
        var collection = await client.GetCollectionAsync(Ct);

        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.CardLockedByRun), (locked.StatusCode, locked.ErrorCode));
        Assert.Equal((run.RunId, "Active"), (locked.Problem!.RunId, locked.Problem.RunStatus));
        Assert.Equal((run.RunId, "Active"), (collection.ActiveRunId, collection.ActiveRunStatus));
        Assert.Equal(run.RunId, collection.Owned.Single().LockedByRunId);
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM card_holdings"));
    }

    [Fact]
    public async Task Dust_ACardAcquiredAfterTheRunStarted_IsNotLocked()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"]), Ct);
        await OwnAsync(factory, player, "item.k1", DateTimeOffset.UtcNow.AddMinutes(1));

        var dusted = await client.DustCardAsync("item.k1", Guid.NewGuid(), Ct);

        Assert.Equal(5, dusted.DustGained);
    }

    [Fact]
    public async Task Dust_AfterTheRunIsAbandoned_Succeeds()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await OwnAsync(factory, player, "item.k1", DateTimeOffset.UtcNow.AddMinutes(-5));
        var run = await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"]), Ct);
        await RefusedAsync(() => client.DustCardAsync("item.k1", Guid.NewGuid(), Ct));

        await client.AbandonRunAsync(run.RunId, Ct);
        var dusted = await client.DustCardAsync("item.k1", Guid.NewGuid(), Ct);

        Assert.Equal(5, dusted.DustGained);
        Assert.Equal(RunStatus.Abandoned, (await client.GetRunAsync(run.RunId, Ct)).Status);
        Assert.Null(await client.GetCurrentRunAsync(Ct));
    }

    [Fact]
    public async Task Dust_AVerifyingRunKeepsTheLock_UntilTheVerdict_AndCannotBeAbandoned()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await OwnAsync(factory, player, "item.k1", DateTimeOffset.UtcNow.AddMinutes(-5));
        var run = await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"]), Ct);
        await ExecuteAsync(factory, $"UPDATE runs SET status = 'Verifying' WHERE run_id = '{run.RunId}'");

        var locked = await RefusedAsync(() => client.DustCardAsync("item.k1", Guid.NewGuid(), Ct));
        var abandon = await RefusedAsync(() => client.AbandonRunAsync(run.RunId, Ct));
        await ExecuteAsync(factory, $"UPDATE runs SET status = 'Won', ended_at = now() WHERE run_id = '{run.RunId}'");
        var freed = await client.DustCardAsync("item.k1", Guid.NewGuid(), Ct);

        Assert.Equal((ApiErrors.CardLockedByRun, "Verifying"), (locked.ErrorCode, locked.Problem!.RunStatus));
        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.RunVerifying), (abandon.StatusCode, abandon.ErrorCode));
        Assert.Equal(5, freed.DustGained);
    }

    [Fact]
    public async Task Abandon_AnotherPlayersRun_IsNotFound_AndAnEndedRunIsNotActive()
    {
        await using var factory = await FactoryAsync();
        var (client, _) = await PlayerAsync(factory, Name() + "a");
        var (other, _) = await PlayerAsync(factory, Name() + "b");
        var run = await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"]), Ct);

        var stranger = await RefusedAsync(() => other.AbandonRunAsync(run.RunId, Ct));
        await ExecuteAsync(factory, $"UPDATE runs SET status = 'Lost', ended_at = now() WHERE run_id = '{run.RunId}'");
        var ended = await RefusedAsync(() => client.AbandonRunAsync(run.RunId, Ct));

        Assert.Equal(HttpStatusCode.NotFound, stranger.StatusCode);
        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.RunNotActive), (ended.StatusCode, ended.ErrorCode));
    }

    [Fact]
    public async Task RunStart_ConcurrentWithDust_PoolMatchesTheHoldings()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await OwnAsync(factory, player, "item.k1", DateTimeOffset.UtcNow.AddMinutes(-5));

        var start = client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"]), Ct);
        var dust = Task.Run(async () =>
        {
            try
            {
                await client.DustCardAsync("item.k1", Guid.NewGuid(), Ct);
                return true;
            }
            catch (GameServerApiException)
            {
                return false;
            }
        }, Ct);
        var run = await start;
        var dusted = await dust;

        // Either the dust won (the card is gone and not in the pool) or the run did (the card is in the pool and locked).
        var pool = run.CardPool!;
        Assert.Equal(!dusted, pool.Contains("item.k1"));
        Assert.Equal(!dusted, (await client.GetCollectionAsync(Ct)).Owned.Any(o => o.CardId == "item.k1"));
    }

    [Fact]
    public async Task Abandon_ARetriedCancel_IsASuccess()
    {
        await using var factory = await FactoryAsync();
        var (client, _) = await PlayerAsync(factory, Name());
        var run = await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"]), Ct);

        await client.AbandonRunAsync(run.RunId, Ct);
        await client.AbandonRunAsync(run.RunId, Ct);   // the first 204 was lost

        Assert.Equal(RunStatus.Abandoned, (await client.GetRunAsync(run.RunId, Ct)).Status);
    }

    /// <summary>
    /// Spec pack-shop: owned packs of a retired type open with its latest version, so a retirement is checked like any other
    /// version: one that could not be drawn, or that can give a rarity with no card rate, is refused when it is saved, and the
    /// packs players own keep opening with the last good version.
    /// </summary>
    [Fact]
    public async Task Admin_ARetirementThatWouldTrapOwnedPacks_IsRefused()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        var commons = new Dictionary<string, int> { [CardRarities.Common] = 10_000 };
        await AddPackAsync(factory, Pack("old", 10, 5, commons));
        await BuyAsync(client, "old", 2);
        await using (var delete = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(
                         "DELETE FROM card_rates WHERE rarity = 'epic'"))
        {
            await delete.ExecuteNonQueryAsync(Ct);
        }

        var undrawable = await RefusedAsync(() => admin.PutPackTypeAsync(
            Pack("old", 10, 5, new Dictionary<string, int> { [CardRarities.Common] = 10_000 }, set: "no-such-set", retired: true), Ct));
        var unrated = await RefusedAsync(() => admin.PutPackTypeAsync(
            Pack("old", 10, 5, new Dictionary<string, int> { [CardRarities.Common] = 5_000, [CardRarities.Epic] = 5_000 }, retired: true), Ct));
        var opened = await OpenAsync(client, "old");

        Assert.All([undrawable, unrated], e => Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.CardRuleInvalid), (e.StatusCode, e.ErrorCode)));
        Assert.Contains("no card rate", unrated.Problem?.Detail);
        Assert.Equal((1, 1), (opened.PackVersion, opened.PacksLeft));   // still the last good version
        await admin.PutPackTypeAsync(Pack("old", 10, 5, commons, retired: true), Ct);   // a sound retirement is fine
        Assert.Equal(2, (await OpenAsync(client, "old")).PackVersion);
    }

    /// <summary>
    /// Spec pack-shop: a rarity only a pity timer (or a first-pack guarantee) can give still needs a card rate: refused at the
    /// save, and when the rate goes away later the pack is no longer sold and an owned one is refused without being spent.
    /// </summary>
    [Fact]
    public async Task APityOnlyRarity_NeedsACardRate_AtTheSaveTheBuyAndTheOpen()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        var commons = new Dictionary<string, int> { [CardRarities.Common] = 10_000 };
        await AddPackAsync(factory, Pack("pity", 10, 5, commons, pity: new Dictionary<string, int> { [CardRarities.Mythic] = 2 }));
        await BuyAsync(client, "pity");
        await using (var delete = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(
                         "DELETE FROM card_rates WHERE rarity = 'mythic'"))
        {
            await delete.ExecuteNonQueryAsync(Ct);
        }

        var save = await RefusedAsync(() => admin.PutPackTypeAsync(Pack("pity2", 10, 5, commons,
            first: new Dictionary<string, int> { [CardRarities.Mythic] = 1 }, pity: new Dictionary<string, int> { [CardRarities.Mythic] = 2 }), Ct));
        var buy = await RefusedAsync(() => BuyAsync(client, "pity"));
        var open = await RefusedAsync(() => OpenAsync(client, "pity"));

        Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.CardRuleInvalid), (save.StatusCode, save.ErrorCode));
        Assert.All([buy, open], e => Assert.Equal((HttpStatusCode.NotFound, ApiErrors.PackUnavailable), (e.StatusCode, e.ErrorCode)));
        var collection = await client.GetCollectionAsync(Ct);
        Assert.Equal(90, collection.Gems);
        Assert.Equal([new OwnedPackDto("pity", 1)], collection.OwnedPacks);   // kept, to open once the rate is back
    }

    [Fact]
    public async Task Admin_APackNobodyCanDrawFrom_IsRefused_AndOneThatBecomesUndrawableIsUnavailable()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        // Only legendary odds, and the only legendaries are core-free items in the descent set: drawable. Epic-only is too.
        await AddPackAsync(factory, Pack("epics", 10, 5, new Dictionary<string, int> { [CardRarities.Epic] = 10_000 }));
        await BuyAsync(client, "epics");
        // Retire every epic: the pack is now undrawable, and the open must say so without spending the pack.
        await SeedAsync(factory, new CardCatalogFile("fixture-3", [.. Catalog().Cards.Where(c => c.Id != "item.e1")]));

        var error = await RefusedAsync(() => OpenAsync(client, "epics"));
        var refused = await RefusedAsync(() => admin.PutPackTypeAsync(Pack("epics2", 10, 5,
            new Dictionary<string, int> { [CardRarities.Epic] = 10_000 }), Ct));

        Assert.Equal((HttpStatusCode.NotFound, ApiErrors.PackUnavailable), (error.StatusCode, error.ErrorCode));
        Assert.Equal(ApiErrors.CardRuleInvalid, refused.ErrorCode);
        Assert.Equal(90, (await client.GetCollectionAsync(Ct)).Gems);
    }

    [Fact]
    public async Task Seeder_RefusesAnItemThatIsMythic_AndACharacterThatIsNot()
    {
        await using var factory = await FactoryAsync();
        var store = factory.Services.GetRequiredService<CardStore>();
        var mythicItem = new CardCatalogFile("bad-1", [new CatalogFileCard("item.x", "item", "mythic", "core", true, [])]);
        var plainHero = new CardCatalogFile("bad-2", [new CatalogFileCard("hero.x", "character", "legendary", "core", true, [])]);

        await Assert.ThrowsAsync<ArgumentException>(() => store.SeedCatalogAsync(mythicItem, DateTimeOffset.UtcNow, Ct));
        await Assert.ThrowsAsync<ArgumentException>(() => store.SeedCatalogAsync(plainHero, DateTimeOffset.UtcNow, Ct));
    }

    [Fact]
    public async Task SeedEconomy_RunTwice_SeedsOnce_AndNeverOverwritesAnAdminsVersion()
    {
        await using var factory = await FactoryAsync();   // seeds once already
        var (admin, _) = await PlayerAsync(factory, "designer");
        await admin.PutCardRateAsync(new CardRateRequest(CardRarities.Epic, 130, 520), Ct);
        var store = factory.Services.GetRequiredService<CardStore>();

        var again = await store.SeedEconomyAsync(CardFixtures.Economy(), 100_000, 100_000, DateTimeOffset.UtcNow, Ct);

        Assert.Equal((0, 0, 0), again);
        Assert.Equal(2, (await admin.ListCardRatesAsync(Ct)).Rates.Single(r => r.Rarity == CardRarities.Epic).Version);
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM pack_types WHERE pack_id = 'descent-pack'"));
    }

    [Fact]
    public async Task TheShippedSeedFile_IsValid_AndSeedsItsPackOverTheFixtureCatalog()
    {
        // infra/economy/card_economy.json is what a fresh server seeds (Cards:SeedFile): it must parse, pass every rule and give a
        // drawable pack. Run over the fixture catalog (same set and rarities), not the demo's content.
        var path = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "infra", "economy", "card_economy.json");
        var seed = System.Text.Json.JsonSerializer.Deserialize<CardEconomySeed>(await File.ReadAllTextAsync(path, Ct),
            Rpg.Contracts.Serialization.RpgJson.Options)!;
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Cards);
        await factory.Services.GetRequiredService<Rpg.GameServerApi.Migrations.MigrationRunner>().EnsureMigratedAsync(Ct);
        var store = factory.Services.GetRequiredService<CardStore>();
        await store.SeedCatalogAsync(Catalog(), DateTimeOffset.UtcNow, Ct);

        var (rates, packs, skipped) = await store.SeedEconomyAsync(seed, 100_000, 100_000, DateTimeOffset.UtcNow, Ct);

        Assert.Equal((5, 1, 0), (rates, packs, skipped));
        Assert.Equal(CardRarities.Order.Length, seed.Rates.Count);
        var pack = Assert.Single(seed.Packs);
        Assert.Equal((10, 20, 30), (pack.PityPacks[CardRarities.Epic], pack.PityPacks[CardRarities.Legendary], pack.PityPacks[CardRarities.Mythic]));
        Assert.Equal((5, 10, 15), (pack.FirstGuarantees[CardRarities.Epic], pack.FirstGuarantees[CardRarities.Legendary], pack.FirstGuarantees[CardRarities.Mythic]));
        Assert.Equal(CardRarities.Rare, pack.MinRarityPerPack);
    }

    // ---- craft -------------------------------------------------------------------------------------------------------

    [Fact]
    public async Task Craft_SpendsDust_GrantsTheCard_AndReplayChargesOnce()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, dust: 500);
        var key = Guid.NewGuid();

        var crafted = await client.CraftCardAsync("item.e1", key, Ct);
        var again = await client.CraftCardAsync("item.e1", key, Ct);

        Assert.Equal((400, 100), (crafted.DustSpent, crafted.Dust));
        Assert.Equal(crafted, again);
        var collection = await client.GetCollectionAsync(Ct);
        Assert.Equal("craft", Assert.Single(collection.Owned).Source);
        Assert.Equal(100, collection.Dust);
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM outbox WHERE type = 'CardCrafted'"));
        await AssertCardLedgerAsync(factory);
    }

    [Fact]
    public async Task Craft_Refusals_NotEnoughDust_AlreadyOwned_Core_Unknown()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, dust: 50);
        await OwnAsync(factory, player, "item.k1");

        var poor = await RefusedAsync(() => client.CraftCardAsync("item.l1", Guid.NewGuid(), Ct));
        var owned = await RefusedAsync(() => client.CraftCardAsync("item.k1", Guid.NewGuid(), Ct));
        var core = await RefusedAsync(() => client.CraftCardAsync("item.core1", Guid.NewGuid(), Ct));
        var unknown = await RefusedAsync(() => client.CraftCardAsync("item.nope", Guid.NewGuid(), Ct));

        Assert.Equal(ApiErrors.InsufficientCurrency, poor.ErrorCode);
        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.CardAlreadyOwned), (owned.StatusCode, owned.ErrorCode));
        Assert.Equal(ApiErrors.CardNotCollectible, core.ErrorCode);
        Assert.Equal(ApiErrors.CardNotCollectible, unknown.ErrorCode);
        Assert.Equal(50, (await client.GetCollectionAsync(Ct)).Dust);
    }

    [Fact]
    public async Task Craft_DuringARun_IsAllowed_AndTheNewCardIsNotInThatRunsPool()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, dust: 100);
        var run = await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"]), Ct);

        await client.CraftCardAsync("item.r1", Guid.NewGuid(), Ct);

        Assert.DoesNotContain("item.r1", run.CardPool!);
        Assert.Null((await client.GetCollectionAsync(Ct)).Owned.Single().LockedByRunId);
    }

    // ---- the run's pool ----------------------------------------------------------------------------------------------

    [Fact]
    public async Task RunStart_ReturnsAndStoresThePool_CoreAndOwned_AndResumeReturnsItAgain()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await OwnAsync(factory, player, "item.e1");
        await OwnAsync(factory, player, "hero.m1");

        var run = await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a", "hero.m1"]), Ct);
        var resumed = await client.ResumeAsync(run.RunId, Ct);

        Assert.Equal(CoreItems.Append("item.e1").Order(StringComparer.Ordinal), run.CardPool!);
        Assert.Equal(run.CardPool!.Order(StringComparer.Ordinal), run.CardPool!);   // stored sorted, ordinally
        Assert.Equal([.. CoreCharacters, "hero.m1"], run.UnlockedCharacterIds!);
        Assert.Equal(run.CardPool, resumed.CardPool);
        Assert.Equal(run.UnlockedCharacterIds, resumed.UnlockedCharacterIds);
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM runs WHERE card_pool IS NOT NULL"));
    }

    [Fact]
    public async Task RunStart_ACharacterTheAccountDoesNotOwn_Is400_1409_AndNoRunIsCreated()
    {
        await using var factory = await FactoryAsync();
        var (client, _) = await PlayerAsync(factory, Name());
        var earlier = await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"]), Ct);

        var locked = await RefusedAsync(() => client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a", "hero.m2"]), Ct));
        var unknown = await RefusedAsync(() => client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["nobody"]), Ct));

        Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.CharacterLocked), (locked.StatusCode, locked.ErrorCode));
        Assert.Equal(ApiErrors.CharacterLocked, unknown.ErrorCode);
        Assert.Equal(earlier.RunId, (await client.GetCurrentRunAsync(Ct))!.RunId);   // the refused start abandoned nothing
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM runs"));
    }

    [Fact]
    public async Task RunStart_ARetiredCardStaysInThePool_WhileOwned()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await OwnAsync(factory, player, "item.k1");
        await SeedAsync(factory, new CardCatalogFile("fixture-2", [.. Catalog().Cards.Where(c => c.Id != "item.k1")]));

        var run = await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"]), Ct);

        Assert.Contains("item.k1", run.CardPool!);
    }

    [Fact]
    public async Task RunStart_WithCardsOnButNoCatalogSeeded_StartsAsBefore_NoPool()
    {
        // A server that is configured for cards but has seeded nothing yet has nothing to enforce: it must not refuse every run.
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Cards);
        var (client, _) = await PlayerAsync(factory, Name());

        var run = await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["anybody"]), Ct);

        Assert.Null(run.CardPool);
        Assert.Null(run.UnlockedCharacterIds);
    }

    /// <summary>
    /// Review fix: a server configured with a catalog file refuses run starts (503, Retry-After) until its seeder has loaded the
    /// catalog, so no run starts without the card checks it would have had a few seconds later.
    /// </summary>
    [Fact]
    public async Task RunStart_BeforeTheConfiguredCatalogIsLoaded_Is503_WithRetryAfter()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>(Cards)
        {
            ["Cards:CatalogFile"] = "no-such-catalog.json",   // never loads: the seeder keeps retrying
        });
        var (client, _) = await PlayerAsync(factory, Name());

        var error = await RefusedAsync(() => client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"]), Ct));

        Assert.Equal(HttpStatusCode.ServiceUnavailable, error.StatusCode);
        Assert.NotNull(error.RetryAfter);
        Assert.Equal(0L, await CountAsync(factory, "SELECT count(*) FROM runs"));
    }

    [Fact]
    public async Task RunStart_WithCardsOff_IsExactlyToday_NoPoolNoCharacterCheck()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>(Cards) { ["Cards:Enabled"] = "false" });
        var (client, _) = await PlayerAsync(factory, Name());

        var run = await client.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["anybody"]), Ct);
        var resumed = await client.ResumeAsync(run.RunId, Ct);

        Assert.Null(run.CardPool);
        Assert.Null(run.UnlockedCharacterIds);
        Assert.Null(resumed.CardPool);
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM runs WHERE card_pool IS NULL"));
    }

    // ---- the rules admin ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task Admin_PackTypes_AreVersioned_AppendOnly_AndValidated()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var odds = new Dictionary<string, int> { [CardRarities.Common] = 10_000 };

        var v1 = await admin.PutPackTypeAsync(Pack("p", 10, 5, odds), Ct);
        var v2 = await admin.PutPackTypeAsync(Pack("p", 20, 5, odds), Ct);
        var badSum = await RefusedAsync(() => admin.PutPackTypeAsync(Pack("p", 10, 5, new Dictionary<string, int> { [CardRarities.Common] = 9_999 }), Ct));
        var badSet = await RefusedAsync(() => admin.PutPackTypeAsync(Pack("p", 10, 5, odds, set: "no-such-set"), Ct));
        var badFirst = await RefusedAsync(() => admin.PutPackTypeAsync(
            Pack("p", 10, 5, odds, pity: new Dictionary<string, int> { [CardRarities.Epic] = 5 }, first: new Dictionary<string, int> { [CardRarities.Epic] = 9 }), Ct));
        var badMin = await RefusedAsync(() => admin.PutPackTypeAsync(Pack("p", 10, 5, odds, min: CardRarities.Mythic), Ct));
        // Every pack holds 5 cards (the user, 2026-11-15).
        var badSizes = new[]
        {
            await RefusedAsync(() => admin.PutPackTypeAsync(Pack("p", 10, 4, odds), Ct)),
            await RefusedAsync(() => admin.PutPackTypeAsync(Pack("p", 10, 6, odds), Ct)),
        };   // a retired version may keep an older size (it is never sold)

        Assert.Equal((1, 2), (v1.Version, v2.Version));
        Assert.All([badSum, badSet, badFirst, badMin, .. badSizes], e => Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.CardRuleInvalid), (e.StatusCode, e.ErrorCode)));
        Assert.Equal(3L, await CountAsync(factory, "SELECT count(*) FROM pack_types WHERE pack_id = 'p' OR pack_id = 'descent-pack'"));
        Assert.Equal(20, (await admin.ListPackTypesAsync(Ct)).PackTypes.Single(p => p.PackId == "p").PriceGems);
        Assert.Equal(2L, await CountAsync(factory, "SELECT count(*) FROM outbox WHERE type = 'PackTypeChanged' AND payload->'payload'->>'packId' = 'p'"));
    }

    [Fact]
    public async Task Admin_CardRates_MustKeepCraftAboveDust_AndNeedTheRole()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var (player, _) = await PlayerAsync(factory, Name());

        var good = await admin.PutCardRateAsync(new CardRateRequest(CardRarities.Epic, 120, 480), Ct);
        var loop = await RefusedAsync(() => admin.PutCardRateAsync(new CardRateRequest(CardRarities.Epic, 400, 400), Ct));
        var unknown = await RefusedAsync(() => admin.PutCardRateAsync(new CardRateRequest("shiny", 1, 2), Ct));
        var forbidden = await RefusedAsync(() => player.PutCardRateAsync(new CardRateRequest(CardRarities.Epic, 1, 2), Ct));
        var forbiddenList = await RefusedAsync(() => player.ListCardRatesAsync(Ct));

        Assert.Equal((2, 120, 480), (good.Version, good.DustValue, good.CraftCost));
        Assert.Equal(ApiErrors.CardRuleInvalid, loop.ErrorCode);
        Assert.Equal(ApiErrors.CardRuleInvalid, unknown.ErrorCode);
        Assert.Equal((HttpStatusCode.Forbidden, ApiErrors.AdminRequired), (forbidden.StatusCode, forbidden.ErrorCode));
        Assert.Equal(HttpStatusCode.Forbidden, forbiddenList.StatusCode);
        Assert.Equal(120, (await admin.ListCardRatesAsync(Ct)).Rates.Single(r => r.Rarity == CardRarities.Epic).DustValue);
        Assert.Equal(120, (await player.GetCardCatalogAsync(Ct)).Cards.Single(c => c.Id == "item.e1").DustValue);   // the put deleted the cache
    }

    [Fact]
    public async Task Admin_ARateChange_AppliesToLaterDusts_AndTheLedgerNamesTheVersion()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var (client, player) = await PlayerAsync(factory, Name());
        await OwnAsync(factory, player, "item.e1");
        await admin.PutCardRateAsync(new CardRateRequest(CardRarities.Epic, 130, 520), Ct);

        var dusted = await client.DustCardAsync("item.e1", Guid.NewGuid(), Ct);

        Assert.Equal((130, 2), (dusted.DustGained, dusted.RateVersion));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM wallet_ledger WHERE rule_ref = 'rate:epic:2' AND delta = 130"));
    }

    // ---- reads and auth ----------------------------------------------------------------------------------------------

    [Fact]
    public async Task EveryCardEndpoint_NeedsAToken()
    {
        await using var factory = await FactoryAsync();
        var anonymous = new GameServerClient(factory.CreateClient());

        var errors = new[]
        {
            await RefusedAsync(() => anonymous.GetCardCatalogAsync(Ct)), await RefusedAsync(() => anonymous.GetPacksAsync(Ct)),
            await RefusedAsync(() => anonymous.GetCollectionAsync(Ct)), await RefusedAsync(() => anonymous.OpenPackAsync(StarterPack, Guid.NewGuid(), Ct)),
            await RefusedAsync(() => anonymous.BuyPackAsync(StarterPack, new PackBuyRequest(Guid.NewGuid(), 1), Ct)),
            await RefusedAsync(() => anonymous.RefundPacksAsync(Ct)),
            await RefusedAsync(() => anonymous.DustCardAsync("item.k1", Guid.NewGuid(), Ct)),
            await RefusedAsync(() => anonymous.CraftCardAsync("item.k1", Guid.NewGuid(), Ct)),
            await RefusedAsync(() => anonymous.AbandonRunAsync(Guid.NewGuid().ToString("D"), Ct)),
        };

        Assert.All(errors, e => Assert.Equal(HttpStatusCode.Unauthorized, e.StatusCode));
    }

    [Fact]
    public async Task Collection_OfOnePlayer_NeverShowsAnothers()
    {
        await using var factory = await FactoryAsync();
        var (alice, a) = await PlayerAsync(factory, Name() + "a");
        var (bob, b) = await PlayerAsync(factory, Name() + "b");
        await OwnAsync(factory, a, "item.e1");
        await GrantAsync(factory, b, gems: 7);

        Assert.Equal(["item.e1"], (await alice.GetCollectionAsync(Ct)).Owned.Select(o => o.CardId));
        Assert.Empty((await bob.GetCollectionAsync(Ct)).Owned);
        Assert.Equal(7, (await bob.GetCollectionAsync(Ct)).Gems);
        var error = await RefusedAsync(() => bob.DustCardAsync("item.e1", Guid.NewGuid(), Ct));
        Assert.Equal(ApiErrors.CardNotOwned, error.ErrorCode);
    }

    [Fact]
    public async Task AccountActions_WithPostgresUnreachable_Answer503()
    {
        await using var factory = new ApiFactory(StackFixture.Unreachable.Postgres, stack.RedisConnectionString, stack.RabbitMqUri,
            "Development", Cards);
        var client = new GameServerClient(factory.CreateClient(), Token(factory, "alice"));

        var open = await RefusedAsync(() => client.OpenPackAsync(StarterPack, Guid.NewGuid(), Ct));
        var buy = await RefusedAsync(() => client.BuyPackAsync(StarterPack, new PackBuyRequest(Guid.NewGuid(), 1), Ct));
        var collection = await RefusedAsync(() => client.GetCollectionAsync(Ct));

        Assert.Equal(HttpStatusCode.ServiceUnavailable, open.StatusCode);
        Assert.Equal(HttpStatusCode.ServiceUnavailable, buy.StatusCode);
        Assert.Equal(HttpStatusCode.ServiceUnavailable, collection.StatusCode);
    }

    [Fact]
    public async Task EveryOtherCardEndpoint_WithPostgresUnreachable_Answers503_NeverA500()
    {
        // The catalogs fall back to Postgres on a Redis miss, and the admin calls reach it after the role check.
        await using var factory = new ApiFactory(StackFixture.Unreachable.Postgres, stack.RedisConnectionString, stack.RabbitMqUri,
            "Development", Cards);
        var player = new GameServerClient(factory.CreateClient(), Token(factory, "alice"));
        var admin = new GameServerClient(factory.CreateClient(), Token(factory, "designer"));
        var pack = Pack("p", 10, 5, new Dictionary<string, int> { [CardRarities.Common] = 10_000 });

        var failures = new[]
        {
            await RefusedAsync(() => player.GetCardCatalogAsync(Ct)),
            await RefusedAsync(() => player.GetPacksAsync(Ct)),
            await RefusedAsync(() => player.DustCardAsync("item.k1", Guid.NewGuid(), Ct)),
            await RefusedAsync(() => player.CraftCardAsync("item.k1", Guid.NewGuid(), Ct)),
            await RefusedAsync(() => player.AbandonRunAsync(Guid.NewGuid().ToString("D"), Ct)),
            await RefusedAsync(() => admin.ListPackTypesAsync(Ct)),
            await RefusedAsync(() => admin.ListCardRatesAsync(Ct)),
            await RefusedAsync(() => admin.PutPackTypeAsync(pack, Ct)),
            await RefusedAsync(() => admin.PutCardRateAsync(new CardRateRequest(CardRarities.Epic, 100, 400), Ct)),
        };

        Assert.All(failures, e => Assert.Equal(HttpStatusCode.ServiceUnavailable, e.StatusCode));
    }
}
