using System.Text;
using Confluent.Kafka;
using Confluent.Kafka.Admin;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Events;
using Rpg.GameServerApi.Infrastructure;
using Rpg.Verification;

namespace Rpg.GameServerApi.Outbox;

/// <summary>A failure that retrying cannot fix: a row that cannot be serialised, an unknown topic, a message too large.</summary>
public sealed class OutboxPermanentException(string reason) : Exception(reason);

/// <summary>Where the relay sends rows of one destination. Throws on any failure; a transient one is simply retried.</summary>
public interface IOutboxSink
{
    string Destination { get; }

    Task PublishAsync(OutboxRow row, CancellationToken ct);
}

/// <summary>
/// RabbitMQ: verify jobs onto <c>verify.battle</c> with a publisher confirm (spec battle-verify 2.1, settlement-outbox 2.1).
/// One shared confirm channel; a channel that failed a publish is never trusted again.
/// </summary>
public sealed class RabbitOutboxSink(RabbitMqConnection rabbit) : IOutboxSink
{
    private static readonly TimeSpan PublishTimeout = TimeSpan.FromSeconds(5);

    private readonly SemaphoreSlim _gate = new(1, 1);
    private IChannel? _channel;

    public string Destination => OutboxDestination.Rabbit;

    public async Task PublishAsync(OutboxRow row, CancellationToken ct)
    {
        if (row.Topic is not (VerifyTopology.RoutingKey or VerifyTopology.SegmentRoutingKey))
        {
            throw new OutboxPermanentException($"unknown routing key '{row.Topic}'");
        }

        // Spec run-verify 3.4: a step job goes to verify.segment; anything else on this destination is a battle job.
        var segment = row.Topic == VerifyTopology.SegmentRoutingKey;
        var bytes = Encoding.UTF8.GetBytes(row.PayloadJson);
        var job = segment ? null : VerifyMessaging.ParseJob(bytes)
                  ?? throw new OutboxPermanentException("the payload is not a verify job");
        var stepJob = segment ? VerifyMessaging.ParseStepJob(bytes)
                  ?? throw new OutboxPermanentException("the payload is not a step job") : null;

        await _gate.WaitAsync(ct);
        try
        {
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
            limit.CancelAfter(PublishTimeout);
            var channel = await ChannelAsync(limit.Token) ?? throw new InvalidOperationException("RabbitMQ is not connected");
            try
            {
                if (stepJob is not null)
                {
                    await VerifyMessaging.PublishAsync(channel, VerifyTopology.Exchange, VerifyTopology.SegmentRoutingKey,
                        stepJob, 0, null, limit.Token);
                }
                else
                {
                    await VerifyMessaging.PublishAsync(channel, VerifyTopology.Exchange, VerifyTopology.RoutingKey, job!, 0,
                        null, limit.Token);
                }
            }
            catch
            {
                _channel = null;
                await channel.DisposeAsync();
                throw;
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<IChannel?> ChannelAsync(CancellationToken ct)
    {
        if (_channel is { IsOpen: true } open)
        {
            return open;
        }

        if (rabbit.OpenConnection is not { } connection)
        {
            return null;
        }

        var channel = await connection.CreateChannelAsync(VerifyMessaging.ConfirmedChannel, ct);
        try
        {
            await VerifyMessaging.DeclareAsync(channel, ct);
        }
        catch
        {
            await channel.DisposeAsync();
            throw;
        }

        _channel = channel;
        return channel;
    }
}

/// <summary>
/// Redpanda (Kafka API): domain events with an idempotent producer, <c>acks=all</c>, keyed by player so one player's
/// events stay in order (spec settlement-outbox 3.4). Topics are created on first use.
/// </summary>
public sealed class KafkaOutboxSink(IOptions<KafkaOptions> kafka, IOptions<OutboxOptions> options, ILogger<KafkaOutboxSink> logger)
    : IOutboxSink, IDisposable
{
    public static readonly IReadOnlyList<string> Topics =
        [EventTopics.Battle, EventTopics.Economy, EventTopics.Run, EventTopics.Security];

    private IProducer<string, string>? _producer;

    private IProducer<string, string> Producer() => _producer ??= new ProducerBuilder<string, string>(new ProducerConfig
    {
        BootstrapServers = kafka.Value.BootstrapServers,
        ClientId = "rpg-game-server-api",
        EnableIdempotence = true,
        Acks = Acks.All,
        LingerMs = 5,
        MessageTimeoutMs = (int)options.Value.KafkaMessageTimeout.TotalMilliseconds,
        SocketTimeoutMs = Math.Min(5000, (int)options.Value.KafkaMessageTimeout.TotalMilliseconds),
    }).Build();

    private volatile bool _topicsReady;

    public string Destination => OutboxDestination.Redpanda;

    public async Task PublishAsync(OutboxRow row, CancellationToken ct)
    {
        if (!Topics.Contains(row.Topic))
        {
            throw new OutboxPermanentException($"unknown topic '{row.Topic}'");
        }

        await EnsureTopicsAsync();
        var message = new Message<string, string>
        {
            Key = row.Key,
            Value = row.PayloadJson,
            Headers = new Confluent.Kafka.Headers
            {
                { "event-id", Encoding.UTF8.GetBytes(row.Id.ToString("D")) },
                { "type", Encoding.UTF8.GetBytes(row.Type) },
                { "schema-version", Encoding.UTF8.GetBytes("1") },
            },
        };
        if (row.TraceParent is { } traceParent)
        {
            message.Headers.Add("traceparent", Encoding.UTF8.GetBytes(traceParent));
        }

        try
        {
            await Producer().ProduceAsync(row.Topic, message, ct);
        }
        catch (ProduceException<string, string> ex) when (ex.Error.Code is ErrorCode.MsgSizeTooLarge or ErrorCode.InvalidMsgSize)
        {
            throw new OutboxPermanentException(ex.Error.Reason);
        }
        catch (ProduceException<string, string> ex) when (ex.Error.IsFatal)
        {
            // An idempotent producer that hit a fatal error (a gap after a long outage) is unusable: build a new one.
            logger.LogWarning("Redpanda producer failed fatally ({Reason}); it is replaced", ex.Error.Reason);
            _producer?.Dispose();
            _producer = null;
            throw;
        }
    }

    private async Task EnsureTopicsAsync()
    {
        if (_topicsReady)
        {
            return;
        }

        using var admin = new AdminClientBuilder(new AdminClientConfig
        {
            BootstrapServers = kafka.Value.BootstrapServers,
            SocketTimeoutMs = Math.Min(5000, (int)options.Value.KafkaMessageTimeout.TotalMilliseconds),
        }).Build();
        try
        {
            await admin.CreateTopicsAsync(Topics.Select(topic => new TopicSpecification
            {
                Name = topic,
                NumPartitions = 3,
                ReplicationFactor = 1,
                Configs = new Dictionary<string, string>
                {
                    ["retention.ms"] = TimeSpan.FromDays(7).TotalMilliseconds.ToString("F0"),
                },
            }), new CreateTopicsOptions { RequestTimeout = options.Value.KafkaMessageTimeout });
        }
        catch (CreateTopicsException ex) when (ex.Results.All(r => r.Error.Code is ErrorCode.NoError or ErrorCode.TopicAlreadyExists))
        {
            // Already there: fine.
        }

        _topicsReady = true;
        logger.LogInformation("Redpanda topics ready: {Topics}", string.Join(", ", Topics));
    }

    public void Dispose()
    {
        _producer?.Dispose();
    }
}
