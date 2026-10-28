using System.Collections.Concurrent;
using System.Diagnostics.Metrics;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace Rpg.GameServerApi.Observability;

/// <summary>
/// Custom instruments: rpg_build_info, rpg_dependency_health, and the run instruments of spec server-authority 5.
/// Labels are small fixed sets; never item, character, room or encounter ids.
/// </summary>
public sealed class RpgMetrics
{
    public const string MeterName = "Rpg.GameServerApi";

    private readonly ConcurrentDictionary<string, HealthStatus> _dependencyHealth = new();
    private readonly Counter<long> _runStarts;
    private readonly Counter<long> _floorSeeds;
    private readonly Counter<long> _cacheReads;
    private readonly Counter<long> _cacheErrors;
    private long _runsInProgress = -1;

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

        _runStarts = meter.CreateCounter<long>("rpg.run_starts", description: "Run starts by result.");
        _floorSeeds = meter.CreateCounter<long>("rpg.floor_seeds", description: "Floor seed requests by result.");
        _cacheReads = meter.CreateCounter<long>("rpg.cache_reads",
            description: "Read-model reads by entity and where the answer came from.");
        _cacheErrors = meter.CreateCounter<long>("rpg.cache_errors",
            description: "Redis operations that failed and fell back (reads) or were skipped (deletes).");
        meter.CreateObservableGauge("rpg.runs_in_progress",
            () => Interlocked.Read(ref _runsInProgress) is var count and >= 0
                ? [new Measurement<long>(count)]
                : Array.Empty<Measurement<long>>(),
            description: "Runs with status Active, recomputed every 30 s from Postgres.");
    }

    /// <summary>result: created | abandoned_previous | rejected.</summary>
    public void RunStart(string result) => _runStarts.Add(1, new KeyValuePair<string, object?>("result", result));

    /// <summary>result: issued | repeated | not_reachable | upload_incomplete.</summary>
    public void FloorSeed(string result) => _floorSeeds.Add(1, new KeyValuePair<string, object?>("result", result));

    /// <summary>entity: run | battle; source: redis | postgres | missing.</summary>
    public void CacheRead(string entity, string source) => _cacheReads.Add(1,
        new KeyValuePair<string, object?>("entity", entity), new KeyValuePair<string, object?>("source", source));

    /// <summary>operation: get | set | delete | zadd | ratelimit.</summary>
    public void CacheError(string operation) =>
        _cacheErrors.Add(1, new KeyValuePair<string, object?>("operation", operation));

    /// <summary>Set by <c>RunsInProgressMonitor</c>; nothing is exported until the first count arrives.</summary>
    public void SetRunsInProgress(long count) => Interlocked.Exchange(ref _runsInProgress, count);

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
