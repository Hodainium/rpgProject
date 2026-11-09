using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;
using Npgsql;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Battle;
using Rpg.GameServerApi.Cards;
using Rpg.GameServerApi.Economy;
using Rpg.GameServerApi.Health;
using Rpg.GameServerApi.Infrastructure;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.Outbox;
using Rpg.GameServerApi.Presence;
using Rpg.GameServerApi.RateLimiting;
using Rpg.GameServerApi.Runs;

var builder = WebApplication.CreateBuilder(args);
// Spec economy-rewards 8.1: Economy:SeedFile names a JSON file shaped like configuration (Economy:SeedRules), loaded last.
if (builder.Configuration["Economy:SeedFile"] is { Length: > 0 } seedFile)
{
    builder.Configuration.AddJsonFile(Path.GetFullPath(seedFile, builder.Environment.ContentRootPath), optional: false);
}

var buildInfo = new BuildInfo();

builder.Services.AddSingleton(buildInfo);
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.ConfigureHttpJsonOptions(o => RpgJson.Apply(o.SerializerOptions));
builder.Services.AddProblemDetails();
builder.Services.AddExceptionHandler<PostgresUnavailableHandler>();
// A malformed body is a 400 ProblemDetails in every environment (Development would otherwise throw).
builder.Services.Configure<RouteHandlerOptions>(o => o.ThrowOnBadRequest = false);

// Dependencies. None of these connect during startup, so the server starts even when the stack is down.
builder.Services.AddSingleton(sp => NpgsqlDataSource.Create(
    sp.GetRequiredService<IConfiguration>().GetConnectionString("Postgres")
    ?? throw new InvalidOperationException("ConnectionStrings:Postgres is not configured.")));
builder.Services.AddSingleton<RedisConnection>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<RedisConnection>());
builder.Services.AddSingleton<RabbitMqConnection>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<RabbitMqConnection>());

// Runs (spec server-authority Part A). Migrations run in the background and again before the first query.
builder.Services.AddOptions<SeedOptions>().BindConfiguration(SeedOptions.Section)
    .Validate(o => o.Secret.Length >= 32, "Seeds:Secret must be at least 32 characters (user-secrets in development).")
    .ValidateOnStart();
builder.Services.AddOptions<RulesetOptions>().BindConfiguration(RulesetOptions.Section);
builder.Services.AddSingleton<MigrationRunner>();
builder.Services.AddHostedService<StartupMigration>();
builder.Services.AddSingleton<FloorSeeds>();
builder.Services.AddSingleton<RulesetPolicy>();
builder.Services.AddSingleton<RunStore>();
builder.Services.AddSingleton<RunSummaryCache>();
builder.Services.AddOptions<MonitorOptions>().BindConfiguration(MonitorOptions.Section);
builder.Services.AddHostedService<RunsInProgressMonitor>();

// Part B: bearer tokens, the action log, battle sessions, presence and rate limits.
builder.Services.AddOptions<AuthOptions>().BindConfiguration(AuthOptions.Section)
    .Validate(o => o.SigningKey.Length >= 32, "Auth:SigningKey must be at least 32 characters (user-secrets in development).")
    .ValidateOnStart();
builder.Services.AddSingleton<DevTokenIssuer>();
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer();
builder.Services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
    .Configure<IOptions<AuthOptions>>((jwt, auth) =>
    {
        jwt.MapInboundClaims = false;  // keep "sub" and "name" as issued
        jwt.TokenValidationParameters = new TokenValidationParameters
        {
            ValidIssuer = AuthOptions.Issuer,
            ValidAudience = AuthOptions.Audience,
            IssuerSigningKey = auth.Value.Key(),
            ValidAlgorithms = [SecurityAlgorithms.HmacSha256],
            ClockSkew = TimeSpan.FromSeconds(30),
        };
    });
builder.Services.AddAuthorization();
builder.Services.AddOptions<RunOptions>().BindConfiguration(RunOptions.Section);
builder.Services.AddOptions<Rpg.Economy.RunVerifyOptions>().BindConfiguration(Rpg.Economy.RunVerifyOptions.Section);
builder.Services.AddSingleton<BattleSessionCache>();
// Slice 3 (spec battle-verify): the queue and backlog gauges. Slice 4 (spec settlement-outbox): the outbox relay carries
// verify jobs to RabbitMQ and domain events to Redpanda; the wallet read model.
builder.Services.AddSingleton<BattleVerifyMonitor>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<BattleVerifyMonitor>());
builder.Services.AddOptions<OutboxOptions>().BindConfiguration(OutboxOptions.Section);
builder.Services.AddOptions<KafkaOptions>().BindConfiguration(KafkaOptions.Section);
builder.Services.AddSingleton<OutboxStore>();
builder.Services.AddSingleton<IOutboxSink, RabbitOutboxSink>();
builder.Services.AddSingleton<IOutboxSink, KafkaOutboxSink>();
builder.Services.AddSingleton<OutboxRelay>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<OutboxRelay>());
builder.Services.AddSingleton<OutboxMonitor>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<OutboxMonitor>());
builder.Services.AddOptions<EconomyOptions>().BindConfiguration(EconomyOptions.Section);
builder.Services.AddHostedService<RewardRuleSeeder>();
builder.Services.AddSingleton<WalletStore>();
// Spec card-collection: the card catalog, the account's cards, pack opening, dust and craft.
builder.Services.AddOptions<CardOptions>().BindConfiguration(CardOptions.Section);
builder.Services.AddSingleton<Rpg.Economy.Cards.CardStore>();
builder.Services.AddSingleton<CatalogCache>();
builder.Services.AddHostedService<CardSeeder>();
builder.Services.AddHostedService<CardsOwnedMonitor>();
builder.Services.AddSingleton<WalletCache>();
builder.Services.AddSingleton<PresenceTracker>();
builder.Services.AddHostedService<PresenceMonitor>();
builder.Services.AddOptions<RateLimitOptions>().BindConfiguration(RateLimitOptions.Section);
builder.Services.AddSingleton<RateLimiter>();

// Readiness policy (spec project-skeleton, section 4): Postgres and RabbitMQ are required, Redis only degrades.
string[] ready = [HealthEndpoints.ReadyTag];
builder.Services.AddHealthChecks()
    .AddCheck<PostgresHealthCheck>("postgres", HealthStatus.Unhealthy, ready, TimeSpan.FromSeconds(2))
    .AddCheck<RedisHealthCheck>("redis", HealthStatus.Degraded, ready, TimeSpan.FromSeconds(1))
    .AddCheck<RabbitMqHealthCheck>("rabbitmq", HealthStatus.Unhealthy, ready, TimeSpan.FromSeconds(1));
builder.Services.Configure<HealthCheckPublisherOptions>(o =>
{
    o.Delay = TimeSpan.FromSeconds(2);
    o.Period = TimeSpan.FromSeconds(10);
});
builder.Services.AddSingleton<RpgMetrics>();
builder.Services.AddSingleton<IHealthCheckPublisher, DependencyHealthPublisher>();

builder.Services.AddOpenTelemetry()
    .ConfigureResource(r => r.AddService(BuildInfo.ServiceName, serviceVersion: buildInfo.Version))
    .WithMetrics(metrics => metrics
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddMeter("System.Runtime")
        .AddMeter(RpgMetrics.MeterName)
        .AddPrometheusExporter())
    .WithTracing(tracing =>
    {
        tracing
            .AddAspNetCoreInstrumentation(o => o.Filter = ctx =>
                !ctx.Request.Path.StartsWithSegments("/health") && !ctx.Request.Path.StartsWithSegments("/metrics"))
            .AddHttpClientInstrumentation()
            .AddSource(OutboxRelay.Source.Name)
            .AddSource("Npgsql")  // Npgsql's built-in ActivitySource
            // Spec server-authority 5: Redis spans. The multiplexer connects in the background, so attach it then.
            .AddRedisInstrumentation()
            .ConfigureRedisInstrumentation((sp, instrumentation) =>
                sp.GetRequiredService<RedisConnection>().WhenConnected(m => instrumentation.AddConnection(m)));
        // No trace backend in compose yet (slice 6); export only when an OTLP endpoint is configured.
        if (!string.IsNullOrWhiteSpace(builder.Configuration["OTEL_EXPORTER_OTLP_ENDPOINT"]))
        {
            tracing.AddOtlpExporter();
        }
    });

var app = builder.Build();

// Instantiate the custom instruments so they are registered before the first scrape.
app.Services.GetRequiredService<RpgMetrics>();

app.UseExceptionHandler();
app.UseStatusCodePages();
app.UseAuthentication();
app.UseAuthorization();
app.UsePresence();

app.MapHealthEndpoints();
app.MapPrometheusScrapingEndpoint().DisableHttpMetrics();

app.MapGet("/api/v1/info", (BuildInfo build, TimeProvider clock) =>
    new ServerInfoResponse(BuildInfo.ServiceName, build.Version, clock.GetUtcNow()));
app.MapAuthEndpoints();
app.MapRunEndpoints();
app.MapWalletEndpoints();
app.MapRewardRuleEndpoints();
app.MapCardEndpoints();
app.MapPresenceEndpoints();

app.Run();

/// <summary>Entry point; public so WebApplicationFactory can host it in tests.</summary>
public partial class Program;
