using System.Diagnostics.Metrics;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using RabbitMQ.Client;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Migrations;
using Rpg.Verification;
using StackExchange.Redis;

namespace Rpg.VerifierWorker.Tests.Infrastructure;

/// <summary>Stands in for headless Godot (spec battle-verify 6): canned results, call counting, optional gating.</summary>
public sealed class FakeReplayRunner : IReplayRunner
{
    private readonly List<string> _requests = [];
    private int _calls;

    public const string Version = "4.7.2.stable.mono+aaaaaaaaaaaaaaaa";

    /// <summary>What a replay returns; the default verifies the battle in the request.</summary>
    public Func<string, CancellationToken, Task<ReplayRun>>? Handler { get; set; }

    public int Calls => Volatile.Read(ref _calls);

    public IReadOnlyList<string> Requests
    {
        get
        {
            lock (_requests)
            {
                return [.. _requests];
            }
        }
    }

    public Task<ReplayRun> ReplayAsync(string requestJson, CancellationToken ct)
    {
        Interlocked.Increment(ref _calls);
        lock (_requests)
        {
            _requests.Add(requestJson);
        }

        return (Handler ?? ((request, _) => Task.FromResult(Verified(BattleIdOf(request)))))(requestJson, ct);
    }

    public Task<string> RulesetVersionAsync(CancellationToken ct) => Task.FromResult(Version);

    public static string BattleIdOf(string requestJson)
    {
        using var document = JsonDocument.Parse(requestJson);
        return document.RootElement.GetProperty("snapshot").GetProperty("battleId").GetString()!;
    }

    public static ReplayRun Verified(string battleId, BattleFacts? facts = null, BattleOutcome outcome = BattleOutcome.Victory) =>
        new(ReplayRunStatus.Completed,
            new ReplayResult(1, battleId, ReplayVerdict.Verified, null, null, null, outcome, 12,
                new string('c', 64), "fake-engine", facts), "");

    public static ReplayRun Rejected(string battleId, MismatchReason reason = MismatchReason.FinalHashMismatch) => new(
        ReplayRunStatus.Completed,
        new ReplayResult(1, battleId, ReplayVerdict.Rejected, ReplayErrors.ReplayMismatchCode,
            ReplayErrors.ReplayMismatchName, new ReplayMismatch(reason, 4, "tampered"), BattleOutcome.Victory, 12,
            new string('d', 64), "fake-engine"), "");

    public static ReplayRun Error(string detail = "boom") => new(ReplayRunStatus.RunnerError, null, detail);
}

public sealed record SeededBattle(string BattleId, Guid RunId, Guid PlayerId, int Seq, string Ruleset);

/// <summary>
/// The worker's services over a database of its own and the shared Redis and RabbitMQ, with a fake runner. Each
/// connection can be pointed somewhere unreachable to test the fail-open paths.
/// </summary>
public sealed class WorkerHarness : IAsyncDisposable
{
    private readonly Stack _stack;

    private WorkerHarness(Stack stack, ServiceProvider services, string postgres, FakeReplayRunner runner)
    {
        _stack = stack;
        Services = services;
        Postgres = postgres;
        Runner = runner;
    }

    public ServiceProvider Services { get; }

    public string Postgres { get; }

    public FakeReplayRunner Runner { get; }

    public VerifyProcessor Processor => Services.GetRequiredService<VerifyProcessor>();

    public VerifyConsumer Consumer => Services.GetRequiredService<VerifyConsumer>();

    public NpgsqlDataSource Data => Services.GetRequiredService<NpgsqlDataSource>();

    public WorkerState State => Services.GetRequiredService<WorkerState>();

    public MetricsProbe Metrics { get; private set; } = null!;

    public static async Task<WorkerHarness> CreateAsync(Stack stack, Dictionary<string, string?>? settings = null,
        string? postgres = null, string? redis = null, FakeReplayRunner? runner = null)
    {
        var database = await stack.NewDatabaseAsync();
        await using (var data = NpgsqlDataSource.Create(database))
        {
            await new MigrationRunner(data, NullLogger<MigrationRunner>.Instance).EnsureMigratedAsync(CancellationToken.None);
            // Spec economy-rewards: what a boss pays is a rule in the table. These tests' bosses pay 10 unless a test says otherwise.
            await using var rules = data.CreateCommand(
                """
                INSERT INTO reward_rules (source_kind, source_id, currency, amount, version, created_by)
                SELECT 'boss', id, 'gems', 10, 1, 'test' FROM unnest(ARRAY['boss.lich','boss.golem','boss.a','boss.b']) AS id
                """);
            await rules.ExecuteNonQueryAsync();
        }

        runner ??= new FakeReplayRunner();
        var values = new Dictionary<string, string?>
        {
            ["ConnectionStrings:Postgres"] = postgres ?? database,
            ["ConnectionStrings:Redis"] = redis ?? stack.RedisConnectionString,
            ["RabbitMq:Uri"] = stack.RabbitMq.GetConnectionString(),
            ["Verifier:RulesetVersion"] = FakeReplayRunner.Version,
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
        services.AddVerifierWorker();
        services.AddSingleton<IReplayRunner>(runner);
        var provider = services.BuildServiceProvider();
        var harness = new WorkerHarness(stack, provider, database, runner);
        harness.Metrics = new MetricsProbe(provider.GetRequiredService<IMeterFactory>());
        return harness;
    }

    /// <summary>One run owned by a new player, with a Submitted battle at seq 2.</summary>
    public async Task<SeededBattle> SeedAsync(string? ruleset = null, string status = "Submitted", Guid? player = null,
        string runStatus = "Active")
    {
        ruleset ??= FakeReplayRunner.Version;
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
              submitted_at) VALUES ($1, $2, 2, 1234567890123, $3, $4::jsonb, $5::jsonb, 'Submitted', now() - interval '3 seconds')
            """, battleId, runId, ruleset, JsonSerializer.Serialize(conditions, RpgJson.Options),
            JsonSerializer.Serialize(log, RpgJson.Options));
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

    /// <summary>A new version of a boss rule, as the API would write it.</summary>
    public Task PutRuleAsync(string boss, int amount, int version) => ExecuteAsync(
        "INSERT INTO reward_rules (source_kind, source_id, currency, amount, version, created_by) VALUES ('boss', $1, 'gems', $2, $3, 'test')",
        boss, amount, version);

    public static VerifyBattleJob JobOf(SeededBattle battle) =>
        new(battle.BattleId, battle.RunId, battle.Seq, battle.Ruleset, DateTimeOffset.UtcNow);

    public async Task<T?> ScalarAsync<T>(string sql, params object[] values)
    {
        await using var command = Command(sql, values);
        var result = await command.ExecuteScalarAsync();
        return result is null or DBNull ? default : (T)result;
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

    /// <summary>Starts the consumer and waits until it is attached to the queue.</summary>
    public async Task StartConsumerAsync(CancellationToken ct)
    {
        await Consumer.StartAsync(ct);
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (!State.Ready)
        {
            Assert.True(DateTime.UtcNow < deadline, "the consumer did not become ready");
            await Task.Delay(100, ct);
        }
    }

    public async ValueTask DisposeAsync()
    {
        Metrics.Dispose();
        try
        {
            await Consumer.StopAsync(CancellationToken.None);
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
    }

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
