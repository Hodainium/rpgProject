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
        api.MapPost("/account/session", SessionAsync).RateLimited(RateLimitOptions.Actions);
        api.MapPost("/packs/refunds", RefundsAsync).RateLimited(RateLimitOptions.Actions);
        api.MapPost("/packs/{packId}/buy", BuyAsync).RateLimited(RateLimitOptions.Actions);
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

    /// <summary>
    /// Spec account-session 2.1: the account login. Raises the player's session under the account lock and returns it with the
    /// collection read inside that lock (final: no older request can commit after it).
    /// </summary>
    private static async Task<IResult> SessionAsync(HttpContext context, CardStore store, MigrationRunner migrations,
        RpgMetrics metrics, TimeProvider clock, CancellationToken ct)
    {
        var player = context.User.Player();
        var watch = Stopwatch.StartNew();
        await migrations.EnsureMigratedAsync(ct);
        var response = await store.StartSessionAsync(player.Id, player.Name, clock.GetUtcNow(), ct);
        metrics.CardActionDuration("account_session", watch.Elapsed);
        metrics.AccountSessionStarted();
        Activity.Current?.SetTag("rpg.account_session", response.Session);
        return Results.Ok(response);
    }

    /// <summary>
    /// Spec pack-shop 2.5: the Open packs page's call when it opens. Pays back the player's unopened packs of a type retired with
    /// a refund (idempotent: a second call finds nothing due) and returns what it paid, for the page's notice.
    /// </summary>
    private static async Task<IResult> RefundsAsync(HttpContext context, PackRefundsRequest? request, PackRefunds refunds,
        RpgMetrics metrics, CancellationToken ct)
    {
        if (request?.Session is not { } session || session < 1)
        {
            return RunEndpoints.BadRequest("A body with the account session (session, 1 or more) is required.");
        }

        Activity.Current?.SetTag("rpg.account_session", session);
        var watch = Stopwatch.StartNew();
        var pass = await refunds.RefundAsync(context.User.Player().Id, session, ct);
        metrics.CardActionDuration("refund_packs", watch.Elapsed);
        if (pass.Problem is { } problem)
        {
            return Refused("refund_packs", problem, metrics);
        }

        return Results.Ok(new PackRefundsResponse([.. pass.Paid.Select(p => new PackRefundDto(p.PackId, p.Count, p.Gems))]));
    }

    /// <summary>Spec pack-shop 2.1: gems for 1..Cards:MaxPacksPerBuy unopened packs, idempotent by the request key.</summary>
    private static async Task<IResult> BuyAsync(HttpContext context, string packId, PackBuyRequest? request, CardStore store,
        RunSummaryCache cache, MigrationRunner migrations, RpgMetrics metrics, IOptions<CardOptions> options, TimeProvider clock,
        CancellationToken ct)
    {
        const string NeedsBody = "A body with a requestKey (a non-empty GUID) and a count is required.";
        if (request is null)
        {
            return RunEndpoints.BadRequest(NeedsBody);
        }

        if ((KeyProblem(request.RequestKey, NeedsBody) ?? FenceProblem(request.Session, request.ExpectedAccountVersion)) is { } bad)
        {
            return bad;
        }

        var player = context.User.Player();
        Activity.Current?.SetTag("rpg.pack_id", packId);
        Activity.Current?.SetTag("rpg.account_session", request.Session);
        var watch = Stopwatch.StartNew();
        await migrations.EnsureMigratedAsync(ct);
        var result = await store.BuyPacksAsync(player.Id, player.Name, packId, request.Count, options.Value.MaxPacksPerBuy,
            request.RequestKey, Fence(request.Session, request.ExpectedAccountVersion), clock.GetUtcNow(), ct);
        metrics.CardActionDuration("buy_pack", watch.Elapsed);
        if (result.Problem is { } problem)
        {
            return Refused("buy_pack", problem, metrics);
        }

        var response = result.Value!;
        if (result.Replayed)
        {
            metrics.AccountReplay("buy_pack");
        }
        else
        {
            metrics.PacksBought(response.PackId, response.Count, response.GemsSpent);
        }

        // On a replay too (review fix): the first request may have committed and died before it got here (acceptance 2).
        await cache.InvalidateAsync(VerifyPolicy.WalletKey(player.Id));

        return Results.Ok(response);
    }

    private static async Task<IResult> OpenAsync(HttpContext context, string packId, AccountActionRequest? request, CardStore store,
        RunSummaryCache cache, MigrationRunner migrations, RpgMetrics metrics, TimeProvider clock, CancellationToken ct)
    {
        if (KeyProblem(request) is { } bad)
        {
            return bad;
        }

        var player = context.User.Player();
        Activity.Current?.SetTag("rpg.account_session", request!.Session);
        Activity.Current?.SetTag("rpg.pack_id", packId);
        var watch = Stopwatch.StartNew();
        await migrations.EnsureMigratedAsync(ct);
        var result = await store.OpenPackAsync(player.Id, player.Name, packId, request!.RequestKey, Fence(request), clock.GetUtcNow(), ct);
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
            metrics.PackOpened(response.PackId);
            foreach (var card in response.Cards)
            {
                metrics.PackCard(card.Rarity, card.Duplicate, card.Pity, card.DustGained);
            }
        }

        // On a replay too (review fix): the first request may have committed and died before it got here (acceptance 2).
        await cache.InvalidateAsync(VerifyPolicy.WalletKey(player.Id));
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
        Activity.Current?.SetTag("rpg.account_session", request!.Session);
        var watch = Stopwatch.StartNew();
        await migrations.EnsureMigratedAsync(ct);
        var result = await store.DustAsync(player.Id, player.Name, cardId, request!.RequestKey, Fence(request), clock.GetUtcNow(), ct);
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
        }

        // On a replay too, as buy and open do: the first request may have committed and died before it got here (acceptance 2).
        await cache.InvalidateAsync(VerifyPolicy.WalletKey(player.Id));
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
        Activity.Current?.SetTag("rpg.account_session", request!.Session);
        var watch = Stopwatch.StartNew();
        await migrations.EnsureMigratedAsync(ct);
        var result = await store.CraftAsync(player.Id, player.Name, cardId, request!.RequestKey, Fence(request), clock.GetUtcNow(), ct);
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
        }

        // On a replay too, as buy and open do: the first request may have committed and died before it got here (acceptance 2).
        await cache.InvalidateAsync(VerifyPolicy.WalletKey(player.Id));
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
        KeyProblem(request?.RequestKey, "A body with a requestKey (a non-empty GUID) is required.")
        ?? FenceProblem(request!.Session, request.ExpectedAccountVersion);

    /// <summary>Spec account-session 3.1: a decision carries the session (1 or more) and the expected account version (0 or more).</summary>
    private static IResult? FenceProblem(long? session, long? expectedAccountVersion) =>
        session is null or < 1 || expectedAccountVersion is null or < 0
            ? RunEndpoints.BadRequest("The account session (session, 1 or more) and the account version the screen showed (expectedAccountVersion) are required.")
            : null;

    private static AccountFence Fence(long? session, long? expectedAccountVersion) => new(session!.Value, expectedAccountVersion!.Value);

    private static AccountFence Fence(AccountActionRequest request) => Fence(request.Session, request.ExpectedAccountVersion);

    private static IResult? KeyProblem(Guid? key, string detail) =>
        key is null || key == Guid.Empty ? RunEndpoints.BadRequest(detail) : null;

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
            CardFailure.NoPackOwned => (StatusCodes.Status409Conflict, ApiErrors.NoPackOwned, "No pack owned"),
            CardFailure.SessionReplaced => (StatusCodes.Status409Conflict, ApiErrors.AccountSessionReplaced, "Account session replaced"),
            CardFailure.AccountVersionStale => (StatusCodes.Status409Conflict, ApiErrors.AccountVersionStale, "Account changed"),
            _ => (StatusCodes.Status409Conflict, ApiErrors.RunVerifying, "A run is being verified"),
        };
        var extensions = new Dictionary<string, object?> { ["errorCode"] = code };
        if (problem.RunId is not null)
        {
            extensions["runId"] = problem.RunId;
            extensions["runStatus"] = problem.RunStatus;
        }

        if (problem.Failure == CardFailure.SessionReplaced)
        {
            extensions["currentSession"] = problem.Current;
        }
        else if (problem.Failure == CardFailure.AccountVersionStale)
        {
            extensions["currentAccountVersion"] = problem.Current;
        }

        return Results.Problem(statusCode: status, title: title, detail: problem.Detail, extensions: extensions);
    }

    private static IResult Forbidden() =>
        Results.Problem(statusCode: StatusCodes.Status403Forbidden, title: "Economy admin required",
            detail: "This endpoint needs the economy-admin role.",
            extensions: new Dictionary<string, object?> { ["errorCode"] = ApiErrors.AdminRequired });
}
