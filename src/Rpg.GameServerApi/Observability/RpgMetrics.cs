using System.Collections.Concurrent;
using System.Diagnostics.Metrics;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace Rpg.GameServerApi.Observability;

/// <summary>Custom instruments: rpg_build_info and rpg_dependency_health.</summary>
public sealed class RpgMetrics
{
    public const string MeterName = "Rpg.GameServerApi";

    private readonly ConcurrentDictionary<string, HealthStatus> _dependencyHealth = new();

    public RpgMetrics(IMeterFactory meterFactory, BuildInfo build)
    {
        var meter = meterFactory.Create(MeterName);

        meter.CreateObservableGauge("rpg.build_info",
            () => new Measurement<int>(1,
                new KeyValuePair<string, object?>("service", BuildInfo.ServiceName),
                new KeyValuePair<string, object?>("version", build.Version)),
            description: "Always 1; labels identify the running build.");

        meter.CreateObservableGauge("rpg.dependency_health",
            () => _dependencyHealth.Select(kv => new Measurement<double>(
                kv.Value switch
                {
                    HealthStatus.Healthy => 1.0,
                    HealthStatus.Degraded => 0.5,
                    _ => 0.0,
                },
                new KeyValuePair<string, object?>("dependency", kv.Key))),
            description: "1 healthy, 0.5 degraded, 0 unhealthy. Updated by the health-check publisher.");
    }

    public void SetDependencyHealth(string dependency, HealthStatus status) => _dependencyHealth[dependency] = status;
}

/// <summary>Feeds every health-check result into <see cref="RpgMetrics"/> (runs every 10 s).</summary>
public sealed class DependencyHealthPublisher(RpgMetrics metrics) : IHealthCheckPublisher
{
    public Task PublishAsync(HealthReport report, CancellationToken cancellationToken)
    {
        foreach (var (name, entry) in report.Entries)
        {
            metrics.SetDependencyHealth(name, entry.Status);
        }

        return Task.CompletedTask;
    }
}
