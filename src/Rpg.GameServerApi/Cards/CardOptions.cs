using System.Text.Json;
using Microsoft.Extensions.Options;
using Rpg.Contracts.Cards;
using Rpg.Contracts.Serialization;
using Rpg.Economy.Cards;
using Rpg.GameServerApi.Economy;
using Rpg.GameServerApi.Migrations;

namespace Rpg.GameServerApi.Cards;

/// <summary>Configuration section <c>Cards</c> (spec card-collection 3.5).</summary>
public sealed class CardOptions
{
    public const string Section = "Cards";

    /// <summary>
    /// False: the run start ignores the account (no pool, no character check), exactly today's behaviour. The existing e2e
    /// scenarios run like this on fixture content that has no catalog.
    /// </summary>
    public bool Enabled { get; set; } = true;

    /// <summary><c>infra/economy/card_catalog.json</c>, exported from content by the Godot tool.</summary>
    public string? CatalogFile { get; set; }

    /// <summary><c>infra/economy/card_economy.json</c>: placeholder rates and packs, filled only where no row exists.</summary>
    public string? SeedFile { get; set; }
}

/// <summary>
/// Seeds the catalog and the placeholder economy once the schema exists (spec card-collection 2.1). A file that would take a
/// core card away is a startup failure, not a retry: the host stops and the log names the card.
/// </summary>
/// <summary>
/// Review fix (2026-11-09): whether the card seeder has finished its first pass. Until then a run start with the card checks on
/// is refused with 503 (and a Retry-After): a run started before the catalog exists would hold no card pool and skip the
/// character check for good. With no catalog or seed file configured there is nothing to wait for.
/// </summary>
public sealed class CardSeedState
{
    private volatile bool _ready;

    public bool Ready => _ready;

    public void MarkReady() => _ready = true;
}

public sealed class CardSeeder(CardStore store, MigrationRunner migrations, IOptions<CardOptions> options,
    IOptions<EconomyOptions> economy, CatalogCache cache, TimeProvider clock, IHostEnvironment environment,
    CardSeedState state, ILogger<CardSeeder> logger) : BackgroundService
{
    private static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(5);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (string.IsNullOrWhiteSpace(options.Value.CatalogFile) && string.IsNullOrWhiteSpace(options.Value.SeedFile))
        {
            state.MarkReady();
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await migrations.EnsureMigratedAsync(stoppingToken);
                await SeedAsync(stoppingToken);
                state.MarkReady();
                return;
            }
            catch (Exception ex) when (ex is not (OperationCanceledException or CatalogDemotionException or ArgumentException or JsonException))
            {
                logger.LogWarning("Card catalog not seeded ({Message}); retrying in {Interval}", ex.Message, RetryInterval);
                await Task.Delay(RetryInterval, stoppingToken);
            }
        }
    }

    public async Task SeedAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        if (Resolve(options.Value.CatalogFile) is { } catalogPath)
        {
            var file = JsonSerializer.Deserialize<CardCatalogFile>(await File.ReadAllTextAsync(catalogPath, ct), RpgJson.Options)
                       ?? throw new JsonException("The card catalog file is empty.");
            var (version, changed) = await store.SeedCatalogAsync(file, now, ct);
            logger.LogInformation("Card catalog version {Version} ({State})", version, changed ? "seeded" : "unchanged");
            await cache.InvalidateAsync(CatalogCache.CardsKey, CatalogCache.PacksKey);
        }

        if (Resolve(options.Value.SeedFile) is { } seedPath)
        {
            var seed = JsonSerializer.Deserialize<CardEconomySeed>(await File.ReadAllTextAsync(seedPath, ct), RpgJson.Options)
                       ?? throw new JsonException("The card economy seed file is empty.");
            var (rates, packs, skipped) = await store.SeedEconomyAsync(seed, economy.Value.MaxPackPrice, economy.Value.MaxCardCost, now, ct);
            logger.LogInformation("Seeded {Rates} card rates and {Packs} pack types", rates, packs);
            if (skipped > 0)
            {
                logger.LogWarning("{Skipped} seed rates or pack types were invalid or name sets with no cards; seed the catalog first", skipped);
            }
            await cache.InvalidateAsync(CatalogCache.CardsKey, CatalogCache.PacksKey);
        }
    }

    private string? Resolve(string? path) =>
        string.IsNullOrWhiteSpace(path) ? null : Path.GetFullPath(path, environment.ContentRootPath);
}
