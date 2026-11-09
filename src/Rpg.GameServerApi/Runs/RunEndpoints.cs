using System.Diagnostics;
using Microsoft.Extensions.Options;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Runs;
using Rpg.Economy;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.RateLimiting;

namespace Rpg.GameServerApi.Runs;

/// <summary>
/// Run endpoints (spec server-authority 2.1–2.4, 3.2): start a run, the stairs, the current run, one run (Part A);
/// the action log, the end, resume and battle sessions (Part B, <see cref="RunActionEndpoints"/>). Every one needs a
/// bearer token; the caller is the token's <c>sub</c>. The server never runs game rules here: it issues seeds, orders
/// and stores, and serves the read model.
/// </summary>
public static class RunEndpoints
{
    public const int MaxCharacters = 8;
    public const int MaxIdLength = 128;

    public static void MapRunEndpoints(this WebApplication app)
    {
        var runs = app.MapGroup("/api/v1/runs").RequireAuthorization();
        runs.MapPost("", StartRunAsync).RateLimited(RateLimitOptions.Runs);
        runs.MapPost("/{runId:guid}/floors/{floor:int}", FloorSeedAsync).RateLimited(RateLimitOptions.Floors);
        runs.MapPost("/{runId:guid}/abandon", AbandonAsync);
        runs.MapGet("/current", GetCurrentAsync);
        runs.MapGet("/{runId:guid}", GetRunAsync);
        runs.MapRunActionEndpoints();
    }

    private static async Task<IResult> StartRunAsync(HttpContext context, RunStartRequest? request, RunStore store,
        RunSummaryCache cache, RulesetPolicy ruleset, RpgMetrics metrics, TimeProvider clock, CancellationToken ct)
    {
        var player = context.User.Player();
        if (Invalid(request) is { } problem)
        {
            return BadRequest(problem);
        }

        if (!ruleset.Accepts(request!.RulesetVersion))
        {
            metrics.RunStart("rejected");
            return Conflict(ApiErrors.RulesetMismatch, "Ruleset not accepted",
                $"Ruleset version '{request.RulesetVersion}' is not accepted by this server.");
        }

        var result = await store.StartAsync(player, request, clock.GetUtcNow(), ct);
        if (result.Outcome == StartOutcome.PreviousVerifying)
        {
            metrics.RunStart("rejected");
            return Conflict(ApiErrors.RunNotActive, "A run is being verified",
                $"Run {result.RunId:D} is waiting for its verdict and can't be abandoned.");
        }

        if (result.Outcome == StartOutcome.CharacterLocked)
        {
            metrics.RunStart("character_locked");
            return Results.Problem(statusCode: StatusCodes.Status400BadRequest, title: "Character not unlocked",
                detail: result.Detail, extensions: new Dictionary<string, object?> { ["errorCode"] = ApiErrors.CharacterLocked });
        }

        var keys = new List<string> { RunSummaryCache.CurrentKey(player.Id) };
        if (result.AbandonedRunId is { } abandoned)
        {
            keys.Add(RunSummaryCache.SummaryKey(abandoned));
        }

        await cache.InvalidateAsync([.. keys]);
        metrics.RunStart(result.Outcome == StartOutcome.Created ? "created" : "abandoned_previous");
        metrics.StepCreated("genesis");
        Activity.Current?.SetTag("rpg.run_id", result.RunId.ToString("D"));

        var response = new RunStartResponse(result.RunId.ToString("D"), 0, result.FloorSeed.ToString(), result.StartedAt,
            result.Pool?.UnlockedCharacterIds, result.Pool?.CardPool);
        return Results.Created($"/api/v1/runs/{response.RunId}", response);
    }

    /// <summary>Spec card-collection 2.3: cancels the Active run (abandoned, not a death). A Verifying run answers 409 1410.</summary>
    private static async Task<IResult> AbandonAsync(HttpContext context, Guid runId, RunStore store, RunSummaryCache cache,
        RpgMetrics metrics, TimeProvider clock, CancellationToken ct)
    {
        var player = context.User.Player();
        switch (await store.AbandonAsync(player.Id, runId, clock.GetUtcNow(), ct))
        {
            case AbandonOutcome.NotFound:
                return NotFound(runId);
            case AbandonOutcome.Verifying:
                return Conflict(ApiErrors.RunVerifying, "A run is being verified",
                    $"Run {runId:D} is waiting for its verdict and can't be cancelled.");
            case AbandonOutcome.NotActive:
                return Conflict(ApiErrors.RunNotActive, "Run not active", $"Run {runId:D} has ended.");
            case AbandonOutcome.AlreadyAbandoned:
                return Results.NoContent();   // a retried cancel: nothing changed, nothing to count
            default:
                await cache.InvalidateAsync(RunSummaryCache.SummaryKey(runId), RunSummaryCache.CurrentKey(player.Id));
                metrics.RunEnd(nameof(RunStatus.Abandoned));
                return Results.NoContent();
        }
    }

    /// <summary>The next floor needs <c>AfterSeq</c> = the run's last stored seq (Part B gate, 409 1106 otherwise).</summary>
    private static async Task<IResult> FloorSeedAsync(HttpContext context, Guid runId, int floor,
        FloorSeedRequest? request, RunStore store, RunSummaryCache cache, RpgMetrics metrics,
        IOptions<RunVerifyOptions> verify, TimeProvider clock, CancellationToken ct)
    {
        var player = context.User.Player();
        Activity.Current?.SetTag("rpg.run_id", runId.ToString("D"));
        Activity.Current?.SetTag("rpg.floor", floor);
        var result = await store.IssueFloorAsync(player.Id, runId, floor, request?.AfterSeq, request?.Epoch ?? 0,
            clock.GetUtcNow(), ct);
        switch (result.Outcome)
        {
            case FloorOutcome.NotFound:
                return NotFound(runId);
            case FloorOutcome.RolledBack:
                return RolledBack(result.Epoch, result.VerifiedSeq, result.Reason);
            case FloorOutcome.Unverified:
                // Spec run-verify 2.6: the floor just played is not verified yet; the client retries after Retry-After.
                metrics.StairsGate("blocked");
                context.Response.Headers.RetryAfter = Math.Max(1, (int)Math.Ceiling(verify.Value.GateRetryAfter.TotalSeconds)).ToString();
                return Conflict(ApiErrors.PreviousFloorUnverified, "Previous floor not verified",
                    "The floor you just played is still being verified. Try again shortly.",
                    new Dictionary<string, object?> { ["verifiedSeq"] = result.VerifiedSeq });
            case FloorOutcome.NotActive:
                return Conflict(ApiErrors.RunNotActive, "Run not active", $"Run {runId:D} has ended.");
            case FloorOutcome.NotReachable:
                metrics.FloorSeed("not_reachable");
                return Conflict(ApiErrors.FloorNotReachable, "Floor not reachable",
                    $"Floor {floor} is neither the run's current floor nor the next one.");
            case FloorOutcome.UploadIncomplete:
                metrics.FloorSeed("upload_incomplete");
                return UploadIncomplete(result.LastSeq, $"Upload the floor's actions first (the server has up to seq {result.LastSeq}).");
            case FloorOutcome.Issued:
                await cache.InvalidateAsync(RunSummaryCache.SummaryKey(runId));
                metrics.FloorSeed("issued");
                metrics.StairsGate("open");
                break;
            default:
                metrics.FloorSeed("repeated");
                break;
        }

        return Results.Ok(new FloorSeedResponse(runId.ToString("D"), floor, result.FloorSeed.ToString()));
    }

    private static async Task<IResult> GetCurrentAsync(HttpContext context, RunStore store, RunSummaryCache cache,
        RpgMetrics metrics, CancellationToken ct)
    {
        var player = context.User.Player();
        if (await cache.GetCurrentAsync(player.Id) is { } cachedId
            && await ReadAsync(cachedId, store, cache, metrics, ct) is { } cached
            && cached.PlayerId == player.Id
            && cached.Summary.Status is RunStatus.Active or RunStatus.Verifying)
        {
            return Results.Ok(cached.Summary);
        }

        var current = await store.GetCurrentAsync(player.Id, ct);
        if (current is null)
        {
            return Results.NoContent();
        }

        await cache.SetCurrentAsync(player.Id, Guid.Parse(current.Summary.RunId));
        await cache.SetSummaryAsync(current);
        return Results.Ok(current.Summary);
    }

    private static async Task<IResult> GetRunAsync(HttpContext context, Guid runId, RunStore store,
        RunSummaryCache cache, RpgMetrics metrics, CancellationToken ct)
    {
        var player = context.User.Player();
        var run = await ReadAsync(runId, store, cache, metrics, ct);
        // Another player's run answers exactly like a missing one: no existence leak.
        return run is not null && run.PlayerId == player.Id ? Results.Ok(run.Summary) : NotFound(runId);
    }

    /// <summary>Cache-aside read: Redis, then Postgres (re-filling Redis). Counted by where the answer came from.</summary>
    internal static async Task<StoredRun?> ReadAsync(Guid runId, RunStore store, RunSummaryCache cache,
        RpgMetrics metrics, CancellationToken ct)
    {
        if (await cache.GetSummaryAsync(runId) is { } cached)
        {
            metrics.CacheRead("run", "redis");
            return cached;
        }

        var stored = await store.GetAsync(runId, ct);
        metrics.CacheRead("run", stored is null ? "missing" : "postgres");
        if (stored is not null)
        {
            await cache.SetSummaryAsync(stored);
        }

        return stored;
    }

    private static string? Invalid(RunStartRequest? request)
    {
        if (request is null)
        {
            return "A body is required.";
        }

        if (string.IsNullOrWhiteSpace(request.RulesetVersion) || request.RulesetVersion.Length > MaxIdLength)
        {
            return $"rulesetVersion is required (at most {MaxIdLength} characters).";
        }

        if (string.IsNullOrWhiteSpace(request.RunStructureId) || request.RunStructureId.Length > MaxIdLength)
        {
            return $"runStructureId is required (at most {MaxIdLength} characters).";
        }

        if (request.CharacterIds is not { Count: > 0 and <= MaxCharacters }
            || request.CharacterIds.Any(id => string.IsNullOrWhiteSpace(id) || id.Length > MaxIdLength))
        {
            return $"characterIds takes 1 to {MaxCharacters} non-empty ids.";
        }

        return null;
    }

    internal static IResult UploadIncomplete(int lastSeq, string detail) =>
        Results.Problem(statusCode: StatusCodes.Status409Conflict, title: "Upload incomplete", detail: detail,
            extensions: new Dictionary<string, object?> { ["errorCode"] = ApiErrors.UploadIncomplete, ["lastSeq"] = lastSeq });

    /// <summary>Spec run-verify 2.4: 409 1108. The client rebuilds from /resume; <c>reason</c> is a coarse category.</summary>
    internal static IResult RolledBack(int epoch, int verifiedSeq, string? reason) =>
        Conflict(ApiErrors.RunRolledBack, "Run rolled back",
            "The server rolled this run back to its last verified checkpoint; resume from the server.",
            new Dictionary<string, object?> { ["epoch"] = epoch, ["rollbackSeq"] = verifiedSeq, ["reason"] = reason });

    internal static IResult BadRequest(string detail) =>
        Results.Problem(statusCode: StatusCodes.Status400BadRequest, title: "Bad request", detail: detail);

    internal static IResult NotFound(Guid runId) =>
        Results.Problem(statusCode: StatusCodes.Status404NotFound, title: "Run not found", detail: $"No run {runId:D}.");

    internal static IResult Conflict(int errorCode, string title, string detail,
        IDictionary<string, object?>? extensions = null) =>
        Results.Problem(statusCode: StatusCodes.Status409Conflict, title: title, detail: detail,
            extensions: new Dictionary<string, object?>(extensions ?? new Dictionary<string, object?>())
            {
                ["errorCode"] = errorCode,
            });
}
