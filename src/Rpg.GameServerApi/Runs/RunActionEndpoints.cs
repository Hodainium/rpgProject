using System.Diagnostics;
using System.Text.Json;
using Microsoft.Extensions.Options;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Runs;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Battle;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.RateLimiting;

namespace Rpg.GameServerApi.Runs;

/// <summary>Configuration section <c>Run</c>.</summary>
public sealed class RunOptions
{
    public const string Section = "Run";

    /// <summary>Development only, until slice 4a verifies runs: a won run becomes Won at once instead of Verifying.</summary>
    public bool AutoApproveWins { get; set; }
}

/// <summary>
/// Part B run endpoints (spec server-authority 2.2–2.4, 3.2): the action log upload, the run's end, resume without a
/// save, and battle sessions. The server stores claims; it never checks them against game rules (slices 3 and 4a).
/// </summary>
public static class RunActionEndpoints
{
    public const int MaxBatch = 50;
    public const int MaxHashLength = 128;
    public const int MaxBattleIdLength = 256;

    public static void MapRunActionEndpoints(this RouteGroupBuilder runs)
    {
        runs.MapPost("/{runId:guid}/actions", SendActionsAsync).RateLimited(RateLimitOptions.Actions);
        runs.MapPost("/{runId:guid}/end", EndRunAsync);
        runs.MapGet("/{runId:guid}/resume", ResumeAsync);
        runs.MapGet("/{runId:guid}/battles/{seq:int}", GetBattleAsync);
    }

    private static async Task<IResult> SendActionsAsync(HttpContext context, Guid runId, RunActionBatch? batch,
        RunStore store, RunSummaryCache cache, RpgMetrics metrics, TimeProvider clock, CancellationToken ct)
    {
        var started = Stopwatch.GetTimestamp();
        var player = context.User.Player();
        Activity.Current?.SetTag("rpg.run_id", runId.ToString("D"));
        if (Invalid(runId, batch) is { } problem)
        {
            return RunEndpoints.BadRequest(problem);
        }

        var now = clock.GetUtcNow();
        var result = await store.AppendAsync(player.Id, runId, batch!.Actions, now, ct);
        foreach (var (type, outcome) in result.Counted)
        {
            metrics.RunAction(type, outcome);
        }

        metrics.RunActionBatch(batch.Actions.Count, Stopwatch.GetElapsedTime(started));
        switch (result.Outcome)
        {
            case AppendOutcome.NotFound:
                return RunEndpoints.NotFound(runId);
            case AppendOutcome.NotActive:
                return RunEndpoints.Conflict(ApiErrors.RunNotActive, "Run not active", $"Run {runId:D} has ended.");
            case AppendOutcome.Gap:
                return RunEndpoints.Conflict(ApiErrors.SequenceGap, "Sequence gap",
                    $"The next action must be seq {result.ExpectedSeq}.",
                    new Dictionary<string, object?> { ["expectedSeq"] = result.ExpectedSeq });
            case AppendOutcome.Conflict:
                return RunEndpoints.Conflict(ApiErrors.SequenceConflict, "Sequence conflict",
                    "A stored action has the same seq and a different body; the server's log wins.",
                    new Dictionary<string, object?> { ["lastSeq"] = result.LastSeq });
        }

        // Counted has one entry per action, in batch order.
        foreach (var (action, (_, outcome)) in batch.Actions.Zip(result.Counted))
        {
            if (outcome == "accepted")
            {
                metrics.UploadLag(now - action.PlayedAt);
            }
        }

        for (var i = 0; i < result.Battles; i++)
        {
            metrics.BattleSubmitted();
        }

        if (result.Ended)
        {
            metrics.RunEnd("lost");
            await cache.InvalidateAsync(RunSummaryCache.SummaryKey(runId), RunSummaryCache.CurrentKey(player.Id));
        }
        else if (result.Counted.Any(c => c.Result == "accepted"))
        {
            await cache.InvalidateAsync(RunSummaryCache.SummaryKey(runId));
        }

        return Results.Ok(new RunActionAck(result.LastSeq));
    }

    private static async Task<IResult> EndRunAsync(HttpContext context, Guid runId, RunEndRequest? request,
        RunStore store, RunSummaryCache cache, RpgMetrics metrics, IOptions<RunOptions> options,
        IHostEnvironment environment, TimeProvider clock, CancellationToken ct)
    {
        var player = context.User.Player();
        Activity.Current?.SetTag("rpg.run_id", runId.ToString("D"));
        if (request is null || request.Seq < 1 || !Enum.IsDefined(request.Status)
            || string.IsNullOrWhiteSpace(request.RunHash) || request.RunHash.Length > MaxHashLength
            || InvalidSnapshot(request.Snapshot) is not null)
        {
            return RunEndpoints.BadRequest(
                $"seq (≥ 1), status (Won or Lost), runHash (at most {MaxHashLength} characters) and a snapshot " +
                "(a JSON object with schemaVersion 1) are required.");
        }

        var autoApprove = options.Value.AutoApproveWins && environment.IsDevelopment();
        var result = await store.EndAsync(player.Id, runId, request, autoApprove, clock.GetUtcNow(), ct);
        switch (result.Outcome)
        {
            case EndOutcome.NotFound:
                return RunEndpoints.NotFound(runId);
            case EndOutcome.NotActive:
                return RunEndpoints.Conflict(ApiErrors.RunNotActive, "Run not active",
                    $"Run {runId:D} is {result.Status}.");
            case EndOutcome.UploadIncomplete:
                return RunEndpoints.UploadIncomplete(result.LastSeq,
                    $"The end must be seq {result.LastSeq + 1}: upload the rest of the log first.");
            case EndOutcome.Conflict:
                return RunEndpoints.Conflict(ApiErrors.SequenceConflict, "Sequence conflict",
                    $"Seq {request.Seq} is already stored with a different body.",
                    new Dictionary<string, object?> { ["lastSeq"] = result.LastSeq });
            case EndOutcome.Ended:
                metrics.RunEnd(request.Status == RunEndStatus.Lost ? "lost" : "won");
                if (result.Status == RunStatus.Won)
                {
                    metrics.RunEnd("auto_approved");
                }

                await cache.InvalidateAsync(RunSummaryCache.SummaryKey(runId), RunSummaryCache.CurrentKey(player.Id));
                break;
        }

        var response = new RunEndResponse(runId.ToString("D"), result.Status);
        return result.Status == RunStatus.Verifying
            ? Results.Accepted($"/api/v1/runs/{response.RunId}", response)
            : Results.Ok(response);
    }

    private static async Task<IResult> ResumeAsync(HttpContext context, Guid runId, RunStore store, CancellationToken ct)
    {
        var result = await store.ResumeAsync(context.User.Player().Id, runId, ct);
        return result.Outcome switch
        {
            ResumeOutcome.Found => Results.Ok(result.Response),
            ResumeOutcome.NotActive => RunEndpoints.Conflict(ApiErrors.RunNotActive, "Run not active",
                $"Run {runId:D} can't be resumed."),
            _ => RunEndpoints.NotFound(runId),
        };
    }

    private static async Task<IResult> GetBattleAsync(HttpContext context, Guid runId, int seq, RunStore store,
        BattleSessionCache cache, RpgMetrics metrics, CancellationToken ct)
    {
        var player = context.User.Player();
        var battle = await cache.GetAsync(runId, seq);
        if (battle is not null)
        {
            metrics.CacheRead("battle", "redis");
        }
        else
        {
            battle = await store.GetBattleAsync(runId, seq, ct);
            metrics.CacheRead("battle", battle is null ? "missing" : "postgres");
            if (battle is not null)
            {
                await cache.SetAsync(runId, seq, battle);
            }
        }

        // Another player's battle answers exactly like a missing one.
        return battle is not null && battle.PlayerId == player.Id
            ? Results.Ok(battle.Session)
            : Results.Problem(statusCode: StatusCodes.Status404NotFound, title: "Battle not found",
                detail: $"No battle at seq {seq} of run {runId:D}.");
    }

    /// <summary>The 400 checks (2.2): shape only, never game rules.</summary>
    private static string? Invalid(Guid runId, RunActionBatch? batch)
    {
        if (batch?.Actions is not { Count: > 0 and <= MaxBatch } actions)
        {
            return $"actions takes 1 to {MaxBatch} actions.";
        }

        for (var i = 0; i < actions.Count; i++)
        {
            var request = actions[i];
            if (request?.Action is not { } action)
            {
                return $"actions[{i}] needs an action.";
            }

            if (request.Seq < 1 || (i > 0 && request.Seq != actions[i - 1].Seq + 1))
            {
                return "seqs start at 1 and are consecutive within a batch.";
            }

            if (!RunActionTypes.All.Contains(action.Type) || action.Floor < 0)
            {
                return $"seq {request.Seq}: unknown type '{action.Type}' or a negative floor.";
            }

            if (string.IsNullOrWhiteSpace(request.StateHash) || request.StateHash.Length > MaxHashLength)
            {
                return $"seq {request.Seq}: stateHash is required (at most {MaxHashLength} characters).";
            }

            if (request.Snapshot is { } snapshot && InvalidSnapshot(snapshot) is { } bad)
            {
                return $"seq {request.Seq}: {bad}";
            }

            if (request.Snapshot is null && RunActionTypes.Checkpoints.Contains(action.Type))
            {
                return $"seq {request.Seq}: a {action.Type} action is a checkpoint and needs a snapshot.";
            }

            if (action.Type == RunActionTypes.End && i != actions.Count - 1)
            {
                return "an end action must be the last of its batch.";
            }

            if ((action.Type == RunActionTypes.Battle) != (action.Battle is not null))
            {
                return $"seq {request.Seq}: battle actions, and only they, carry a battle.";
            }

            if (action.Battle is { } battle
                && (battle.BattleId is not { Length: > 0 and <= MaxBattleIdLength }
                    || !battle.BattleId.StartsWith($"{runId:D}/", StringComparison.Ordinal)
                    || battle.Conditions is null || battle.ActionLog is null
                    || battle.Conditions.BattleId != battle.BattleId
                    || !long.TryParse(battle.Conditions.Seed, out var seed) || seed < 0))
            {
                return $"seq {request.Seq}: a battle needs an id under this run, conditions with the same id and a " +
                       "non-negative int64 seed, and an action log.";
            }
        }

        return null;
    }

    /// <summary>Snapshots are opaque (3.1): only "a JSON object with schemaVersion 1" is checked.</summary>
    private static string? InvalidSnapshot(JsonElement snapshot) =>
        snapshot.ValueKind == JsonValueKind.Object
        && snapshot.TryGetProperty("schemaVersion", out var version)
        && version.ValueKind == JsonValueKind.Number && version.TryGetInt32(out var number) && number == 1
            ? null
            : "the snapshot must be a JSON object with schemaVersion 1.";
}
