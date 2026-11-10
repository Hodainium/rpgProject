using System.Diagnostics.Metrics;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using RabbitMQ.Client;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Migrations;
using Rpg.Verification;
using StackExchange.Redis;

namespace Rpg.VerifierWorker.Tests.Infrastructure;

/// <summary>Stands in for the Godot project's version lookup: a fixed ruleset version.</summary>
public sealed class FakeGodotProcess : IGodotProcess
{
    public const string Version = "4.7.2.stable.mono+aaaaaaaaaaaaaaaa";

    public Task<string> RulesetVersionAsync(CancellationToken ct) => Task.FromResult(Version);
}

/// <summary>
/// Stands in for the headless step runner (spec run-verify 6): by default an honest verifier, which reproduces what the
/// request claims; tests set <see cref="Handler"/> to tamper, fail or hang.
/// </summary>
public sealed class FakeStepRunner : IStepRunner
{
    private readonly List<StepRequest> _requests = [];
    private int _calls;

    public const string GenesisHash = "genesis-hash";

    /// <summary>The boss facts every battle in a step reports (null = an ordinary battle).</summary>
    public BattleFacts? Facts { get; set; }

    public Func<StepRequest, CancellationToken, Task<StepRun>>? Handler { get; set; }

    public int Calls => Volatile.Read(ref _calls);

    public IReadOnlyList<StepRequest> Requests
    {
        get
        {
            lock (_requests)
            {
                return [.. _requests];
            }
        }
    }

    public Task<StepRun> RunAsync(string requestJson, CancellationToken ct)
    {
        Interlocked.Increment(ref _calls);
        var request = JsonSerializer.Deserialize<StepRequest>(requestJson, RpgJson.Options)!;
        lock (_requests)
        {
            _requests.Add(request);
        }

        return Handler is { } handler ? handler(request, ct) : Task.FromResult(Honest(request));
    }

    /// <summary>The verdict of a verifier that agrees with the client: hashes as claimed, every battle Verified.</summary>
    public StepRun Honest(StepRequest request)
    {
        if (request.Kind == StepKind.Genesis)
        {
            var snapshot = JsonDocument.Parse("""{"schemaVersion":1,"genesis":true}""").RootElement.Clone();
            return Ok(new StepVerdict(ReplayVerdict.Verified, null, null, null, "", GenesisHash, snapshot, [], null, "", "fake",
                DateTimeOffset.UtcNow));
        }

        var battles = request.Actions.Where(a => a.Action.Battle is not null)
            .Select(a => new ReplayResult(1, a.Action.Battle!.BattleId, ReplayVerdict.Verified, null, null, null,
                BattleOutcome.Victory, 12, new string('c', 64), "fake-engine", Facts))
            .ToList();
        return Ok(new StepVerdict(ReplayVerdict.Verified, null, null, null, request.StartStateHash ?? "",
            request.Actions[^1].StateHash, null, battles, null, "", "fake", DateTimeOffset.UtcNow));
    }

    public static StepRun Ok(StepVerdict verdict) => new(ReplayRunStatus.Completed, verdict, "");

    /// <summary>A rejection of the step with <paramref name="reason"/> at <paramref name="seq"/>.</summary>
    public static StepRun Rejected(StepMismatchReason reason, int seq = 0, IReadOnlyList<ReplayResult>? battles = null) =>
        Ok(new StepVerdict(ReplayVerdict.Rejected, ReplayErrors.ReplayMismatchCode, ReplayErrors.ReplayMismatchName,
            new StepMismatch(reason, seq, "tampered"), "", "", null, battles ?? [], null, "", "fake", DateTimeOffset.UtcNow));

    public static StepRun Error(string detail = "boom") => new(ReplayRunStatus.RunnerError, null, detail);
}

public sealed record SeededBattle(string BattleId, Guid RunId, Guid PlayerId, int Seq, string Ruleset);

/// <summary>
/// The worker's services over a database of its own and the shared Redis and RabbitMQ, with a fake runner. Each
/// connection can be pointed somewhere unreachable to test the fail-open paths.
/// </summary>
public sealed class WorkerHarness : IAsyncDisposable
{
    private readonly Stack _stack;

    private WorkerHarness(Stack stack, ServiceProvider services, string postgres, FakeGodotProcess runner)
    {
        _stack = stack;
        Services = services;
        Postgres = postgres;
    }

    public ServiceProvider Services { get; }

    public string Postgres { get; }

    public FakeReplayRunner Runner { get; } = new();

    private BattleSettler? _settler;

    /// <summary>Settles a seeded battle through the production settlement code (see BattleSettler).</summary>
    public BattleSettler Processor => _settler ??= new BattleSettler(Services, Runner);

    public StepProcessor Steps => Services.GetRequiredService<StepProcessor>();

    public StepConsumer StepConsumer => Services.GetRequiredService<StepConsumer>();

    public FakeStepRunner StepRunner => (FakeStepRunner)Services.GetRequiredService<IStepRunner>();

    public NpgsqlDataSource Data => Services.GetRequiredService<NpgsqlDataSource>();

    public WorkerState State => Services.GetRequiredService<WorkerState>();

    public MetricsProbe Metrics { get; private set; } = null!;

    public static async Task<WorkerHarness> CreateAsync(Stack stack, Dictionary<string, string?>? settings = null,
        string? postgres = null, string? redis = null, FakeGodotProcess? runner = null, string environment = "Development")
    {
        var database = await stack.NewDatabaseAsync();
        await using (var data = NpgsqlDataSource.Create(database))
        {
            await new MigrationRunner(data, NullLogger<MigrationRunner>.Instance).EnsureMigratedAsync(CancellationToken.None);
            // Spec economy-rewards: what a boss pays is a rule in the table. These tests' bosses pay 10 unless a test says otherwise.
            // In force long before any seeded battle: settlement reads the rule as it stood at the battle (C10).
            await using var rules = data.CreateCommand(
                $"""
                INSERT INTO reward_rules (challenge_id, currency, amount, version, effective_from, created_by)
                SELECT 'boss/' || id, 'gems', 10, 1, '{LongAgo:O}', 'test' FROM unnest(ARRAY['boss.lich','boss.golem','boss.a','boss.b']) AS id
                """);
            await rules.ExecuteNonQueryAsync();
        }

        runner ??= new FakeGodotProcess();
        var values = new Dictionary<string, string?>
        {
            ["ConnectionStrings:Postgres"] = postgres ?? database,
            ["ConnectionStrings:Redis"] = redis ?? stack.RedisConnectionString,
            ["RabbitMq:Uri"] = stack.RabbitMq.GetConnectionString(),
            ["Verifier:RulesetVersion"] = FakeGodotProcess.Version,
            ["Verifier:Concurrency"] = "1",
        };
        foreach (var (key, value) in settings ?? [])
        {
            values[key] = value;
        }

        var services = new ServiceCollection();
        services.AddLogging();
        services.AddMetrics();
        services.AddSingleton<IConfiguration>(new ConfigurationBuilder().AddInMemoryCollection(values).Build());
        services.AddSingleton<Microsoft.Extensions.Hosting.IHostEnvironment>(new StubEnvironment(environment));
        services.AddVerifierWorker();
        services.AddSingleton<IGodotProcess>(runner);
        services.AddSingleton<IStepRunner>(new FakeStepRunner());
        var provider = services.BuildServiceProvider();
        var harness = new WorkerHarness(stack, provider, database, runner);
        harness.Metrics = new MetricsProbe(provider.GetRequiredService<IMeterFactory>());
        return harness;
    }

    /// <summary>One run owned by a new player, with a Submitted battle at seq 2.</summary>
    public async Task<SeededBattle> SeedAsync(string? ruleset = null, string status = "Submitted", Guid? player = null,
        string runStatus = "Active", DateTimeOffset? submittedAt = null)
    {
        ruleset ??= FakeGodotProcess.Version;
        var runId = Guid.NewGuid();
        var playerId = player ?? Guid.NewGuid();
        var battleId = $"{runId:D}/f0/c5";
        var conditions = new BattleSnapshot(2, battleId, "1234567890123", "fixture.encounter.duel",
            [new PartyMemberSnapshot(1, "fixture.character.duelist", 1, Hp: 50000)], ScalingId: "fixture.scaling", Depth: 0);
        var log = new ActionLog(2, [new ActionEntry(1, "P1", "Ability.Attack", "E1")], BattleOutcome.Victory,
            new string('a', 64));
        await ExecuteAsync(
            "INSERT INTO players (player_id, display_name, created_at) VALUES ($1, 'p', now()) ON CONFLICT DO NOTHING", playerId);
        await ExecuteAsync(
            """
            INSERT INTO runs (run_id, player_id, ruleset_version, run_structure_id, character_ids, status, current_floor,
              last_seq, started_at) VALUES ($1, $2, $3, 'descent', ARRAY['warrior'], $4, 0, 2, now())
            """, runId, playerId, ruleset, runStatus);
        await ExecuteAsync(
            """
            INSERT INTO run_actions (run_id, seq, floor, type, action, state_hash, played_at, received_at)
            VALUES ($1, 2, 0, 'battle', '{}'::jsonb, 'h', now(), now())
            """, runId);
        await ExecuteAsync(
            """
            INSERT INTO battle_sessions (battle_id, run_id, run_seq, seed, ruleset_version, conditions, action_log, status,
              submitted_at) VALUES ($1, $2, 2, 1234567890123, $3, $4::jsonb, $5::jsonb, 'Submitted', COALESCE($6, now() - interval '3 seconds'))
            """, battleId, runId, ruleset, JsonSerializer.Serialize(conditions, RpgJson.Options),
            JsonSerializer.Serialize(log, RpgJson.Options), submittedAt?.ToUniversalTime() ?? (object)DBNull.Value);
        if (status != "Submitted")
        {
            var verdict = JsonSerializer.Serialize(new BattleVerdict(ReplayVerdict.Verified, null, null, null,
                BattleOutcome.Victory, 1, "x", ruleset, "e", DateTimeOffset.UtcNow), RpgJson.Options);
            await ExecuteAsync(
                "UPDATE battle_sessions SET status = $2, verdict = $3::jsonb, verified_at = now() WHERE battle_id = $1",
                battleId, status, verdict);
        }

        return new SeededBattle(battleId, runId, playerId, 2, ruleset);
    }

    /// <summary>
    /// When the harness's rule versions take effect unless a test says otherwise: long before any battle a test seeds, so a
    /// version is in force for the battles that follow it in the test. Settlement reads the rule as it stood at the battle's
    /// submit time (spec economy-challenges C10), so a test about the order of a rule and a battle passes its own time.
    /// </summary>
    public static readonly DateTimeOffset LongAgo = new(2000, 1, 1, 0, 0, 0, TimeSpan.Zero);

    /// <summary>A new version of a boss's rule (retired for 0), as the API would write it.</summary>
    public Task PutRuleAsync(string boss, int amount, int version, DateTimeOffset? effectiveFrom = null) =>
        PutChallengeAsync("boss/" + boss, version, amount, Rpg.Contracts.Economy.RewardCycles.Once, null, effectiveFrom);

    /// <summary>A new version of a challenge's reward (an amount of 0 retires it).</summary>
    public Task PutChallengeAsync(string challengeId, int version, int amount) =>
        PutChallengeAsync(challengeId, version, amount, Rpg.Contracts.Economy.RewardCycles.Once, null);

    public Task PutChallengeAsync(string challengeId, int version, int amount, string cycle, DateTimeOffset? endsAt,
        DateTimeOffset? effectiveFrom = null) => ExecuteAsync(
        """
        INSERT INTO reward_rules (challenge_id, currency, amount, cycle, ends_at, version, effective_from, created_by)
        VALUES ($1, 'gems', $2, $3, $4, $5, $6, 'test')
        """,
        challengeId, amount, cycle, endsAt?.ToUniversalTime() ?? (object)DBNull.Value, version,
        (effectiveFrom ?? LongAgo).ToUniversalTime());

    public static VerifyBattleJob JobOf(SeededBattle battle) =>
        new(battle.BattleId, battle.RunId, battle.Seq, battle.Ruleset, DateTimeOffset.UtcNow);

    // ---- runs with steps (spec run-verify 2) -----------------------------------------------------------------------

    /// <summary>A run that went through the step pipeline: Active, floor 0, and its genesis step (step 0) Pending.</summary>
    public async Task<SeededRun> SeedRunAsync(string runStatus = "Active", int lastSeq = 0, Guid? player = null)
    {
        var runId = Guid.NewGuid();
        var playerId = player ?? Guid.NewGuid();
        await ExecuteAsync(
            "INSERT INTO players (player_id, display_name, created_at) VALUES ($1, 'p', now()) ON CONFLICT DO NOTHING", playerId);
        await ExecuteAsync(
            """
            INSERT INTO runs (run_id, player_id, ruleset_version, run_structure_id, character_ids, status, current_floor,
              last_seq, started_at) VALUES ($1, $2, $3, 'descent', ARRAY['warrior'], $4, 0, $5, now())
            """, runId, playerId, FakeGodotProcess.Version, runStatus, lastSeq);
        await ExecuteAsync("INSERT INTO run_floors (run_id, floor, floor_seed, issued_at) VALUES ($1, 0, 11, now())", runId);
        await ExecuteAsync(
            """
            INSERT INTO run_steps (run_id, epoch, step_no, from_seq, to_seq, kind, status) VALUES ($1, 0, 0, 0, 1, 'genesis', 'Pending')
            """, runId);
        return new SeededRun(runId, playerId);
    }

    /// <summary>
    /// What an upload does for one action: the run_actions row (a snapshot-bearing one is a checkpoint and, after seq 1, closes
    /// a step) and, for a battle, its session. Hashes are "h&lt;seq&gt;" unless given.
    /// </summary>
    public async Task<int?> UploadAsync(SeededRun run, int seq, string type = "enter_room", bool snapshot = false,
        string? hash = null, int floor = 0, int epoch = 0)
    {
        var battle = type == RunActionTypes.Battle;
        await ExecuteAsync(
            """
            INSERT INTO run_actions (run_id, seq, floor, type, action, state_hash, snapshot, played_at, received_at)
            VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7::jsonb, now(), now())
            """, run.RunId, seq, floor, type, $$"""{"type":"{{type}}","floor":{{floor}}}""", hash ?? $"h{seq}",
            snapshot ? """{"schemaVersion":1,"marker":1}""" : DBNull.Value);
        await ExecuteAsync("UPDATE runs SET last_seq = $2 WHERE run_id = $1", run.RunId, seq);
        if (type == RunActionTypes.NextFloor)
        {
            await ExecuteAsync("UPDATE run_floors SET end_seq = $3 WHERE run_id = $1 AND floor = $2", run.RunId, floor, seq);
        }

        if (battle)
        {
            var id = $"{run.RunId:D}/f{floor}/c{seq}";
            var conditions = new BattleSnapshot(2, id, "1234567890123", "fixture.encounter.duel",
                [new PartyMemberSnapshot(1, "fixture.character.duelist", 1, Hp: 50000)], ScalingId: "fixture.scaling", Depth: floor);
            var log = new ActionLog(2, [new ActionEntry(1, "P1", "Ability.Attack", "E1")], BattleOutcome.Victory,
                new string('a', 64));
            await ExecuteAsync(
                $$"""
                UPDATE run_actions SET action = '{"type":"battle","floor":{{floor}}}'::jsonb WHERE run_id = $1 AND seq = $2
                """, run.RunId, seq);
            await ExecuteAsync(
                """
                INSERT INTO battle_sessions (battle_id, run_id, run_seq, seed, ruleset_version, conditions, action_log, status,
                  submitted_at) VALUES ($1, $2, $3, 1234567890123, $4, $5::jsonb, $6::jsonb, 'Submitted', now())
                """, id, run.RunId, seq, FakeGodotProcess.Version, JsonSerializer.Serialize(conditions, RpgJson.Options),
                JsonSerializer.Serialize(log, RpgJson.Options));
        }

        if (!snapshot || seq == 1)
        {
            return null;
        }

        var from = await ScalarAsync<int>("SELECT COALESCE(max(seq), 0) FROM run_actions WHERE run_id = $1 AND snapshot IS NOT NULL AND seq < $2",
            run.RunId, seq);
        var stepNo = await ScalarAsync<int>("SELECT COALESCE(max(step_no), -1) + 1 FROM run_steps WHERE run_id = $1", run.RunId);
        var kind = battle ? "battle" : type == RunActionTypes.End ? "end" : "segment";
        await ExecuteAsync(
            "INSERT INTO run_steps (run_id, epoch, step_no, from_seq, to_seq, kind, status) VALUES ($1, $2, $3, $4, $5, $6, 'Pending')",
            run.RunId, epoch, stepNo, from, seq, kind);
        return stepNo;
    }

    public static VerifyStepJob StepJobOf(SeededRun run, int stepNo, int epoch = 0) =>
        new(run.RunId, epoch, stepNo, FakeGodotProcess.Version, DateTimeOffset.UtcNow);

    /// <summary>The run's verified prefix, status, epoch and last_seq.</summary>
    public async Task<(string Status, int Epoch, int VerifiedSeq, int LastSeq)> RunStateAsync(SeededRun run)
    {
        await using var command = Command("SELECT status, epoch, verified_seq, last_seq FROM runs WHERE run_id = $1", [run.RunId]);
        await using var reader = await command.ExecuteReaderAsync();
        await reader.ReadAsync();
        return (reader.GetString(0), reader.GetInt32(1), reader.GetInt32(2), reader.GetInt32(3));
    }

    public async Task<T?> ScalarAsync<T>(string sql, params object[] values)
    {
        await using var command = Command(sql, values);
        var result = await command.ExecuteScalarAsync();
        return result is null or DBNull ? default : (T)result;
    }

    /// <summary>The first column of every row, as a number.</summary>
    public async Task<List<int>> IntsAsync(string sql, params object[] values) =>
        [.. (await StringsAsync(sql, values)).Select(int.Parse)];

    /// <summary>The first column of every row, as text.</summary>
    public async Task<List<string>> StringsAsync(string sql, params object[] values)
    {
        await using var command = Command(sql, values);
        await using var reader = await command.ExecuteReaderAsync();
        var rows = new List<string>();
        while (await reader.ReadAsync())
        {
            rows.Add(reader.GetValue(0).ToString()!);
        }

        return rows;
    }

    /// <summary>The outbox row types for a destination, in the order the relay would send them.</summary>
    public async Task<List<string>> OutboxTypesAsync(string destination)
    {
        await using var command = Command("SELECT type FROM outbox WHERE destination = $1 ORDER BY seq", [destination]);
        await using var reader = await command.ExecuteReaderAsync();
        var types = new List<string>();
        while (await reader.ReadAsync())
        {
            types.Add(reader.GetString(0));
        }

        return types;
    }

    /// <summary>The JSON payloads of one outbox row type, in order.</summary>
    public async Task<List<string>> OutboxPayloadsAsync(string type)
    {
        await using var command = Command("SELECT payload::text FROM outbox WHERE type = $1 ORDER BY seq", [type]);
        await using var reader = await command.ExecuteReaderAsync();
        var payloads = new List<string>();
        while (await reader.ReadAsync())
        {
            payloads.Add(reader.GetString(0));
        }

        return payloads;
    }

    public async Task ExecuteAsync(string sql, params object[] values)
    {
        await using var command = Command(sql, values);
        await command.ExecuteNonQueryAsync();
    }

    private NpgsqlCommand Command(string sql, object[] values)
    {
        var command = Data.CreateCommand(sql);
        foreach (var value in values)
        {
            command.Parameters.Add(new NpgsqlParameter { Value = value });
        }

        return command;
    }

    public async Task<IDatabase> RedisAsync() =>
        (await ConnectionMultiplexer.ConnectAsync(_stack.RedisConnectionString)).GetDatabase();

    /// <summary>Starts the step consumer and waits until it is attached to verify.segment.</summary>
    public async Task StartStepConsumerAsync(CancellationToken ct)
    {
        await StepConsumer.StartAsync(ct);
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (!State.Ready)
        {
            Assert.True(DateTime.UtcNow < deadline, "the step consumer did not become ready");
            await Task.Delay(100, ct);
        }
    }

    public async ValueTask DisposeAsync()
    {
        Metrics.Dispose();
        try
        {
            await StepConsumer.StopAsync(CancellationToken.None);
        }
        catch (Exception)
        {
            // Never started.
        }

        await Services.DisposeAsync();
    }
}

/// <summary>Collects the worker's counters for one harness (the meters of its own IMeterFactory only).</summary>
public sealed class MetricsProbe : IDisposable
{
    private readonly MeterListener _listener = new();
    private readonly Dictionary<string, long> _counts = [];

    public MetricsProbe(IMeterFactory factory)
    {
        _listener.InstrumentPublished = (instrument, listener) =>
        {
            if (instrument.Meter.Name == WorkerMetrics.MeterName && ReferenceEquals(instrument.Meter.Scope, factory))
            {
                listener.EnableMeasurementEvents(instrument);
            }
        };
        _listener.SetMeasurementEventCallback<long>((instrument, value, tags, _) => Add(instrument.Name, value, tags));
        _listener.SetMeasurementEventCallback<double>((instrument, _, tags, _) => Add(instrument.Name + ".count", 1, tags));
        _listener.Start();
    }

    private void Add(string name, long value, ReadOnlySpan<KeyValuePair<string, object?>> tags)
    {
        var key = name + string.Concat(tags.ToArray().OrderBy(t => t.Key).Select(t => $"|{t.Key}={t.Value}"));
        lock (_counts)
        {
            _counts[key] = _counts.GetValueOrDefault(key) + value;
        }
    }

    /// <summary>The sum of <paramref name="name"/> for the label set, e.g. <c>Count("rpg.verify_jobs", "result=verified")</c>.</summary>
    public long Count(string name, params string[] labels)
    {
        lock (_counts)
        {
            return _counts.Where(kv => kv.Key.StartsWith(name + "|", StringComparison.Ordinal) || kv.Key == name)
                .Where(kv => labels.All(l => kv.Key.Contains("|" + l, StringComparison.Ordinal)))
                .Sum(kv => kv.Value);
        }
    }

    public void Dispose() => _listener.Dispose();
}

/// <summary>The verify queues seen from outside: purge, publish a job, read what a queue holds.</summary>
public sealed class RabbitTools : IAsyncDisposable
{
    private readonly IConnection _connection;
    private readonly IChannel _channel;

    private RabbitTools(IConnection connection, IChannel channel)
    {
        _connection = connection;
        _channel = channel;
    }

    public static async Task<RabbitTools> OpenAsync(Stack stack)
    {
        var connection = await new ConnectionFactory { Uri = new Uri(stack.RabbitMq.GetConnectionString()) }
            .CreateConnectionAsync();
        var channel = await connection.CreateChannelAsync(VerifyMessaging.ConfirmedChannel);
        await VerifyMessaging.DeclareAsync(channel, CancellationToken.None);
        var tools = new RabbitTools(connection, channel);
        await tools.PurgeAsync();
        return tools;
    }

    public async Task PurgeAsync()
    {
        await _channel.QueuePurgeAsync(VerifyTopology.Queue);
        await _channel.QueuePurgeAsync(VerifyTopology.DeadLetterQueue);
        foreach (var tier in VerifyTopology.RetryTiers)
        {
            await _channel.QueuePurgeAsync(tier.Queue);
        }

        await _channel.QueuePurgeAsync(VerifyTopology.SegmentQueue);
        await _channel.QueuePurgeAsync(VerifyTopology.SegmentDeadLetterQueue);
        foreach (var tier in VerifyTopology.SegmentRetryTiers)
        {
            await _channel.QueuePurgeAsync(tier.Queue);
        }
    }

    public Task PublishStepAsync(VerifyStepJob job, int attempt = 0) =>
        VerifyMessaging.PublishAsync(_channel, VerifyTopology.Exchange, VerifyTopology.SegmentRoutingKey, job, attempt, null,
            CancellationToken.None);

    public Task PublishRawSegmentAsync(byte[] body) =>
        _channel.BasicPublishAsync(VerifyTopology.Exchange, VerifyTopology.SegmentRoutingKey, mandatory: false,
            new BasicProperties { Persistent = true }, body).AsTask();

    public Task PublishAsync(VerifyBattleJob job, int attempt = 0) =>
        VerifyMessaging.PublishAsync(_channel, VerifyTopology.Exchange, VerifyTopology.RoutingKey, job, attempt, null,
            CancellationToken.None);

    public Task PublishRawAsync(byte[] body) =>
        _channel.BasicPublishAsync(VerifyTopology.Exchange, VerifyTopology.RoutingKey, mandatory: false,
            new BasicProperties { Persistent = true }, body).AsTask();

    public async Task<uint> DepthAsync(string queue) => (await _channel.QueueDeclarePassiveAsync(queue)).MessageCount;

    /// <summary>Waits until <paramref name="queue"/> holds a message (or the time is up) and returns it without removing it.</summary>
    public async Task<(byte[] Body, IReadOnlyDictionary<string, object?> Headers)?> PeekAsync(string queue, TimeSpan wait)
    {
        var deadline = DateTime.UtcNow + wait;
        while (DateTime.UtcNow < deadline)
        {
            var message = await _channel.BasicGetAsync(queue, autoAck: false);
            if (message is not null)
            {
                IReadOnlyDictionary<string, object?> headers =
                    new Dictionary<string, object?>(message.BasicProperties.Headers ?? new Dictionary<string, object?>());
                var result = (message.Body.ToArray(), headers);
                await _channel.BasicNackAsync(message.DeliveryTag, false, requeue: true);
                return result;
            }

            await Task.Delay(100);
        }

        return null;
    }

    public async Task WaitUntilAsync(Func<Task<bool>> condition, string what, TimeSpan? limit = null)
    {
        var deadline = DateTime.UtcNow + (limit ?? TimeSpan.FromSeconds(30));
        while (!await condition())
        {
            Assert.True(DateTime.UtcNow < deadline, $"timed out waiting for {what}");
            await Task.Delay(100);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await PurgeAsync();
        await _channel.DisposeAsync();
        await _connection.DisposeAsync();
    }
}

public sealed record SeededRun(Guid RunId, Guid PlayerId);

internal sealed class StubEnvironment(string name) : Microsoft.Extensions.Hosting.IHostEnvironment
{
    public string EnvironmentName { get; set; } = name;

    public string ApplicationName { get; set; } = "test";

    public string ContentRootPath { get; set; } = "";

    public Microsoft.Extensions.FileProviders.IFileProvider ContentRootFileProvider { get; set; } = null!;
}
