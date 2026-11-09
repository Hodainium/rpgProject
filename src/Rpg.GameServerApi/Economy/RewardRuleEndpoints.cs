using Microsoft.Extensions.Options;
using Npgsql;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Economy;
using Rpg.Economy;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Observability;

namespace Rpg.GameServerApi.Economy;

/// <summary>Configuration section <c>Economy</c> (spec economy-rewards 3.7).</summary>
public sealed class EconomyOptions
{
    public const string Section = "Economy";

    /// <summary>The most one rule can pay: a plain whole number (not x100).</summary>
    public int MaxRewardAmount { get; set; } = RewardRules.DefaultMaxAmount;

    /// <summary>Spec card-collection 3.5: the most a pack can cost in gems, and the most a craft can cost in dust.</summary>
    public int MaxPackPrice { get; set; } = 100_000;

    public int MaxCardCost { get; set; } = 100_000;

    /// <summary>Rewards applied at startup, only for challenges that have none yet (a demo or e2e starting point).</summary>
    public RewardRuleRequest[] SeedRules { get; set; } = [];
}

/// <summary>Applies <see cref="EconomyOptions.SeedRules"/> once the schema exists. An admin's version is never overwritten (F9).</summary>
public sealed class RewardRuleSeeder(NpgsqlDataSource dataSource, MigrationRunner migrations, IOptions<EconomyOptions> options,
    TimeProvider clock, ILogger<RewardRuleSeeder> logger) : BackgroundService
{
    private static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(5);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (options.Value.SeedRules.Length == 0)
        {
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await migrations.EnsureMigratedAsync(stoppingToken);
                var now = clock.GetUtcNow();
                foreach (var bad in options.Value.SeedRules.Where(r =>
                    RewardRules.Validate(r, options.Value.MaxRewardAmount, now) is not null || r.Amount == 0))
                {
                    logger.LogWarning("Seed reward rule skipped as invalid: {Id} {Currency} {Amount}",
                        bad.ChallengeId, bad.Currency, bad.Amount);
                }

                var created = await RewardRules.SeedAsync(dataSource, options.Value.SeedRules,
                    options.Value.MaxRewardAmount, now, stoppingToken);
                logger.LogInformation("Seeded {Count} reward rules", created);
                return;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning("Reward rules not seeded ({Message}); retrying in {Interval}", ex.Message, RetryInterval);
                await Task.Delay(RetryInterval, stoppingToken);
            }
        }
    }
}

/// <summary>The admin path for reward rules (spec economy-rewards 2.1, 3.6). Needs the <c>economy-admin</c> role on the token.</summary>
public static class RewardRuleEndpoints
{
    public static void MapRewardRuleEndpoints(this WebApplication app)
    {
        app.MapPut("/api/v1/admin/reward-rules", async (HttpContext context, RewardRuleRequest? request, NpgsqlDataSource data,
            MigrationRunner migrations, IOptions<EconomyOptions> options, TimeProvider clock, RpgMetrics metrics,
            CancellationToken ct) =>
        {
            if (!context.User.IsEconomyAdmin())
            {
                metrics.RewardRuleChange("forbidden");
                return Forbidden();
            }

            if (RewardRules.Validate(request, options.Value.MaxRewardAmount, clock.GetUtcNow()) is { } problem)
            {
                metrics.RewardRuleChange("invalid");
                return Results.Problem(statusCode: StatusCodes.Status400BadRequest, title: "Invalid reward rule",
                    detail: problem.Detail,
                    extensions: new Dictionary<string, object?> { ["errorCode"] = ApiErrors.RewardRuleInvalid });
            }

            await migrations.EnsureMigratedAsync(ct);
            var player = context.User.Player();
            var rule = await RewardRules.PutAsync(data, request!, player.Id, player.Name, clock.GetUtcNow(), ct);
            metrics.RewardRuleChange("ok");
            return Results.Ok(rule.ToResponse());
        }).RequireAuthorization();

        app.MapPost("/api/v1/admin/reward-cycles/reset", async (HttpContext context, RewardCycleResetRequest? request,
            NpgsqlDataSource data, MigrationRunner migrations, TimeProvider clock, RpgMetrics metrics, CancellationToken ct) =>
        {
            if (!context.User.IsEconomyAdmin())
            {
                metrics.RewardCycleReset("forbidden");
                return Forbidden();
            }

            if (RewardRules.ValidateReset(request) is { } problem)
            {
                metrics.RewardCycleReset("invalid");
                return Results.Problem(statusCode: StatusCodes.Status400BadRequest, title: "Invalid cycle reset",
                    detail: problem.Detail,
                    extensions: new Dictionary<string, object?> { ["errorCode"] = ApiErrors.RewardRuleInvalid });
            }

            await migrations.EnsureMigratedAsync(ct);
            var admin = context.User.Player();
            var reset = await RewardRules.ResetAsync(data, request!, admin.Id, admin.Name, clock.GetUtcNow(), ct);
            if (reset is null)
            {
                metrics.RewardCycleReset("unknown");
                return Results.Problem(statusCode: StatusCodes.Status404NotFound, title: "Reset target unknown",
                    detail: "The challenge has no reward rule, or the player does not exist.",
                    extensions: new Dictionary<string, object?> { ["errorCode"] = ApiErrors.RewardTargetUnknown });
            }

            metrics.RewardCycleReset("ok");
            return Results.Ok(reset);
        }).RequireAuthorization();

        app.MapGet("/api/v1/admin/reward-rules", async (HttpContext context, NpgsqlDataSource data, MigrationRunner migrations,
            RpgMetrics metrics, CancellationToken ct) =>
        {
            if (!context.User.IsEconomyAdmin())
            {
                metrics.RewardRuleChange("forbidden");
                return Forbidden();
            }

            await migrations.EnsureMigratedAsync(ct);
            var rules = await RewardRules.ListLatestAsync(data, ct);
            return Results.Ok(new RewardRuleListResponse([.. rules.Select(r => r.ToResponse())]));
        }).RequireAuthorization();
    }

    private static IResult Forbidden() =>
        Results.Problem(statusCode: StatusCodes.Status403Forbidden, title: "Economy admin required",
            detail: "This endpoint needs the economy-admin role.",
            extensions: new Dictionary<string, object?> { ["errorCode"] = ApiErrors.AdminRequired });
}
