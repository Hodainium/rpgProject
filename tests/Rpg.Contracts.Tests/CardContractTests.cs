using System.Text.Json;
using Rpg.Contracts.Cards;
using Rpg.Contracts.Events;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;

namespace Rpg.Contracts.Tests;

/// <summary>Spec card-collection 6: golden JSON for every card record and event payload, and the additive run fields.</summary>
public class CardContractTests
{
    private const string RunId = "019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b";
    private const string Ruleset = "4.7.2.stable.mono+0123456789abcdef";
    private static readonly Guid Player = Guid.Parse("019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a01");
    private static readonly Guid EventId = Guid.Parse("019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a10");
    private static readonly DateTimeOffset At = new(2026, 11, 9, 12, 3, 9, TimeSpan.Zero);

    private static readonly Dictionary<string, int> Odds = new()
    {
        ["common"] = 7210, ["rare"] = 2200, ["epic"] = 450, ["legendary"] = 100, ["mythic"] = 40,
    };

    private static readonly Dictionary<string, int> Pity = new() { ["epic"] = 10, ["legendary"] = 20, ["mythic"] = 30 };
    private static readonly Dictionary<string, int> First = new() { ["epic"] = 5, ["legendary"] = 10, ["mythic"] = 15 };
    private static readonly PackCardDto[] Drawn =
    [
        new("item.silver_key", "common", false, 0, false), new("item.hex_charm", "rare", true, 20, false),
        new("hero.cryomancer", "mythic", false, 0, true),
    ];

    private static PackTypeRequest PackRequest(bool retired = false) =>
        new("descent-pack", "Descent Pack", 100, 5, Odds, ["descent"], retired, Pity, First, "rare");

    public static TheoryData<string, object> Goldens() => new()
    {
        {
            "card-catalog-file.json",
            new CardCatalogFile("5e1f", [
                new CatalogFileCard("warrior", "character", "mythic", "core", true, []),
                new CatalogFileCard("item.silver_key", "item", "common", "descent", false, ["Pool.Treasure", "Pool.Shop"]),
            ])
        },
        {
            "card-economy-seed.json",
            new CardEconomySeed([new CardRateRequest("common", 5, 40), new CardRateRequest("mythic", 800, 3200)], [PackRequest()])
        },
        {
            "card-catalog-response.json",
            new CatalogResponse(3, "5e1f", [
                new CardDto("warrior", "character", "mythic", "core", true, [], false, 800, 3200),
                new CardDto("item.silver_key", "item", "common", "descent", false, ["Pool.Treasure", "Pool.Shop"], true, 5, 40),
            ])
        },
        {
            "card-collection-response.json",
            new CollectionResponse([new OwnedCardDto("item.hex_charm", At, "pack", RunId), new OwnedCardDto("hero.cryomancer", At, "craft", null)],
                120, 340, 17, RunId, "Active",
                [new PityStateDto("descent-pack", new Dictionary<string, int> { ["epic"] = 4, ["legendary"] = 11, ["mythic"] = 2 })])
        },
        { "card-collection-response-empty.json", new CollectionResponse([], 0, 0, 0, null, null, []) },
        {
            "card-pack-list-response.json",
            new PackListResponse([
                new PackTypeDto("descent-pack", "Descent Pack", 2, 100, 5, Odds, ["descent"], ["hero.cryomancer", "item.hex_charm"], Pity, First, "rare"),
            ])
        },
        { "card-action-request.json", new AccountActionRequest(Guid.Parse("c0ffee00-0000-4000-8000-000000000001")) },
        { "card-pack-open-response.json", new PackOpenResponse("opening-1", "descent-pack", 2, 100, Drawn, 20, 20, "-1234567890123456789") },
        { "card-dust-response.json", new DustResponse("item.hex_charm", 20, 1, 340) },
        { "card-craft-response.json", new CraftResponse("hero.cryomancer", 3200, 1, 140) },
        { "card-pack-type-request.json", PackRequest() },
        {
            "card-pack-type-response.json",
            new PackTypeResponse("descent-pack", "Descent Pack", 2, 100, 5, Odds, ["descent"], false, Pity, First, "rare", At, "designer")
        },
        { "card-pack-type-list-response.json", new PackTypeListResponse([]) },
        { "card-rate-request.json", new CardRateRequest("legendary", 400, 1600) },
        { "card-rate-response.json", new CardRateResponse("legendary", 400, 1600, 2, At, "designer") },
        { "card-rate-list-response.json", new CardRateListResponse([]) },
        {
            "event-pack-opened.json",
            new DomainEvent<PackOpenedPayload>(EventId, EventTypes.PackOpened, 1, Player, null, At, "economy",
                new PackOpenedPayload("opening-1", Player.ToString("D"), "descent-pack", 2, 100, Drawn, 20, 2, "-1234567890123456789", 3, 1))
        },
        {
            "event-card-dusted.json",
            new DomainEvent<CardDustedPayload>(EventId, EventTypes.CardDusted, 1, Player, null, At, "economy",
                new CardDustedPayload(Player.ToString("D"), "item.hex_charm", "rare", 20, 1))
        },
        {
            "event-card-crafted.json",
            new DomainEvent<CardCraftedPayload>(EventId, EventTypes.CardCrafted, 1, Player, null, At, "economy",
                new CardCraftedPayload(Player.ToString("D"), "hero.cryomancer", "mythic", 3200, 1))
        },
        {
            "event-pack-type-changed.json",
            new DomainEvent<PackTypeChangedPayload>(EventId, EventTypes.PackTypeChanged, 1, Player, null, At, "economy",
                new PackTypeChangedPayload("descent-pack", 2, 100, false, "designer"))
        },
        {
            "event-card-rates-changed.json",
            new DomainEvent<CardRatesChangedPayload>(EventId, EventTypes.CardRatesChanged, 1, Player, null, At, "economy",
                new CardRatesChangedPayload("legendary", 400, 1600, 2, "designer"))
        },
        {
            "run-start-response-cards.json",
            new RunStartResponse(RunId, 0, "8070450532247928832", new DateTimeOffset(2026, 10, 27, 12, 0, 0, TimeSpan.Zero),
                ["warrior", "cleric"], ["item.core1", "item.silver_key"])
        },
    };

    [Theory]
    [MemberData(nameof(Goldens))]
    public void Record_MatchesGoldenVector_ByteForByte(string file, object record) =>
        Assert.Equal(ReadGolden(file, record), JsonSerializer.Serialize(record, record.GetType(), RpgJson.Options));

    [Theory]
    [MemberData(nameof(Goldens))]
    public void Record_GoldenVector_RoundTrips(string file, object record)
    {
        var text = ReadGolden(file, record);

        var parsed = JsonSerializer.Deserialize(text, record.GetType(), RpgJson.Options)!;

        Assert.Equal(text, JsonSerializer.Serialize(parsed, record.GetType(), RpgJson.Options));
    }

    [Fact]
    public void RunStartResponse_WithCardsOff_IsByteIdenticalToToday()
    {
        var text = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "golden", "run-start-response.json"));

        var parsed = JsonSerializer.Deserialize<RunStartResponse>(text, RpgJson.Options)!;

        Assert.Null(parsed.CardPool);
        Assert.Null(parsed.UnlockedCharacterIds);
        Assert.Equal(text, JsonSerializer.Serialize(parsed, RpgJson.Options));
    }

    [Fact]
    public void RunResumeResponse_WithCardsOff_WritesNoPoolFields()
    {
        var resume = new RunResumeResponse(RunId, RunStatus.Active, [], 0, JsonDocument.Parse("null").RootElement, []);

        var json = JsonSerializer.Serialize(resume, RpgJson.Options);

        Assert.DoesNotContain("cardPool", json);
        Assert.DoesNotContain("unlockedCharacterIds", json);
    }

    [Fact]
    public void StepRequest_WithoutAPool_WritesNoPoolField_AndWithOneCarriesIt()
    {
        var without = new StepRequest(1, RunId, "run.test", ["warrior"], new Dictionary<int, string> { [0] = "1" }, 0, 1,
            StepKind.Genesis, null, null, [], null);
        var with = without with { CardPool = ["item.core1", "item.e1"] };

        Assert.DoesNotContain("cardPool", JsonSerializer.Serialize(without, RpgJson.Options));
        Assert.Contains("\"cardPool\":[\"item.core1\",\"item.e1\"]", JsonSerializer.Serialize(with, RpgJson.Options));
    }

    [Fact]
    public void TheGodotCatalogExport_IsTheServersCatalogFile_ByteForByte()
    {
        // Cross-language check (spec card-collection 6): the file the Godot tool writes (its test pins it against the card
        // fixtures) must read as the record the server seeds from and write back unchanged.
        var path = Path.Combine(RepoRoot(), "client-godot", "tests", "fixtures", "golden", "game", "card_catalog.json");
        var text = File.ReadAllText(path);

        var parsed = JsonSerializer.Deserialize<CardCatalogFile>(text, RpgJson.Options)!;

        Assert.Equal(text, JsonSerializer.Serialize(parsed, RpgJson.Options));
        Assert.Equal(64, parsed.CatalogHash.Length);
        Assert.Contains(parsed.Cards, c => c.Kind == CardKinds.Character && c.Rarity == CardRarities.Mythic);
        Assert.Contains(parsed.Cards, c => c.Kind == CardKinds.Item && c.Core);
        Assert.All(parsed.Cards, c => Assert.Contains(c.Rarity, CardRarities.Order));
    }

    [Fact]
    public void CardRarities_AreInTheOrderThePackDrawWalks()
    {
        Assert.Equal(["common", "rare", "epic", "legendary", "mythic"], CardRarities.Order);
    }

    /// <summary>
    /// Reads a golden; with <c>RPG_WRITE_GOLDENS=1</c> a missing one is written first from the record (review the file, then commit it).
    /// </summary>
    private static string ReadGolden(string name, object record)
    {
        var built = Path.Combine(AppContext.BaseDirectory, "golden", name);
        if (!File.Exists(built) && Environment.GetEnvironmentVariable("RPG_WRITE_GOLDENS") == "1")
        {
            var source = Path.Combine(RepoRoot(), "tests", "Rpg.Contracts.Tests", "golden", name);
            File.WriteAllText(source, JsonSerializer.Serialize(record, record.GetType(), RpgJson.Options));
            return File.ReadAllText(source);
        }

        return File.ReadAllText(built);
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Rpg.slnx")))
        {
            dir = dir.Parent;
        }

        return dir!.FullName;
    }
}
