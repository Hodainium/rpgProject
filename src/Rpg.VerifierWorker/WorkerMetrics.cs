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
    private readonly Counter<long> _settlements;
    private readonly Counter<long> _gems;
    private readonly Counter<long> _ruleLookups;
    private readonly Counter<long> _marks;
    private readonly Counter<long> _cacheErrors;
    private readonly Histogram<double> _replayDuration;
    private readonly Histogram<double> _latency;
    private readonly Histogram<double> _godotCpu;
    private readonly Histogram<double> _godotMemory;
    // Spec run-verify 5.
    private readonly Counter<long> _stepJobs;
    private readonly Counter<long> _stepMismatches;
    private readonly Counter<long> _fanin;
    private readonly Counter<long> _floorsVerified;
    private readonly Counter<long> _runVerdicts;
    private readonly Counter<long> _rollbacks;
    private readonly Counter<long> _ledgerTransitions;
    private readonly Counter<long> _antiCheat;
    private readonly Histogram<double> _stepDuration;
    private readonly Histogram<double> _stepWait;

    public WorkerMetrics(IMeterFactory meterFactory)
    {
        var meter = meterFactory.Create(MeterName);
        _stepJobs = meter.CreateCounter<long>("rpg.step_jobs", description: "Step jobs handled, by result (spec run-verify 5).");
        _stepMismatches = meter.CreateCounter<long>("rpg.step_mismatches", description: "Rejected steps by mismatch reason.");
        _fanin = meter.CreateCounter<long>("rpg.fanin", description: "Aggregator runs by result.");
        _floorsVerified = meter.CreateCounter<long>("rpg.floor_verified", description: "Floors whose log became verified.");
        _runVerdicts = meter.CreateCounter<long>("rpg.run_verdicts", description: "Runs the verifier decided, by result (won | rejected).");
        _rollbacks = meter.CreateCounter<long>("rpg.run_rollbacks", description: "Runs rolled back or ended by the verifier, by reason and terminal.");
        _ledgerTransitions = meter.CreateCounter<long>("rpg.ledger_transitions", description: "Ledger rows moved to released or voided.");
        _antiCheat = meter.CreateCounter<long>("rpg.anticheat_events", description: "Anti-cheat alerts written, by kind.");
        _stepDuration = meter.CreateHistogram<double>("rpg.step_duration", unit: "s",
            description: "Time of the Godot process of one step, by kind.",
            advice: new InstrumentAdvice<double> { HistogramBucketBoundaries = [0.5, 1, 2, 5, 10, 20, 40, 90] });
        _stepWait = meter.CreateHistogram<double>("rpg.step_queue_wait", unit: "s",
            description: "A step's creation to its verdict committed.",
            advice: new InstrumentAdvice<double> { HistogramBucketBoundaries = [1, 2, 5, 10, 30, 60, 120, 300, 900] });
        _jobs = meter.CreateCounter<long>("rpg.verify_jobs", description: "Verify jobs handled, by result.");
        _rejections = meter.CreateCounter<long>("rpg.battle_rejections", description: "Rejected battles by mismatch reason.");
        _settlements = meter.CreateCounter<long>("rpg.settlements", description: "Settlements by result (spec settlement-outbox 5).");
        _gems = meter.CreateCounter<long>("rpg.gems_granted", description: "Gems granted, by reason.");
        _marks = meter.CreateCounter<long>("rpg.completion_marks", description: "Completion marks a settlement touched, by result (spec economy-challenges 5).");
        _ruleLookups = meter.CreateCounter<long>("rpg.reward_rule_lookups", description: "Reward-rule lookups per beaten boss, by result (spec economy-rewards 5).");
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

    /// <summary>result: verified | rejected | duplicate | retry | dead_lettered | wrong_ruleset.</summary>
    public void Job(string result) => _jobs.Add(1, new KeyValuePair<string, object?>("result", result));

    public void Rejection(MismatchReason reason) =>
        _rejections.Add(1, new KeyValuePair<string, object?>("reason", reason.ToString()));

    /// <summary>result: new | existing.</summary>
    public void CompletionMarks(string result, int count)
    {
        if (count > 0)
        {
            _marks.Add(count, new KeyValuePair<string, object?>("result", result));
        }
    }

    /// <summary>result: found | missing | retired | expired. A rising missing count means a boss without a reward rule.</summary>
    public void RewardRuleLookups(string result, int count)
    {
        if (count > 0)
        {
            _ruleLookups.Add(count, new KeyValuePair<string, object?>("result", result));
        }
    }

    /// <summary>result: granted | no_reward | no_rule | bad_id | ignored_fact | already_marked | rejected.</summary>
    public void Settlement(string result) => _settlements.Add(1, new KeyValuePair<string, object?>("result", result));

    /// <summary>reason: completion_mark.</summary>
    public void GemsGranted(string reason, int gems) => _gems.Add(gems, new KeyValuePair<string, object?>("reason", reason));

    /// <summary>operation: set | delete.</summary>
    public void CacheError(string operation) =>
        _cacheErrors.Add(1, new KeyValuePair<string, object?>("operation", operation));

    /// <summary>result: verified | rejected | error.</summary>
    public void ReplayDuration(string result, TimeSpan duration) =>
        _replayDuration.Record(duration.TotalSeconds, new KeyValuePair<string, object?>("result", result));

    public void Latency(TimeSpan latency) => _latency.Record(Math.Max(0, latency.TotalSeconds));

    /// <summary>result: verified | rejected | malformed | duplicate | superseded | runner_error | retry | dead_letter | ruleset | postponed | run_gone.</summary>
    public void StepJob(string result) => _stepJobs.Add(1, new KeyValuePair<string, object?>("result", result));

    public void StepDuration(string kind, TimeSpan duration) =>
        _stepDuration.Record(duration.TotalSeconds, new KeyValuePair<string, object?>("kind", kind));

    public void StepWait(TimeSpan wait) => _stepWait.Record(Math.Max(0, wait.TotalSeconds));

    public void StepMismatch(Rpg.Contracts.Runs.StepMismatchReason reason) =>
        _stepMismatches.Add(1, new KeyValuePair<string, object?>("reason", reason.ToString()));

    /// <summary>result: advanced | waiting | rolled_back | rejected | won | noop.</summary>
    public void Fanin(string result) => _fanin.Add(1, new KeyValuePair<string, object?>("result", result));

    public void FloorsVerified(int count)
    {
        if (count > 0)
        {
            _floorsVerified.Add(count);
        }
    }

    /// <summary>result: won | rejected.</summary>
    public void RunVerdict(string result) => _runVerdicts.Add(1, new KeyValuePair<string, object?>("result", result));

    public void RunRolledBack(string reason, bool terminal) => _rollbacks.Add(1,
        new KeyValuePair<string, object?>("reason", reason), new KeyValuePair<string, object?>("terminal", terminal));

    /// <summary>to: released | voided | pending.</summary>
    public void LedgerTransition(string to, long gems)
    {
        if (gems > 0)
        {
            _ledgerTransitions.Add(gems, new KeyValuePair<string, object?>("to", to));
        }
    }

    public void AntiCheat(string kind) => _antiCheat.Add(1, new KeyValuePair<string, object?>("kind", kind));
}
