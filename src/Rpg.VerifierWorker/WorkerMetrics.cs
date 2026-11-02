using System.Diagnostics.Metrics;
using Rpg.Contracts.Battle;

namespace Rpg.VerifierWorker;

/// <summary>
/// The worker's instruments (spec battle-verify 5). Labels are small fixed sets: never battle, run, player, character or
/// ability ids.
/// </summary>
public sealed class WorkerMetrics
{
    public const string MeterName = "Rpg.VerifierWorker";

    private readonly Counter<long> _jobs;
    private readonly Counter<long> _rejections;
    private readonly Counter<long> _locks;
    private readonly Counter<long> _cacheErrors;
    private readonly Histogram<double> _replayDuration;
    private readonly Histogram<double> _latency;
    private readonly Histogram<double> _godotCpu;
    private readonly Histogram<double> _godotMemory;

    public WorkerMetrics(IMeterFactory meterFactory)
    {
        var meter = meterFactory.Create(MeterName);
        _jobs = meter.CreateCounter<long>("rpg.verify_jobs", description: "Verify jobs handled, by result.");
        _rejections = meter.CreateCounter<long>("rpg.battle_rejections", description: "Rejected battles by mismatch reason.");
        _locks = meter.CreateCounter<long>("rpg.verify_lock", description: "Dedup lock attempts by result.");
        _cacheErrors = meter.CreateCounter<long>("rpg.cache_errors", description: "Redis operations that failed and were skipped.");
        _replayDuration = meter.CreateHistogram<double>("rpg.verify_replay_duration", unit: "s",
            description: "Time of the Godot process, by result.",
            advice: new InstrumentAdvice<double> { HistogramBucketBoundaries = [0.5, 1, 2, 5, 10, 20, 40, 60] });
        _latency = meter.CreateHistogram<double>("rpg.verify_latency", unit: "s",
            description: "Submitted to verdict committed.",
            advice: new InstrumentAdvice<double>
            {
                HistogramBucketBoundaries = [1, 2, 5, 10, 30, 60, 120, 300, 900],
            });
        _godotCpu = meter.CreateHistogram<double>("rpg.verify_godot_cpu_time", unit: "s",
            description: "CPU time (user + system) of one Godot replay process.",
            advice: new InstrumentAdvice<double> { HistogramBucketBoundaries = [0.5, 1, 2, 5, 10, 20, 40, 60] });
        _godotMemory = meter.CreateHistogram<double>("rpg.verify_godot_peak_memory", unit: "By",
            description: "Peak working set of one Godot replay process.",
            advice: new InstrumentAdvice<double>
            {
                HistogramBucketBoundaries = [64e6, 128e6, 256e6, 384e6, 512e6, 768e6, 1024e6, 2048e6],
            });
    }

    /// <summary>What one Godot replay cost, by result (verified | rejected | error), when it could be sampled.</summary>
    public void GodotUsage(string result, ReplayUsage? usage)
    {
        if (usage is null)
        {
            return;
        }

        var tag = new KeyValuePair<string, object?>("result", result);
        _godotCpu.Record(usage.CpuTime.TotalSeconds, tag);
        _godotMemory.Record(usage.PeakMemoryBytes, tag);
    }

    /// <summary>result: verified | rejected | duplicate | retry | dead_lettered | wrong_ruleset | lock_busy.</summary>
    public void Job(string result) => _jobs.Add(1, new KeyValuePair<string, object?>("result", result));

    public void Rejection(MismatchReason reason) =>
        _rejections.Add(1, new KeyValuePair<string, object?>("reason", reason.ToString()));

    /// <summary>result: acquired | busy | redis_error.</summary>
    public void Lock(string result) => _locks.Add(1, new KeyValuePair<string, object?>("result", result));

    /// <summary>operation: set | lock.</summary>
    public void CacheError(string operation) =>
        _cacheErrors.Add(1, new KeyValuePair<string, object?>("operation", operation));

    /// <summary>result: verified | rejected | error.</summary>
    public void ReplayDuration(string result, TimeSpan duration) =>
        _replayDuration.Record(duration.TotalSeconds, new KeyValuePair<string, object?>("result", result));

    public void Latency(TimeSpan latency) => _latency.Record(Math.Max(0, latency.TotalSeconds));
}
