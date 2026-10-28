using Microsoft.Extensions.Diagnostics.HealthChecks;
using Npgsql;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Health;
using Rpg.GameServerApi.Infrastructure;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.Runs;

var builder = WebApplication.CreateBuilder(args);
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
builder.Services.AddHostedService<RunsInProgressMonitor>();

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

app.MapHealthEndpoints();
app.MapPrometheusScrapingEndpoint().DisableHttpMetrics();

app.MapGet("/api/v1/info", (BuildInfo build, TimeProvider clock) =>
    new ServerInfoResponse(BuildInfo.ServiceName, build.Version, clock.GetUtcNow()));
app.MapRunEndpoints();

app.Run();

/// <summary>Entry point; public so WebApplicationFactory can host it in tests.</summary>
public partial class Program;
