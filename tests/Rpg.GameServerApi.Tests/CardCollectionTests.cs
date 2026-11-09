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

    [Fact]
    public async Task Catalog_WithRedisUnreachable_StillReadsFromPostgres_AndPacksStillOpen()
    {
        await using var factory = await FactoryAsync("127.0.0.1:1,abortConnect=false,connectTimeout=200");
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);

        var catalog = await client.GetCardCatalogAsync(Ct);
        var opened = await OpenAsync(client);

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
    public async Task OpenPack_SpendsGems_GrantsNewCards_AndWritesEveryLedger()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 250);

        var opened = await OpenAsync(client);

        Assert.Equal(5, opened.Cards.Count);
        Assert.Equal((100, 150), (opened.GemsSpent, opened.Gems));
        var collection = await client.GetCollectionAsync(Ct);
        var fresh = opened.Cards.Where(c => !c.Duplicate).Select(c => c.CardId).Distinct().Order().ToList();
        Assert.Equal(fresh, collection.Owned.Select(o => o.CardId).Order().ToList());
        Assert.Equal(opened.Cards.Sum(c => c.DustGained), collection.Dust);
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM pack_openings"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM outbox WHERE type = 'PackOpened'"));
        Assert.Equal(1L, await CountAsync(factory, "SELECT count(*) FROM wallet_ledger WHERE reason = 'pack_open' AND delta = -100"));
        await AssertCardLedgerAsync(factory);
        await AssertDustLedgerAsync(factory);
    }

    [Fact]
    public async Task OpenPack_NeverDrawsACoreCard_OrACardOutsideThePacksSets()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100 * 40);

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
        var key = Guid.NewGuid();

        var first = await OpenAsync(client, key: key);
        var again = await OpenAsync(client, key: key);

        Assert.Equal(first, again with { Cards = first.Cards });
        Assert.Equal(first.Cards, again.Cards);
        Assert.Equal(150, (await client.GetCollectionAsync(Ct)).Gems);
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
    public async Task OpenPack_WithTooFewGems_Is1402_AndNothingChanges()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 99);

        var error = await RefusedAsync(() => OpenAsync(client));

        Assert.Equal((HttpStatusCode.Conflict, ApiErrors.InsufficientCurrency), (error.StatusCode, error.ErrorCode));
        Assert.Equal(99, (await client.GetCollectionAsync(Ct)).Gems);
        Assert.Equal(0L, await CountAsync(factory, "SELECT count(*) FROM pack_openings"));
    }

    [Fact]
    public async Task OpenPack_UnknownOrRetired_Is404_1408()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 500);
        await AddPackAsync(factory, CommonsOnly("old") with { Retired = true });

        var unknown = await RefusedAsync(() => OpenAsync(client, "nope"));
        var retired = await RefusedAsync(() => OpenAsync(client, "old"));

        Assert.All([unknown, retired], e => Assert.Equal((HttpStatusCode.NotFound, ApiErrors.PackUnavailable), (e.StatusCode, e.ErrorCode)));
    }

    [Fact]
    public async Task OpenPack_Concurrent_NeverOverdraws()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);

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

        Assert.Equal(1, results.Count(r => r.Ok));
        Assert.All(results.Where(r => !r.Ok), r => Assert.Equal(ApiErrors.InsufficientCurrency, r.Code));
        Assert.Equal(0, (await client.GetCollectionAsync(Ct)).Gems);
        await AssertCardLedgerAsync(factory);
    }

    [Fact]
    public async Task OpenPack_ADuplicate_IsAutoDusted_NeverASecondHolding()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        await AddPackAsync(factory, CommonsOnly("commons", price: 10, count: 20));   // three commons, twenty draws

        var opened = await OpenAsync(client, "commons");

        Assert.Equal(20, opened.Cards.Count);
        Assert.Equal(3, opened.Cards.Count(c => !c.Duplicate));
        Assert.Equal(17, opened.Cards.Count(c => c.Duplicate));
        Assert.All(opened.Cards.Where(c => c.Duplicate), c => Assert.Equal(5, c.DustGained));
        var collection = await client.GetCollectionAsync(Ct);
        Assert.Equal(3, collection.Owned.Count);
        Assert.Equal(17 * 5, collection.Dust);
        Assert.Equal(17L, await CountAsync(factory, "SELECT count(*) FROM wallet_ledger WHERE reason = 'duplicate'"));
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
        await AddPackAsync(factory, CommonsOnly("commons", price: 10, count: 20));

        await OpenAsync(client, "commons");

        var held = (await client.GetCollectionAsync(Ct)).Owned.Single(o => o.CardId == "item.k1");
        Assert.NotNull(held.LockedByRunId);
    }

    [Fact]
    public async Task OpenPack_PriceChangedAfterTheListing_ChargesTheCurrentPrice()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 500);
        var listed = (await client.GetPacksAsync(Ct)).Packs.Single();   // fills the pack cache at 100 gems
        await AddPackAsync(factory, FromListing(listed) with { PriceGems = 150 });

        var opened = await OpenAsync(client);

        Assert.Equal(150, opened.GemsSpent);
        Assert.Equal(2, opened.PackVersion);
        Assert.Equal(350, opened.Gems);
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
        await AddPackAsync(factory, Pack("pity3", 10, 2, new Dictionary<string, int> { [CardRarities.Common] = 10_000 },
            pity: new Dictionary<string, int> { [CardRarities.Legendary] = 3 }));

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
        await AddPackAsync(factory, Pack("first2", 10, 1, new Dictionary<string, int> { [CardRarities.Common] = 10_000 },
            pity: new Dictionary<string, int> { [CardRarities.Mythic] = 30 }, first: new Dictionary<string, int> { [CardRarities.Mythic] = 2 }));

        var before = (await client.GetCollectionAsync(Ct)).Pity.SingleOrDefault(p => p.PackId == "first2");
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
        await AddPackAsync(factory, Pack("pa", 10, 1, new Dictionary<string, int> { [CardRarities.Common] = 10_000 }, pity: pity));
        await AddPackAsync(factory, Pack("pb", 10, 1, new Dictionary<string, int> { [CardRarities.Common] = 10_000 }, pity: pity));
        var key = Guid.NewGuid();

        await OpenAsync(client, "pa", key);
        await OpenAsync(client, "pa", key);   // the same request again
        await OpenAsync(client, "pa");

        var counters = (await client.GetCollectionAsync(Ct)).Pity.ToDictionary(p => p.PackId, p => p.MissedPacks[CardRarities.Legendary]);
        Assert.Equal((2, 0), (counters["pa"], counters["pb"]));
    }

    [Fact]
    public async Task OpenPack_NeverReturnsAPackWithoutARareOrBetter_WhenTheGuaranteeIsOn()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100 * 30);

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

        var opened = await OpenAsync(client);

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

    [Fact]
    public async Task Admin_APackNobodyCanDrawFrom_IsRefused_AndOneThatBecomesUndrawableIsUnavailable()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await PlayerAsync(factory, "designer");
        var (client, player) = await PlayerAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        // Only legendary odds, and the only legendaries are core-free items in the descent set: drawable. Epic-only is too.
        await AddPackAsync(factory, Pack("epics", 10, 1, new Dictionary<string, int> { [CardRarities.Epic] = 10_000 }));
        // Retire every epic: the pack is now undrawable, and the open must say so without charging.
        await SeedAsync(factory, new CardCatalogFile("fixture-3", [.. Catalog().Cards.Where(c => c.Id != "item.e1")]));

        var error = await RefusedAsync(() => OpenAsync(client, "epics"));
        var refused = await RefusedAsync(() => admin.PutPackTypeAsync(Pack("epics2", 10, 1,
            new Dictionary<string, int> { [CardRarities.Epic] = 10_000 }), Ct));

        Assert.Equal((HttpStatusCode.NotFound, ApiErrors.PackUnavailable), (error.StatusCode, error.ErrorCode));
        Assert.Equal(ApiErrors.CardRuleInvalid, refused.ErrorCode);
        Assert.Equal(100, (await client.GetCollectionAsync(Ct)).Gems);
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

        var v1 = await admin.PutPackTypeAsync(Pack("p", 10, 3, odds), Ct);
        var v2 = await admin.PutPackTypeAsync(Pack("p", 20, 3, odds), Ct);
        var badSum = await RefusedAsync(() => admin.PutPackTypeAsync(Pack("p", 10, 3, new Dictionary<string, int> { [CardRarities.Common] = 9_999 }), Ct));
        var badSet = await RefusedAsync(() => admin.PutPackTypeAsync(Pack("p", 10, 3, odds, set: "no-such-set"), Ct));
        var badFirst = await RefusedAsync(() => admin.PutPackTypeAsync(
            Pack("p", 10, 3, odds, pity: new Dictionary<string, int> { [CardRarities.Epic] = 5 }, first: new Dictionary<string, int> { [CardRarities.Epic] = 9 }), Ct));
        var badMin = await RefusedAsync(() => admin.PutPackTypeAsync(Pack("p", 10, 3, odds, min: CardRarities.Mythic), Ct));

        Assert.Equal((1, 2), (v1.Version, v2.Version));
        Assert.All([badSum, badSet, badFirst, badMin], e => Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.CardRuleInvalid), (e.StatusCode, e.ErrorCode)));
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
        var collection = await RefusedAsync(() => client.GetCollectionAsync(Ct));

        Assert.Equal(HttpStatusCode.ServiceUnavailable, open.StatusCode);
        Assert.Equal(HttpStatusCode.ServiceUnavailable, collection.StatusCode);
    }
}
