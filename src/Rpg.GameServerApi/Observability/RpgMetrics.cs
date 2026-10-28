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
    private readonly Counter<long> _runActions;
    private readonly Histogram<int> _batchSize;
    private readonly Histogram<double> _uploadLag;
    private readonly Histogram<double> _actionDuration;
    private readonly Counter<long> _battlesSubmitted;
    private readonly Counter<long> _runEnds;
    private readonly Counter<long> _rateLimited;
    private readonly Counter<long> _devTokens;
    private long _runsInProgress = -1;
    private long _playersOnline = -1;
    private long _playersInBattle = -1;

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

        // Part B (spec server-authority 5).
        _runActions = meter.CreateCounter<long>("rpg.run_actions", description: "Uploaded run actions by type and result.");
        _batchSize = meter.CreateHistogram<int>("rpg.run_action_batch_size", description: "Actions per upload request.",
            advice: new InstrumentAdvice<int> { HistogramBucketBoundaries = [1, 2, 5, 10, 20, 30, 40, 50] });
        _uploadLag = meter.CreateHistogram<double>("rpg.run_action_upload_lag", unit: "s",
            description: "Received minus played: how long players played offline before syncing.",
            advice: new InstrumentAdvice<double>
            {
                HistogramBucketBoundaries = [0.1, 0.5, 1, 5, 15, 60, 300, 900, 3600, 21600, 86400],
            });
        _actionDuration = meter.CreateHistogram<double>("rpg.run_action_duration", unit: "s",
            description: "Time to store one upload request.");
        _battlesSubmitted = meter.CreateCounter<long>("rpg.battles_submitted", description: "Battle sessions stored.");
        _runEnds = meter.CreateCounter<long>("rpg.run_ends", description: "Run ends by status.");
        _rateLimited = meter.CreateCounter<long>("rpg.rate_limited", description: "Requests refused with 429 by bucket.");
        _devTokens = meter.CreateCounter<long>("rpg.dev_tokens_issued", description: "Development tokens issued.");
        meter.CreateObservableGauge("rpg.players_online",
            () => Interlocked.Read(ref _playersOnline) is var count and >= 0
                ? [new Measurement<long>(count)]
                : Array.Empty<Measurement<long>>(),
            description: "Players seen in the last 5 minutes (presence:online).");
        meter.CreateObservableGauge("rpg.players_in_battle",
            () => Interlocked.Read(ref _playersInBattle) is var count and >= 0
                ? [new Measurement<long>(count)]
                : Array.Empty<Measurement<long>>(),
            description: "Players whose heartbeat said Battle in the last 2 minutes (a client hint).");
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

    /// <summary>type: a <c>RunActionTypes</c> value; result: accepted | duplicate | gap | conflict | inactive.</summary>
    public void RunAction(string type, string result) => _runActions.Add(1,
        new KeyValuePair<string, object?>("type", type), new KeyValuePair<string, object?>("result", result));

    public void RunActionBatch(int size, TimeSpan duration)
    {
        _batchSize.Record(size);
        _actionDuration.Record(duration.TotalSeconds);
    }

    public void UploadLag(TimeSpan lag) => _uploadLag.Record(Math.Max(0, lag.TotalSeconds));

    public void BattleSubmitted() => _battlesSubmitted.Add(1);

    /// <summary>status: won | lost | auto_approved.</summary>
    public void RunEnd(string status) => _runEnds.Add(1, new KeyValuePair<string, object?>("status", status));

    /// <summary>bucket: actions | runs | floors.</summary>
    public void RateLimited(string bucket) => _rateLimited.Add(1, new KeyValuePair<string, object?>("bucket", bucket));

    public void DevTokenIssued() => _devTokens.Add(1);

    /// <summary>Set by <c>PresenceMonitor</c>; kept (stale, not zero) while Redis is down.</summary>
    public void SetPresence(long online, long inBattle)
    {
        Interlocked.Exchange(ref _playersOnline, online);
        Interlocked.Exchange(ref _playersInBattle, inBattle);
    }

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
