using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using Rpg.VerifierWorker;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddVerifierWorker();
// The host waits for the running jobs: the consumer's grace period (Verifier:ShutdownGrace) plus a margin.
builder.Services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(90));
builder.Services.AddOpenTelemetry()
    .ConfigureResource(r => r.AddService("rpg-verifier-worker", serviceInstanceId: Environment.MachineName))
    .WithMetrics(metrics => metrics
        .AddAspNetCoreInstrumentation()
        .AddMeter("System.Runtime")
        .AddMeter(WorkerMetrics.MeterName)
        .AddPrometheusExporter())
    .WithTracing(tracing =>
    {
        tracing
            .AddAspNetCoreInstrumentation(o => o.Filter = ctx =>
                !ctx.Request.Path.StartsWithSegments("/health") && !ctx.Request.Path.StartsWithSegments("/metrics"))
            .AddSource(VerifyProcessor.Source.Name)
            .AddSource("Npgsql");
        if (!string.IsNullOrWhiteSpace(builder.Configuration["OTEL_EXPORTER_OTLP_ENDPOINT"]))
        {
            tracing.AddOtlpExporter();
        }
    });

var app = builder.Build();

// Instantiate the instruments so they are registered before the first scrape.
app.Services.GetRequiredService<WorkerMetrics>();

app.MapPrometheusScrapingEndpoint().DisableHttpMetrics();
app.MapGet("/health/live", () => Results.Ok(new { status = "Healthy" }));
// Ready = the ruleset version is known, the schema is there and the consumers are attached (spec battle-verify 5).
app.MapGet("/health/ready", (WorkerState state) => state.Ready
    ? Results.Ok(new { status = "Healthy", ruleset = state.RulesetVersion })
    : Results.Json(new { status = "Unhealthy" }, statusCode: StatusCodes.Status503ServiceUnavailable));

app.Run();
