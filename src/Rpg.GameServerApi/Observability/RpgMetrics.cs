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
    private readonly Counter<long> _outboxPublished;
    private readonly Histogram<double> _outboxPublishDuration;
    private readonly Counter<long> _walletReads;
    private readonly Counter<long> _ruleChanges;
    private readonly Counter<long> _cycleResets;
    private readonly Counter<long> _redrives;
    private readonly ConcurrentDictionary<string, (long Pending, double OldestAge, long Dead)> _outbox = new();
    private long _battlesUnverified = -1;
    private double _oldestUnverifiedAge;
    private readonly ConcurrentDictionary<string, long> _verifyQueueDepth = new();
    // Spec run-verify 5.
    private readonly Counter<long> _stepsCreated;
    private readonly Counter<long> _stairsGate;
    private readonly Counter<long> _genesisClaims;
    private readonly Counter<long> _rollbacks;
    private long _stepsPending = -1;
    private double _oldestPendingStepAge;
    private long _gemsPending = -1;
    // Spec card-collection 5.
    private readonly Counter<long> _packsOpened;
    private readonly Counter<long> _packCards;
    private readonly Counter<long> _packPity;
    private readonly Counter<long> _cardsDusted;
    private readonly Counter<long> _cardsCrafted;
    private readonly Counter<long> _gemsSpent;
    private readonly Counter<long> _dustMoved;
    private readonly Counter<long> _cardRefusals;
    private readonly Counter<long> _accountReplays;
    private readonly Histogram<double> _cardActionDuration;
    private readonly Counter<long> _cardCatalogReads;
    private readonly Counter<long> _cardRuleChanges;
    private long _cardsOwned = -1;

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

        // Slice 3 (spec battle-verify 5).
        _outboxPublished = meter.CreateCounter<long>("rpg.outbox_published",
            description: "Outbox rows the relay tried to publish, by destination, type and result (spec settlement-outbox 5).");
        _outboxPublishDuration = meter.CreateHistogram<double>("rpg.outbox_publish_duration", unit: "s",
            description: "Time to publish one outbox row (to the confirm), by destination.",
            advice: new InstrumentAdvice<double> { HistogramBucketBoundaries = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10] });
        _ruleChanges = meter.CreateCounter<long>("rpg.reward_rule_changes", description: "Reward-rule admin writes, by result.");
        _redrives = meter.CreateCounter<long>("rpg.redrives", description: "Dead-lettered rows put back to work by an operator, by target (review fix 2026-11-09).");
        _cycleResets = meter.CreateCounter<long>("rpg.reward_cycle_resets", description: "Reward cycle resets, by result (spec economy-challenges 5).");
        _walletReads = meter.CreateCounter<long>("rpg.wallet_reads", description: "Wallet reads by where the answer came from.");
        // Spec card-collection 5. Labels are small fixed sets: never a card or character id; `pack` is a configured pack type.
        _packsOpened = meter.CreateCounter<long>("rpg.packs_opened", description: "Packs opened, by pack type.");
        _packCards = meter.CreateCounter<long>("rpg.pack_cards", description: "Cards drawn from packs, by rarity and whether they were duplicates.");
        _packPity = meter.CreateCounter<long>("rpg.pack_pity_triggers", description: "Cards forced by a pity timer, by rarity.");
        _cardsDusted = meter.CreateCounter<long>("rpg.cards_dusted", description: "Cards dusted.");
        _cardsCrafted = meter.CreateCounter<long>("rpg.cards_crafted", description: "Cards crafted.");
        _gemsSpent = meter.CreateCounter<long>("rpg.gems_spent", description: "Gems spent, by reason.");
        _dustMoved = meter.CreateCounter<long>("rpg.dust", description: "Dust moved: direction in (faucet) or out (sink), by reason.");
        _cardRefusals = meter.CreateCounter<long>("rpg.card_actions_refused", description: "Account actions refused, by action and reason.");
        _accountReplays = meter.CreateCounter<long>("rpg.account_request_replays", description: "Account requests answered from the request log, by action.");
        _cardActionDuration = meter.CreateHistogram<double>("rpg.account_action_duration", unit: "s",
            description: "The whole transaction of one account action.");
        _cardCatalogReads = meter.CreateCounter<long>("rpg.card_catalog_reads", description: "Catalog reads by where the answer came from.");
        _cardRuleChanges = meter.CreateCounter<long>("rpg.card_rule_changes", description: "Pack-type and card-rate admin writes, by kind.");
        meter.CreateObservableGauge("rpg.cards_owned",
            () => Interlocked.Read(ref _cardsOwned) is var count and >= 0
                ? [new Measurement<long>(count)]
                : Array.Empty<Measurement<long>>(),
            description: "Rows in card_holdings, recomputed every 30 s from Postgres.");
        meter.CreateObservableGauge("rpg.outbox_pending",
            () => _outbox.Select(kv => new Measurement<long>(kv.Value.Pending,
                new KeyValuePair<string, object?>("destination", kv.Key))),
            description: "Outbox rows not yet published and not dead-lettered, recomputed from Postgres.");
        meter.CreateObservableGauge("rpg.outbox_oldest_unpublished_age",
            () => _outbox.Select(kv => new Measurement<double>(kv.Value.OldestAge,
                new KeyValuePair<string, object?>("destination", kv.Key))),
            unit: "s", description: "Age of the oldest unpublished outbox row: the outbox lag (0 when none).");
        meter.CreateObservableGauge("rpg.outbox_dead_lettered",
            () => _outbox.Select(kv => new Measurement<long>(kv.Value.Dead,
                new KeyValuePair<string, object?>("destination", kv.Key))),
            description: "Outbox rows dead-lettered and waiting for a human.");
        meter.CreateObservableGauge("rpg.battles_unverified",
            () => Interlocked.Read(ref _battlesUnverified) is var count and >= 0
                ? [new Measurement<long>(count)]
                : Array.Empty<Measurement<long>>(),
            description: "Battle sessions still Submitted and not dead-lettered, recomputed from Postgres.");
        meter.CreateObservableGauge("rpg.battle_oldest_unverified_age", () =>
                Interlocked.Read(ref _battlesUnverified) >= 0
                    ? [new Measurement<double>(Volatile.Read(ref _oldestUnverifiedAge))]
                    : Array.Empty<Measurement<double>>(),
            unit: "s", description: "Age of the oldest unverified battle session (0 when none).");
        meter.CreateObservableGauge("rpg.verify_queue_depth",
            () => _verifyQueueDepth.Select(kv => new Measurement<long>(kv.Value,
                new KeyValuePair<string, object?>("queue", kv.Key))),
            description: "Messages waiting in verify.battle, verify.segment, the retry queues (summed) and the DLQs.");

        // Slice 4a (spec run-verify 5).
        _stepsCreated = meter.CreateCounter<long>("rpg.steps_created", description: "Verification steps created by uploads, by kind.");
        _stairsGate = meter.CreateCounter<long>("rpg.stairs_gate", description: "Stairs requests the verification gate looked at, by result.");
        _genesisClaims = meter.CreateCounter<long>("rpg.genesis_claims", description: "The client's seq 1 against the server's anchor, by result.");
        _rollbacks = meter.CreateCounter<long>("rpg.run_rollbacks", description: "Runs rolled back or ended by the verifier, by reason and terminal.");
        meter.CreateObservableGauge("rpg.steps_pending",
            () => Interlocked.Read(ref _stepsPending) is var count and >= 0
                ? [new Measurement<long>(count)]
                : Array.Empty<Measurement<long>>(),
            description: "Verification steps not decided and not dead-lettered, recomputed from Postgres.");
        meter.CreateObservableGauge("rpg.step_oldest_pending_age", () =>
                Interlocked.Read(ref _stepsPending) >= 0
                    ? [new Measurement<double>(Volatile.Read(ref _oldestPendingStepAge))]
                    : Array.Empty<Measurement<double>>(),
            unit: "s", description: "Age of the oldest pending verification step (0 when none).");
        meter.CreateObservableGauge("rpg.gems_pending",
            () => Interlocked.Read(ref _gemsPending) is var gems and >= 0
                ? [new Measurement<long>(gems)]
                : Array.Empty<Measurement<long>>(),
            description: "Gems in pending ledger rows: settled, waiting for their battle to be verified.");
    }

    /// <summary>kind: genesis | segment | battle | end.</summary>
    public void StepCreated(string kind, int count = 1) =>
        _stepsCreated.Add(count, new KeyValuePair<string, object?>("kind", kind));

    /// <summary>result: open | blocked.</summary>
    public void StairsGate(string result) => _stairsGate.Add(1, new KeyValuePair<string, object?>("result", result));

    /// <summary>result: match | mismatch (the first comparison of an upload's seq 1).</summary>
    public void GenesisClaim(string result) => _genesisClaims.Add(1, new KeyValuePair<string, object?>("result", result));

    /// <summary>reason: a coarse category (StateMismatch | Illegal | Seed | Link | Malformed); terminal: true | false.</summary>
    public void RunRolledBack(string reason, bool terminal) => _rollbacks.Add(1,
        new KeyValuePair<string, object?>("reason", reason), new KeyValuePair<string, object?>("terminal", terminal));

    /// <summary>Set by <c>BattleVerifyMonitor</c>.</summary>
    public void SetStepsPending(long count, double oldestAgeSeconds)
    {
        Volatile.Write(ref _oldestPendingStepAge, Math.Max(0, oldestAgeSeconds));
        Interlocked.Exchange(ref _stepsPending, count);
    }

    public void SetGemsPending(long gems) => Interlocked.Exchange(ref _gemsPending, gems);

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

    /// <summary>status: won | lost.</summary>
    public void RunEnd(string status) => _runEnds.Add(1, new KeyValuePair<string, object?>("status", status));

    /// <summary>bucket: actions | runs | floors.</summary>
    public void RateLimited(string bucket) => _rateLimited.Add(1, new KeyValuePair<string, object?>("bucket", bucket));

    public void DevTokenIssued() => _devTokens.Add(1);

    /// <summary>destination: rabbit | redpanda; type: an outbox row type; result: ok | failed.</summary>
    public void OutboxPublished(string destination, string type, string result) => _outboxPublished.Add(1,
        new KeyValuePair<string, object?>("destination", destination), new KeyValuePair<string, object?>("type", type),
        new KeyValuePair<string, object?>("result", result));

    public void OutboxPublishDuration(string destination, TimeSpan duration) => _outboxPublishDuration.Record(
        duration.TotalSeconds, new KeyValuePair<string, object?>("destination", destination));

    /// <summary>Set by <c>OutboxMonitor</c>.</summary>
    public void SetOutbox(string destination, long pending, double oldestAgeSeconds, long deadLettered) =>
        _outbox[destination] = (pending, Math.Max(0, oldestAgeSeconds), deadLettered);

    /// <summary>result: ok | invalid | forbidden.</summary>
    public void RewardRuleChange(string result) => _ruleChanges.Add(1, new KeyValuePair<string, object?>("result", result));

    /// <summary>result: ok | unknown | forbidden | invalid.</summary>
    /// <summary>target: outbox | steps; the count is the rows re-driven.</summary>
    public void Redriven(string target, long rows) => _redrives.Add(rows, new KeyValuePair<string, object?>("target", target));

    public void RewardCycleReset(string result) => _cycleResets.Add(1, new KeyValuePair<string, object?>("result", result));

    /// <summary>source: redis | postgres.</summary>
    public void WalletRead(string source) => _walletReads.Add(1, new KeyValuePair<string, object?>("source", source));

    // Spec card-collection 5.
    public void PackOpened(string pack, int gems)
    {
        _packsOpened.Add(1, new KeyValuePair<string, object?>("pack", pack));
        _gemsSpent.Add(gems, new KeyValuePair<string, object?>("reason", "pack"));
    }

    public void PackCard(string rarity, bool duplicate, bool pity, int dust)
    {
        _packCards.Add(1, new KeyValuePair<string, object?>("rarity", rarity),
            new KeyValuePair<string, object?>("duplicate", duplicate ? "true" : "false"));
        if (pity)
        {
            _packPity.Add(1, new KeyValuePair<string, object?>("rarity", rarity));
        }

        if (dust > 0)
        {
            _dustMoved.Add(dust, new KeyValuePair<string, object?>("direction", "in"), new KeyValuePair<string, object?>("reason", "duplicate"));
        }
    }

    public void CardDusted(int dust)
    {
        _cardsDusted.Add(1);
        _dustMoved.Add(dust, new KeyValuePair<string, object?>("direction", "in"), new KeyValuePair<string, object?>("reason", "dust"));
    }

    public void CardCrafted(int dust)
    {
        _cardsCrafted.Add(1);
        _dustMoved.Add(dust, new KeyValuePair<string, object?>("direction", "out"), new KeyValuePair<string, object?>("reason", "craft"));
    }

    public void CardActionRefused(string action, string reason) => _cardRefusals.Add(1,
        new KeyValuePair<string, object?>("action", action), new KeyValuePair<string, object?>("reason", reason));

    public void AccountReplay(string action) => _accountReplays.Add(1, new KeyValuePair<string, object?>("action", action));

    public void CardActionDuration(string action, TimeSpan duration) => _cardActionDuration.Record(duration.TotalSeconds,
        new KeyValuePair<string, object?>("action", action));

    public void CardCatalogRead(string source) => _cardCatalogReads.Add(1, new KeyValuePair<string, object?>("source", source));

    public void CardRuleChange(string kind) => _cardRuleChanges.Add(1, new KeyValuePair<string, object?>("kind", kind));

    public void SetCardsOwned(long count) => Interlocked.Exchange(ref _cardsOwned, count);

    /// <summary>Set by <c>BattleVerifyMonitor</c>; nothing is exported until the first count arrives.</summary>
    public void SetBattlesUnverified(long count, double oldestAgeSeconds)
    {
        Volatile.Write(ref _oldestUnverifiedAge, Math.Max(0, oldestAgeSeconds));
        Interlocked.Exchange(ref _battlesUnverified, count);
    }

    /// <summary>queue: verify.battle | retry | dlq.</summary>
    public void SetVerifyQueueDepth(string queue, long depth) => _verifyQueueDepth[queue] = depth;

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
