using System.Collections.Concurrent;
using Confluent.Kafka;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Npgsql;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Events;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.Outbox;
using Rpg.GameServerApi.Tests.Infrastructure;
using Rpg.Verification;
using static Rpg.GameServerApi.Tests.RunTests;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Spec settlement-outbox, the relay (sections 2.1, 2.3, 3.2, 3.4) and the failure rows F9â€“F13: ordering per key, backoff,
/// permanent versus transient failures, two relays, a crash after the publish, and (against a real Redpanda) acceptance
/// scenario 3. The relay runs by hand (<c>RunOnceAsync</c>) over fake sinks, so every case is deterministic.
/// </summary>
[Collection(StackCollection.Name)]
public class OutboxTests(StackFixture stack)
{
    private static readonly Dictionary<string, string?> Paused = new()
    {
        ["Outbox:Enabled"] = "false",
        ["Monitors:Interval"] = "01:00:00",
    };

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task Relay_PublishesInOrder_AndOnlyTheEarliestRowOfAKeyPerPass()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        var sink = new FakeSink(OutboxDestination.Redpanda);
        var relay = Relay(factory, sink);
        await InsertAsync(factory, "a", "a1");
        await InsertAsync(factory, "a", "a2");
        await InsertAsync(factory, "b", "b1");

        var first = await relay.RunOnceAsync(Ct);
        var second = await relay.RunOnceAsync(Ct);
        var third = await relay.RunOnceAsync(Ct);

        Assert.Equal((2, 1, 0), (first, second, third));  // a2 waits for a1: a key's rows never overtake each other
        Assert.Equal(["a1", "b1", "a2"], sink.Published.Select(r => r.Type));
        Assert.Equal(3L, await ScalarAsync(factory, "SELECT count(*) FROM outbox WHERE published_at IS NOT NULL"));
    }

    [Fact]
    public async Task Relay_ATransientFailure_BacksOff_AndBlocksOnlyThatKey()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        var sink = new FakeSink(OutboxDestination.Redpanda) { FailKeys = { "a" } };
        var relay = Relay(factory, sink, new OutboxOptions { BackoffBase = TimeSpan.FromMinutes(5), BackoffCap = TimeSpan.FromMinutes(5) });
        await InsertAsync(factory, "a", "a1");
        await InsertAsync(factory, "a", "a2");
        await InsertAsync(factory, "b", "b1");

        await relay.RunOnceAsync(Ct);
        await relay.RunOnceAsync(Ct);  // a1 is backing off, a2 is behind it, b1 is already out

        Assert.Equal(["b1"], sink.Published.Select(r => r.Type));
        Assert.Equal(1L, await ScalarAsync(factory, "SELECT attempts::bigint FROM outbox WHERE type = 'a1'"));  // the backoff pass leased nothing
        Assert.Equal(2L, await ScalarAsync(factory,
            "SELECT count(*) FROM outbox WHERE published_at IS NULL AND dead_lettered_at IS NULL"));

        sink.FailKeys.Clear();  // the destination heals; the backoff is cut short by hand
        await ExecuteAsync(factory, "UPDATE outbox SET leased_until = NULL WHERE type = 'a1'");
        await relay.RunOnceAsync(Ct);
        await relay.RunOnceAsync(Ct);

        Assert.Equal(["b1", "a1", "a2"], sink.Published.Select(r => r.Type));  // none lost, none reordered (scenario 3)
    }

    [Fact]
    public async Task APermanentlyBadRow_IsDeadLetteredAtOnce_AndTheKeysNextRowFlows()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        var sink = new FakeSink(OutboxDestination.Redpanda) { PermanentTypes = { "bad" } };
        var relay = Relay(factory, sink);
        await InsertAsync(factory, "a", "bad");
        await InsertAsync(factory, "a", "good");

        await relay.RunOnceAsync(Ct);
        await relay.RunOnceAsync(Ct);

        Assert.Equal(["good"], sink.Published.Select(r => r.Type));  // F13
        Assert.Equal(1L, await ScalarAsync(factory,
            "SELECT count(*) FROM outbox WHERE type = 'bad' AND dead_lettered_at IS NOT NULL AND attempts = 1"));
        Assert.Contains("boom", await TextAsync(factory, "SELECT dead_letter_reason FROM outbox WHERE type = 'bad'"));
    }

    [Fact]
    public async Task Relay_RedpandaRows_DeadLetterAtMaxAttempts_ButRabbitRowsNever()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        var redpanda = new FakeSink(OutboxDestination.Redpanda) { FailKeys = { "a" } };
        var rabbit = new FakeSink(OutboxDestination.Rabbit) { FailKeys = { "j" } };
        var relay = Relay(factory, redpanda, new OutboxOptions { MaxAttempts = 2, BackoffBase = TimeSpan.Zero }, rabbit);
        await InsertAsync(factory, "a", "event");
        await InsertAsync(factory, "j", "job", OutboxDestination.Rabbit);

        for (var i = 0; i < 4; i++)
        {
            await relay.RunOnceAsync(Ct);
        }

        Assert.Equal("attempts", await TextAsync(factory, "SELECT dead_letter_reason FROM outbox WHERE type = 'event'"));
        Assert.Equal(0L, await ScalarAsync(factory,
            "SELECT count(*) FROM outbox WHERE type = 'job' AND dead_lettered_at IS NOT NULL"));  // a verify job is never given up on
        Assert.Equal(4L, await ScalarAsync(factory, "SELECT attempts::bigint FROM outbox WHERE type = 'job'"));
    }

    [Fact]
    public async Task RelayCrashAfterPublish_PublishesAgain_WithTheSameEventId()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        var sink = new FakeSink(OutboxDestination.Redpanda);
        var relay = Relay(factory, sink);
        var id = await InsertAsync(factory, "a", "a1");
        await relay.RunOnceAsync(Ct);

        // The publish was confirmed but the process died before published_at was written.
        await ExecuteAsync(factory, "UPDATE outbox SET published_at = NULL, leased_until = NULL");
        await relay.RunOnceAsync(Ct);

        Assert.Equal([id, id], sink.Published.Select(r => r.Id));  // F11: at-least-once, same id, consumers dedupe
    }

    [Fact]
    public async Task ALeaseOfACrashedRelay_ExpiresAndTheRowIsTakenAgain()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        var store = factory.Services.GetRequiredService<OutboxStore>();
        await InsertAsync(factory, "a", "a1");
        var now = DateTimeOffset.UtcNow;

        var leased = await store.LeaseAsync(10, TimeSpan.FromSeconds(30), now, Ct);
        var during = await store.LeaseAsync(10, TimeSpan.FromSeconds(30), now.AddSeconds(5), Ct);
        var after = await store.LeaseAsync(10, TimeSpan.FromSeconds(30), now.AddSeconds(31), Ct);

        Assert.Single(leased);
        Assert.Empty(during);
        Assert.Equal(leased[0].Id, Assert.Single(after).Id);
        Assert.Equal(2, after[0].Attempts);
    }

    [Fact]
    public async Task TwoRelays_NeverPublishTheSameRowAtOnce_AndKeepKeyOrder()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        var published = new ConcurrentQueue<OutboxRow>();
        var slow = new FakeSink(OutboxDestination.Redpanda) { Delay = TimeSpan.FromMilliseconds(30), Shared = published };
        var relays = new[] { Relay(factory, slow), Relay(factory, slow) };
        foreach (var key in new[] { "k1", "k2", "k3", "k4" })
        {
            for (var n = 1; n <= 5; n++)
            {
                await InsertAsync(factory, key, $"{key}-{n}");
            }
        }

        await Task.WhenAll(relays.Select(async relay =>
        {
            for (var i = 0; i < 30; i++)
            {
                await relay.RunOnceAsync(Ct);
                await Task.Delay(10, Ct);
            }
        }));

        Assert.Equal(20, published.Count);
        Assert.Equal(20, published.Select(r => r.Id).Distinct().Count());  // F12: SKIP LOCKED plus the lease
        foreach (var key in new[] { "k1", "k2", "k3", "k4" })
        {
            Assert.Equal(Enumerable.Range(1, 5).Select(n => $"{key}-{n}"),
                published.Where(r => r.Key == key).Select(r => r.Type));
        }
    }

    [Fact]
    public async Task Monitor_ExportsTheOutboxLag()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        await InsertAsync(factory, "a", "a1");
        await InsertAsync(factory, "b", "dead");
        await ExecuteAsync(factory, "UPDATE outbox SET created_at = now() - interval '2 minutes' WHERE type = 'a1'");
        await ExecuteAsync(factory, "UPDATE outbox SET dead_lettered_at = now(), dead_letter_reason = 'x' WHERE type = 'dead'");

        await factory.Services.GetRequiredService<OutboxMonitor>().CountOnceAsync(Ct);
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_outbox_pending"));

        Assert.Equal("1", Sample(metrics, "rpg_outbox_pending", "destination=\"redpanda\""));
        Assert.Equal("1", Sample(metrics, "rpg_outbox_dead_lettered", "destination=\"redpanda\""));
        Assert.InRange(double.Parse(Sample(metrics, "rpg_outbox_oldest_unpublished_age_seconds", "destination=\"redpanda\"")!,
            System.Globalization.CultureInfo.InvariantCulture), 110, 200);
        Assert.Equal("0", Sample(metrics, "rpg_outbox_pending", "destination=\"rabbit\""));
    }

    // ---- against a real Redpanda ----

    [Fact]
    public async Task Relay_PublishesEventsToRedpanda_KeyedByPlayer_WithTheEventIdHeader()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        var relay = RealRelay(factory);
        var player = Guid.NewGuid().ToString("D");
        var ids = new List<Guid>();
        for (var n = 1; n <= 3; n++)
        {
            ids.Add(await InsertAsync(factory, player, EventTypes.BattleVerified, topic: EventTopics.Battle,
                payload: $"{{\"n\":{n}}}"));
        }

        for (var i = 0; i < 3; i++)
        {
            await relay.RunOnceAsync(Ct);
        }

        var received = await ConsumeAsync(EventTopics.Battle, player, 3);
        Assert.Equal(ids, received.Select(m => m.EventId));  // one key lands in one partition: order is kept
        Assert.Equal([1, 2, 3], received.Select(m => m.N));
        Assert.All(received, m => Assert.Equal(player, m.Key));
    }

    [Fact]
    public async Task RedpandaDown_RowsDrainInOrderWhenItReturns()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        var options = new OutboxOptions { KafkaMessageTimeout = TimeSpan.FromSeconds(3), BackoffBase = TimeSpan.Zero };
        var relay = RealRelay(factory, options);
        var player = Guid.NewGuid().ToString("D");
        var ids = new List<Guid>();
        for (var n = 1; n <= 4; n++)
        {
            ids.Add(await InsertAsync(factory, player, EventTypes.RewardGranted, topic: EventTopics.Economy,
                payload: $"{{\"n\":{n}}}"));
        }

        await relay.RunOnceAsync(Ct);  // warm: topics exist, the first row is out
        await Docker("pause", stack.Redpanda.Id);
        try
        {
            await relay.RunOnceAsync(Ct);  // fails after the message timeout; the row backs off
            await relay.RunOnceAsync(Ct);
            Assert.True(await ScalarAsync(factory,
                "SELECT count(*) FROM outbox WHERE published_at IS NULL AND dead_lettered_at IS NULL") >= 3);  // scenario 3: kept, not lost
        }
        finally
        {
            await Docker("unpause", stack.Redpanda.Id);
        }

        var deadline = DateTime.UtcNow.AddSeconds(60);
        while (await ScalarAsync(factory, "SELECT count(*) FROM outbox WHERE published_at IS NULL") > 0)
        {
            Assert.True(DateTime.UtcNow < deadline, "the outbox did not drain after Redpanda returned");
            await relay.RunOnceAsync(Ct);
            await Task.Delay(200, Ct);
        }

        var received = await ConsumeAsync(EventTopics.Economy, player, 4);
        Assert.Equal(ids, received.Select(m => m.EventId));  // all four, in order, none lost
    }

    [Fact]
    public async Task ARowForAnUnknownTopic_IsDeadLetteredAtOnce_ByTheRealSink()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        var relay = RealRelay(factory);
        await InsertAsync(factory, Guid.NewGuid().ToString("D"), "Weird", topic: "not.a.topic");

        await relay.RunOnceAsync(Ct);

        Assert.Equal(1L, await ScalarAsync(factory,
            "SELECT count(*) FROM outbox WHERE type = 'Weird' AND dead_lettered_at IS NOT NULL"));
    }

    // ---- helpers ----

    // ---- Trace continuity (spec economy-rewards 3.8, F11) ----

    [Fact]
    public async Task ThePublishSpan_IsAChildOfTheSpanThatWroteTheRow()
    {
        var started = new ConcurrentQueue<System.Diagnostics.Activity>();
        using var listener = new System.Diagnostics.ActivityListener
        {
            ShouldListenTo = source => source.Name == OutboxRelay.Source.Name,
            Sample = (ref System.Diagnostics.ActivityCreationOptions<System.Diagnostics.ActivityContext> _) =>
                System.Diagnostics.ActivitySamplingResult.AllDataAndRecorded,
            ActivityStarted = started.Enqueue,
        };
        System.Diagnostics.ActivitySource.AddActivityListener(listener);
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        var sink = new FakeSink(OutboxDestination.Redpanda);
        var traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
        await InsertAsync(factory, "a", "traced", traceParent: traceparent);

        await Relay(factory, sink).RunOnceAsync(Ct);

        var publish = Assert.Single(started, a => a.OperationName == "outbox.publish");
        Assert.Equal(System.Diagnostics.ActivityTraceId.CreateFromString("0af7651916cd43dd8448eb211c80319c"), publish.TraceId);
        Assert.Equal("b7ad6b7169203331", publish.ParentSpanId.ToString());
        Assert.Equal(traceparent, Assert.Single(sink.Published).TraceParent);  // the sinks send this as the traceparent header
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not-a-traceparent")]
    [InlineData("00-zzzz-yyyy-01")]
    public async Task ARowWithNoOrAMalformedTraceParent_StillPublishes(string? traceparent)
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Paused);
        var sink = new FakeSink(OutboxDestination.Redpanda);
        await InsertAsync(factory, "a", "plain", traceParent: traceparent ?? "", clearTrace: traceparent is null);

        var published = await Relay(factory, sink).RunOnceAsync(Ct);

        Assert.Equal(1, published);  // F11: no parent span, no failure, no retry
        Assert.Equal(["plain"], sink.Published.Select(r => r.Type));
        Assert.Equal(0L, await ScalarAsync(factory, "SELECT attempts::bigint FROM outbox") - 1);
        Assert.Equal(1L, await ScalarAsync(factory, "SELECT count(*) FROM outbox WHERE published_at IS NOT NULL AND dead_lettered_at IS NULL"));
    }

    private OutboxRelay Relay(ApiFactory factory, FakeSink redpanda, OutboxOptions? options = null, FakeSink? rabbit = null) =>
        new(factory.Services.GetRequiredService<OutboxStore>(), rabbit is null ? [redpanda] : [redpanda, rabbit],
            Options.Create(options ?? new OutboxOptions { BackoffBase = TimeSpan.Zero }),
            factory.Services.GetRequiredService<RpgMetrics>(), TimeProvider.System, NullLogger<OutboxRelay>.Instance);

    private OutboxRelay RealRelay(ApiFactory factory, OutboxOptions? options = null)
    {
        options ??= new OutboxOptions { BackoffBase = TimeSpan.Zero };
        var sink = new KafkaOutboxSink(Options.Create(new KafkaOptions { BootstrapServers = stack.RedpandaBootstrap }),
            Options.Create(options), NullLogger<KafkaOutboxSink>.Instance);
        return new OutboxRelay(factory.Services.GetRequiredService<OutboxStore>(), [sink], Options.Create(options),
            factory.Services.GetRequiredService<RpgMetrics>(), TimeProvider.System, NullLogger<OutboxRelay>.Instance);
    }

    /// <summary>A row written the way the worker writes one; the payload is a stand-in the consumer can read back.</summary>
    private static async Task<Guid> InsertAsync(ApiFactory factory, string key, string type,
        string destination = OutboxDestination.Redpanda, string? topic = null, string payload = "{}",
        string? traceParent = null, bool clearTrace = false)
    {
        var id = Guid.NewGuid();
        await factory.Services.GetRequiredService<MigrationRunner>().EnsureMigratedAsync(Ct);
        await using var connection = await factory.Services.GetRequiredService<NpgsqlDataSource>().OpenConnectionAsync(Ct);
        await using var transaction = await connection.BeginTransactionAsync(Ct);
        await OutboxWriter.InsertAsync(connection, transaction, new OutboxMessage(id, destination,
            topic ?? (destination == OutboxDestination.Rabbit ? VerifyTopology.RoutingKey : EventTopics.Battle), key, type,
            payload, traceParent), Ct);
        await transaction.CommitAsync(Ct);
        if (clearTrace)
        {
            await ExecuteAsync(factory, $"UPDATE outbox SET traceparent = NULL WHERE id = '{id}'");
        }

        return id;
    }

    private static async Task ExecuteAsync(ApiFactory factory, string sql)
    {
        await factory.Services.GetRequiredService<MigrationRunner>().EnsureMigratedAsync(Ct);
        await using var command = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(sql);
        await command.ExecuteNonQueryAsync(Ct);
    }

    private static async Task<string> TextAsync(ApiFactory factory, string sql)
    {
        await using var command = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(sql);
        return (string)(await command.ExecuteScalarAsync(Ct))!;
    }

    private static string? Sample(string metrics, string name, params string[] labels) =>
        metrics.Split('\n')
            .Where(line => (line.StartsWith(name + "{", StringComparison.Ordinal) || line.StartsWith(name + " ", StringComparison.Ordinal))
                           && labels.All(line.Contains))
            .Select(line => line[(Math.Max(line.LastIndexOf('}'), name.Length - 1) + 1)..].Trim().Split(' ')[0])
            .FirstOrDefault();

    private sealed record Received(Guid EventId, string Key, int N);

    /// <summary>Reads a topic from the start until <paramref name="count"/> messages with this key have arrived.</summary>
    private async Task<List<Received>> ConsumeAsync(string topic, string key, int count)
    {
        using var consumer = new ConsumerBuilder<string, string>(new ConsumerConfig
        {
            BootstrapServers = stack.RedpandaBootstrap,
            GroupId = "test-" + Guid.NewGuid().ToString("N"),
            AutoOffsetReset = AutoOffsetReset.Earliest,
            EnableAutoCommit = false,
        }).Build();
        consumer.Subscribe(topic);
        var received = new List<Received>();
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (received.Count < count && DateTime.UtcNow < deadline)
        {
            var result = consumer.Consume(TimeSpan.FromMilliseconds(500));
            if (result is null || result.Message.Key != key)
            {
                continue;
            }

            var id = Guid.Parse(System.Text.Encoding.UTF8.GetString(result.Message.Headers.GetLastBytes("event-id")));
            using var document = System.Text.Json.JsonDocument.Parse(result.Message.Value);
            received.Add(new Received(id, result.Message.Key, document.RootElement.GetProperty("n").GetInt32()));
        }

        return received;
    }

    private static async Task Docker(string verb, string container)
    {
        using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("docker", $"{verb} {container}")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        })!;
        await process.WaitForExitAsync(Ct);
        Assert.Equal(0, process.ExitCode);
    }

    private sealed class FakeSink(string destination) : IOutboxSink
    {
        private readonly object _gate = new();
        private readonly List<OutboxRow> _published = [];

        public string Destination => destination;

        public HashSet<string> FailKeys { get; } = [];

        public HashSet<string> PermanentTypes { get; } = [];

        public TimeSpan Delay { get; init; }

        public ConcurrentQueue<OutboxRow>? Shared { get; init; }

        public IReadOnlyList<OutboxRow> Published
        {
            get
            {
                lock (_gate)
                {
                    return [.. _published];
                }
            }
        }

        public async Task PublishAsync(OutboxRow row, CancellationToken ct)
        {
            if (Delay > TimeSpan.Zero)
            {
                await Task.Delay(Delay, ct);
            }

            if (PermanentTypes.Contains(row.Type))
            {
                throw new OutboxPermanentException("boom: cannot serialise");
            }

            if (FailKeys.Contains(row.Key))
            {
                throw new InvalidOperationException("the destination is down");
            }

            lock (_gate)
            {
                _published.Add(row);
            }

            Shared?.Enqueue(row);
        }
    }
}
