using System.Diagnostics;
using System.Text.Json;
using RabbitMQ.Client;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;

namespace Rpg.Verification;

/// <summary>
/// The verify.battle topology and message format (spec battle-verify 3.3), declared idempotently by both the API and
/// the worker. Queues are durable and classic; retry queues hold a job for their message TTL, then dead-letter it back
/// to the main queue through the verify exchange.
/// </summary>
public static class VerifyMessaging
{
    public const string TraceParentHeader = "traceparent";

    public static async Task DeclareAsync(IChannel channel, CancellationToken ct)
    {
        await channel.ExchangeDeclareAsync(VerifyTopology.Exchange, ExchangeType.Direct, durable: true, cancellationToken: ct);
        await channel.ExchangeDeclareAsync(VerifyTopology.DeadLetterExchange, ExchangeType.Direct, durable: true,
            cancellationToken: ct);

        await channel.QueueDeclareAsync(VerifyTopology.DeadLetterQueue, durable: true, exclusive: false, autoDelete: false,
            cancellationToken: ct);
        await channel.QueueBindAsync(VerifyTopology.DeadLetterQueue, VerifyTopology.DeadLetterExchange,
            VerifyTopology.DeadRoutingKey, cancellationToken: ct);

        // A message nacked without requeue lands in the DLQ (a safety net; the worker dead-letters explicitly).
        await channel.QueueDeclareAsync(VerifyTopology.Queue, durable: true, exclusive: false, autoDelete: false,
            arguments: new Dictionary<string, object?>
            {
                ["x-dead-letter-exchange"] = VerifyTopology.DeadLetterExchange,
                ["x-dead-letter-routing-key"] = VerifyTopology.DeadRoutingKey,
            }, cancellationToken: ct);
        await channel.QueueBindAsync(VerifyTopology.Queue, VerifyTopology.Exchange, VerifyTopology.RoutingKey,
            cancellationToken: ct);

        foreach (var tier in VerifyTopology.RetryTiers)
        {
            await channel.QueueDeclareAsync(tier.Queue, durable: true, exclusive: false, autoDelete: false,
                arguments: new Dictionary<string, object?>
                {
                    ["x-message-ttl"] = (int)tier.Delay.TotalMilliseconds,
                    ["x-dead-letter-exchange"] = VerifyTopology.Exchange,
                    ["x-dead-letter-routing-key"] = VerifyTopology.RoutingKey,
                }, cancellationToken: ct);
            await channel.QueueBindAsync(tier.Queue, VerifyTopology.Exchange, tier.RoutingKey, cancellationToken: ct);
        }

        // Spec run-verify 3.4: the step queue, its retry tiers and its own dead-letter queue.
        await channel.QueueDeclareAsync(VerifyTopology.SegmentDeadLetterQueue, durable: true, exclusive: false,
            autoDelete: false, cancellationToken: ct);
        await channel.QueueBindAsync(VerifyTopology.SegmentDeadLetterQueue, VerifyTopology.DeadLetterExchange,
            VerifyTopology.SegmentDeadRoutingKey, cancellationToken: ct);
        await channel.QueueDeclareAsync(VerifyTopology.SegmentQueue, durable: true, exclusive: false, autoDelete: false,
            arguments: new Dictionary<string, object?>
            {
                ["x-dead-letter-exchange"] = VerifyTopology.DeadLetterExchange,
                ["x-dead-letter-routing-key"] = VerifyTopology.SegmentDeadRoutingKey,
            }, cancellationToken: ct);
        await channel.QueueBindAsync(VerifyTopology.SegmentQueue, VerifyTopology.Exchange,
            VerifyTopology.SegmentRoutingKey, cancellationToken: ct);
        foreach (var tier in VerifyTopology.SegmentRetryTiers)
        {
            await channel.QueueDeclareAsync(tier.Queue, durable: true, exclusive: false, autoDelete: false,
                arguments: new Dictionary<string, object?>
                {
                    ["x-message-ttl"] = (int)tier.Delay.TotalMilliseconds,
                    ["x-dead-letter-exchange"] = VerifyTopology.Exchange,
                    ["x-dead-letter-routing-key"] = VerifyTopology.SegmentRoutingKey,
                }, cancellationToken: ct);
            await channel.QueueBindAsync(tier.Queue, VerifyTopology.Exchange, tier.RoutingKey, cancellationToken: ct);
        }
    }

    public static byte[] Body(VerifyStepJob job) => JsonSerializer.SerializeToUtf8Bytes(job, RpgJson.Options);

    /// <summary>Null when the body isn't a usable step job (a poison message).</summary>
    public static VerifyStepJob? ParseStepJob(ReadOnlyMemory<byte> body)
    {
        try
        {
            var job = JsonSerializer.Deserialize<VerifyStepJob>(body.Span, RpgJson.Options);
            return job is { RulesetVersion.Length: > 0, StepNo: >= 0, Epoch: >= 0 } && job.RunId != Guid.Empty ? job : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>The retry tier for the n-th failed attempt (1-based) on the step queue.</summary>
    public static RetryTier SegmentTierForAttempt(int attempt) =>
        VerifyTopology.SegmentRetryTiers[Math.Clamp(attempt, 1, VerifyTopology.SegmentRetryTiers.Count) - 1];

    public static Task PublishAsync(IChannel channel, string exchange, string routingKey, VerifyStepJob job,
        int attempt, string? reason, CancellationToken ct) =>
        PublishBodyAsync(channel, exchange, routingKey, Body(job), attempt, reason, ct);

    public static byte[] Body(VerifyBattleJob job) => JsonSerializer.SerializeToUtf8Bytes(job, RpgJson.Options);

    /// <summary>Null when the body isn't a usable job (a poison message).</summary>
    public static VerifyBattleJob? ParseJob(ReadOnlyMemory<byte> body)
    {
        try
        {
            var job = JsonSerializer.Deserialize<VerifyBattleJob>(body.Span, RpgJson.Options);
            return job is { BattleId.Length: > 0 } && job.RunId != Guid.Empty ? job : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// Publishes a job and waits for the broker's confirm (the channel must have publisher confirmations on). Persistent;
    /// carries the attempt count and the current trace context.
    /// </summary>
    public static Task PublishAsync(IChannel channel, string exchange, string routingKey, VerifyBattleJob job,
        int attempt, string? reason, CancellationToken ct) =>
        PublishBodyAsync(channel, exchange, routingKey, Body(job), attempt, reason, ct);

    private static async Task PublishBodyAsync(IChannel channel, string exchange, string routingKey, byte[] body,
        int attempt, string? reason, CancellationToken ct)
    {
        var headers = new Dictionary<string, object?> { [VerifyTopology.AttemptHeader] = attempt };
        if (reason is not null)
        {
            headers[VerifyTopology.ReasonHeader] = reason;
        }

        if (Activity.Current is { } activity)
        {
            headers[TraceParentHeader] = activity.Id;
        }

        var properties = new BasicProperties
        {
            Persistent = true,
            ContentType = "application/json",
            Headers = headers,
        };
        await channel.BasicPublishAsync(exchange, routingKey, mandatory: false, properties, body, ct);
    }

    /// <summary>The channel options for publishing: confirms on, tracked per publish.</summary>
    public static CreateChannelOptions ConfirmedChannel { get; } =
        new(publisherConfirmationsEnabled: true, publisherConfirmationTrackingEnabled: true);

    public static int Attempt(IReadOnlyBasicProperties properties) =>
        properties.Headers is { } headers && headers.TryGetValue(VerifyTopology.AttemptHeader, out var value)
            ? value switch { int i => i, long l => (int)l, byte[] b when int.TryParse(System.Text.Encoding.UTF8.GetString(b), out var p) => p, _ => 0 }
            : 0;

    public static string? TraceParent(IReadOnlyBasicProperties properties) =>
        properties.Headers is { } headers && headers.TryGetValue(TraceParentHeader, out var value)
            ? value switch { byte[] b => System.Text.Encoding.UTF8.GetString(b), string s => s, _ => null }
            : null;
}
