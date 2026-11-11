using System.Diagnostics;
using Microsoft.Extensions.Options;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Cards;
using Rpg.Economy.Cards;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Economy;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.RateLimiting;
using Rpg.GameServerApi.Runs;
using Rpg.Verification;

namespace Rpg.GameServerApi.Cards;

/// <summary>
/// The card endpoints (spec card-collection 2.2–2.7). Open, dust and craft are blocking account actions, idempotent by the
/// request key in the body; the rules admin needs the <c>economy-admin</c> role. Every error is a plain request error with its
/// <c>errorCode</c> (14xx), never a verdict.
/// </summary>
public static class CardEndpoints
{
    public static void MapCardEndpoints(this WebApplication app)
    {
        var api = app.MapGroup("/api/v1").RequireAuthorization();
        api.MapGet("/cards/catalog", CatalogAsync);
        api.MapGet("/packs", PacksAsync);
        api.MapGet("/cards/collection", CollectionAsync);
        api.MapPost("/packs/{packId}/open", OpenAsync).RateLimited(RateLimitOptions.Actions);
        api.MapPost("/cards/{cardId}/dust", DustAsync).RateLimited(RateLimitOptions.Actions);
        api.MapPost("/cards/{cardId}/craft", CraftAsync).RateLimited(RateLimitOptions.Actions);
        api.MapPut("/admin/pack-types", PutPackTypeAsync);
        api.MapGet("/admin/pack-types", ListPackTypesAsync);
        api.MapPut("/admin/card-rates", PutRateAsync);
        api.MapGet("/admin/card-rates", ListRatesAsync);
    }

    // ---- reads -----------------------------------------------------------------------------------------------------

    private static async Task<IResult> CatalogAsync(CardStore store, CatalogCache cache, MigrationRunner migrations,
        RpgMetrics metrics, CancellationToken ct)
    {
        if (await cache.GetAsync<CatalogResponse>(CatalogCache.CardsKey) is { } cached)
        {
            metrics.CardCatalogRead("redis");
            return Results.Ok(cached);
        }

        var generation = await cache.GenerationAsync();   // before Postgres: a write after it makes this refill a no-op
        await migrations.EnsureMigratedAsync(ct);
        var catalog = await store.GetCatalogAsync(ct);
        metrics.CardCatalogRead("postgres");
        await cache.SetAsync(CatalogCache.CardsKey, catalog, generation);
        return Results.Ok(catalog);
    }

    private static async Task<IResult> PacksAsync(CardStore store, CatalogCache cache, MigrationRunner migrations,
        RpgMetrics metrics, CancellationToken ct)
    {
        if (await cache.GetAsync<PackListResponse>(CatalogCache.PacksKey) is { } cached)
        {
            metrics.CardCatalogRead("redis");
            return Results.Ok(cached);
        }

        var generation = await cache.GenerationAsync();
        await migrations.EnsureMigratedAsync(ct);
        var packs = await store.ListPacksAsync(ct);
        metrics.CardCatalogRead("postgres");
        await cache.SetAsync(CatalogCache.PacksKey, packs, generation);
        return Results.Ok(packs);
    }

    private static async Task<IResult> CollectionAsync(HttpContext context, CardStore store, MigrationRunner migrations,
        CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        return Results.Ok(await store.GetCollectionAsync(context.User.Player().Id, ct));
    }

    // ---- account actions -------------------------------------------------------------------------------------------

    private static async Task<IResult> OpenAsync(HttpContext context, string packId, AccountActionRequest? request, CardStore store,
        RunSummaryCache cache, MigrationRunner migrations, RpgMetrics metrics, TimeProvider clock, CancellationToken ct)
    {
        if (KeyProblem(request) is { } bad)
        {
            return bad;
        }

        var player = context.User.Player();
        Activity.Current?.SetTag("rpg.pack_id", packId);
        var watch = Stopwatch.StartNew();
        await migrations.EnsureMigratedAsync(ct);
        var result = await store.OpenPackAsync(player.Id, player.Name, packId, request!.RequestKey, clock.GetUtcNow(), ct);
        metrics.CardActionDuration("open_pack", watch.Elapsed);
        if (result.Problem is { } problem)
        {
            return Refused("open_pack", problem, metrics);
        }

        var response = result.Value!;
        if (result.Replayed)
        {
            metrics.AccountReplay("open_pack");
        }
        else
        {
            metrics.PackOpened(response.PackId, response.GemsSpent);
            foreach (var card in response.Cards)
            {
                metrics.PackCard(card.Rarity, card.Duplicate, card.Pity, card.DustGained);
            }

            await cache.InvalidateAsync(VerifyPolicy.WalletKey(player.Id));
        }

        return Results.Ok(response);
    }

    private static async Task<IResult> DustAsync(HttpContext context, string cardId, AccountActionRequest? request, CardStore store,
        RunSummaryCache cache, MigrationRunner migrations, RpgMetrics metrics, TimeProvider clock, CancellationToken ct)
    {
        if (KeyProblem(request) is { } bad)
        {
            return bad;
        }

        var player = context.User.Player();
        var watch = Stopwatch.StartNew();
        await migrations.EnsureMigratedAsync(ct);
        var result = await store.DustAsync(player.Id, player.Name, cardId, request!.RequestKey, clock.GetUtcNow(), ct);
        metrics.CardActionDuration("dust", watch.Elapsed);
        if (result.Problem is { } problem)
        {
            return Refused("dust", problem, metrics);
        }

        if (result.Replayed)
        {
            metrics.AccountReplay("dust");
        }
        else
        {
            metrics.CardDusted(result.Value!.DustGained);
            await cache.InvalidateAsync(VerifyPolicy.WalletKey(player.Id));
        }

        return Results.Ok(result.Value);
    }

    private static async Task<IResult> CraftAsync(HttpContext context, string cardId, AccountActionRequest? request, CardStore store,
        RunSummaryCache cache, MigrationRunner migrations, RpgMetrics metrics, TimeProvider clock, CancellationToken ct)
    {
        if (KeyProblem(request) is { } bad)
        {
            return bad;
        }

        var player = context.User.Player();
        var watch = Stopwatch.StartNew();
        await migrations.EnsureMigratedAsync(ct);
        var result = await store.CraftAsync(player.Id, player.Name, cardId, request!.RequestKey, clock.GetUtcNow(), ct);
        metrics.CardActionDuration("craft", watch.Elapsed);
        if (result.Problem is { } problem)
        {
            return Refused("craft", problem, metrics);
        }

        if (result.Replayed)
        {
            metrics.AccountReplay("craft");
        }
        else
        {
            metrics.CardCrafted(result.Value!.DustSpent);
            await cache.InvalidateAsync(VerifyPolicy.WalletKey(player.Id));
        }

        return Results.Ok(result.Value);
    }

    // ---- rules admin -----------------------------------------------------------------------------------------------

    private static async Task<IResult> PutPackTypeAsync(HttpContext context, PackTypeRequest? request, CardStore store,
        CatalogCache cache, MigrationRunner migrations, IOptions<EconomyOptions> options, TimeProvider clock, RpgMetrics metrics,
        CancellationToken ct)
    {
        if (!context.User.IsEconomyAdmin())
        {
            metrics.CardRuleChange("forbidden");
            return Forbidden();
        }

        await migrations.EnsureMigratedAsync(ct);
        var admin = context.User.Player();
        var result = await store.PutPackTypeAsync(request!, admin.Id, admin.Name, clock.GetUtcNow(), options.Value.MaxPackPrice, ct);
        if (result.Problem is { } problem)
        {
            metrics.CardRuleChange("invalid");
            return Problem(problem);
        }

        await cache.InvalidateAsync(CatalogCache.PacksKey);
        metrics.CardRuleChange("pack");
        return Results.Ok(result.Value!.ToResponse());
    }

    private static async Task<IResult> ListPackTypesAsync(HttpContext context, CardStore store, MigrationRunner migrations,
        RpgMetrics metrics, CancellationToken ct)
    {
        if (!context.User.IsEconomyAdmin())
        {
            metrics.CardRuleChange("forbidden");
            return Forbidden();
        }

        await migrations.EnsureMigratedAsync(ct);
        return Results.Ok(new PackTypeListResponse([.. (await store.ListPackTypesAsync(ct)).Select(p => p.ToResponse())]));
    }

    private static async Task<IResult> PutRateAsync(HttpContext context, CardRateRequest? request, CardStore store,
        CatalogCache cache, MigrationRunner migrations, IOptions<EconomyOptions> options, TimeProvider clock, RpgMetrics metrics,
        CancellationToken ct)
    {
        if (!context.User.IsEconomyAdmin())
        {
            metrics.CardRuleChange("forbidden");
            return Forbidden();
        }

        await migrations.EnsureMigratedAsync(ct);
        var admin = context.User.Player();
        var result = await store.PutRateAsync(request!, admin.Id, admin.Name, clock.GetUtcNow(), options.Value.MaxCardCost, ct);
        if (result.Problem is { } problem)
        {
            metrics.CardRuleChange("invalid");
            return Problem(problem);
        }

        await cache.InvalidateAsync(CatalogCache.CardsKey);
        metrics.CardRuleChange("rate");
        return Results.Ok(result.Value!.ToResponse());
    }

    private static async Task<IResult> ListRatesAsync(HttpContext context, CardStore store, MigrationRunner migrations,
        RpgMetrics metrics, CancellationToken ct)
    {
        if (!context.User.IsEconomyAdmin())
        {
            metrics.CardRuleChange("forbidden");
            return Forbidden();
        }

        await migrations.EnsureMigratedAsync(ct);
        return Results.Ok(new CardRateListResponse([.. (await store.ListRatesAsync(ct)).Select(r => r.ToResponse())]));
    }

    // ---- errors ----------------------------------------------------------------------------------------------------

    private static IResult? KeyProblem(AccountActionRequest? request) =>
        request is null || request.RequestKey == Guid.Empty
            ? RunEndpoints.BadRequest("A body with a requestKey (a non-empty GUID) is required.")
            : null;

    private static IResult Refused(string action, CardProblem problem, RpgMetrics metrics)
    {
        metrics.CardActionRefused(action, problem.Failure.ToString());
        return Problem(problem);
    }

    private static IResult Problem(CardProblem problem)
    {
        var (status, code, title) = problem.Failure switch
        {
            CardFailure.RuleInvalid => (StatusCodes.Status400BadRequest, ApiErrors.CardRuleInvalid, "Invalid card rule"),
            CardFailure.InsufficientCurrency => (StatusCodes.Status409Conflict, ApiErrors.InsufficientCurrency, "Not enough currency"),
            CardFailure.CardLockedByRun => (StatusCodes.Status409Conflict, ApiErrors.CardLockedByRun, "Card locked by the run"),
            CardFailure.CardNotCollectible => (StatusCodes.Status400BadRequest, ApiErrors.CardNotCollectible, "Card not collectible"),
            CardFailure.CardAlreadyOwned => (StatusCodes.Status409Conflict, ApiErrors.CardAlreadyOwned, "Card already owned"),
            CardFailure.CardNotOwned => (StatusCodes.Status409Conflict, ApiErrors.CardNotOwned, "Card not owned"),
            CardFailure.RequestKeyReused => (StatusCodes.Status409Conflict, ApiErrors.RequestKeyReused, "Request key reused"),
            CardFailure.PackUnavailable => (StatusCodes.Status404NotFound, ApiErrors.PackUnavailable, "Pack unavailable"),
            CardFailure.CharacterLocked => (StatusCodes.Status400BadRequest, ApiErrors.CharacterLocked, "Character not unlocked"),
            _ => (StatusCodes.Status409Conflict, ApiErrors.RunVerifying, "A run is being verified"),
        };
        var extensions = new Dictionary<string, object?> { ["errorCode"] = code };
        if (problem.RunId is not null)
        {
            extensions["runId"] = problem.RunId;
            extensions["runStatus"] = problem.RunStatus;
        }

        return Results.Problem(statusCode: status, title: title, detail: problem.Detail, extensions: extensions);
    }

    private static IResult Forbidden() =>
        Results.Problem(statusCode: StatusCodes.Status403Forbidden, title: "Economy admin required",
            detail: "This endpoint needs the economy-admin role.",
            extensions: new Dictionary<string, object?> { ["errorCode"] = ApiErrors.AdminRequired });
}
