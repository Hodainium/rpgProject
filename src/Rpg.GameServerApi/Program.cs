using Microsoft.Extensions.Diagnostics.HealthChecks;
using Npgsql;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Health;
using Rpg.GameServerApi.Infrastructure;
using Rpg.GameServerApi.Observability;

var builder = WebApplication.CreateBuilder(args);
var buildInfo = new BuildInfo();

builder.Services.AddSingleton(buildInfo);
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.ConfigureHttpJsonOptions(o => RpgJson.Apply(o.SerializerOptions));
builder.Services.AddProblemDetails();

// Dependencies. None of these connect during startup, so the server starts even when the stack is down.
builder.Services.AddSingleton(sp => NpgsqlDataSource.Create(
    sp.GetRequiredService<IConfiguration>().GetConnectionString("Postgres")
    ?? throw new InvalidOperationException("ConnectionStrings:Postgres is not configured.")));
builder.Services.AddSingleton<RedisConnection>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<RedisConnection>());
builder.Services.AddSingleton<RabbitMqConnection>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<RabbitMqConnection>());

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
            .AddHttpClientInstrumentation();
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

app.Run();

/// <summary>Entry point; public so WebApplicationFactory can host it in tests.</summary>
public partial class Program;
