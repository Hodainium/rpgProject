using System.Diagnostics;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Verification;

namespace Rpg.VerifierWorker;

/// <summary>
/// The RabbitMQ side of the step pool (spec run-verify 3.4): <c>Verifier:Segment:Concurrency</c> consumers on
/// <c>verify.segment</c>, prefetch 1, manual acks. The shape is <see cref="VerifyConsumer"/>'s: a message is acked only
/// after the processor's decision has been carried out (the verdict is committed, or the job was published to a retry queue
/// or the DLQ and the broker confirmed it).
/// </summary>
public sealed class StepConsumer(IConfiguration configuration, StepProcessor processor, StepStore store, VerdictStore schema,
    IGodotProcess runner, WorkerState state, IOptions<VerifierOptions> options, WorkerMetrics metrics,
    ILogger<StepConsumer> logger) : BackgroundService
{
    private static readonly TimeSpan StartupRetry = TimeSpan.FromSeconds(2);

    private readonly SemaphoreSlim _publishGate = new(1, 1);
    private int _inFlight;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            while (state.RulesetVersion.Length == 0)
            {
                try
                {
                    state.SetRulesetVersion(await runner.RulesetVersionAsync(stoppingToken));
                }
                catch (InvalidOperationException ex)
                {
                    logger.LogWarning("Ruleset version not read ({Message}); retrying in {Interval}", ex.Message, StartupRetry);
                    await Task.Delay(StartupRetry, stoppingToken);
                }
            }

            await schema.WaitForSchemaAsync(StartupRetry, stoppingToken);
            var consumers = new List<(IChannel Channel, string Tag)>();
            await using var connection = await ConnectAsync(stoppingToken);
            connection.ConnectionShutdownAsync += (_, args) =>
            {
                if (args.Initiator != ShutdownInitiator.Application)
                {
                    state.SetReady(false);
                    logger.LogWarning("RabbitMQ connection lost: {Reason}", args.ReplyText);
                }

                return Task.CompletedTask;
            };
            connection.RecoverySucceededAsync += (_, _) =>
            {
                var allOpen = consumers.Count > 0 && consumers.All(c => c.Channel.IsOpen);
                state.SetReady(allOpen);
                return Task.CompletedTask;
            };
            await using var publishChannel = await connection.CreateChannelAsync(VerifyMessaging.ConfirmedChannel, stoppingToken);
            await VerifyMessaging.DeclareAsync(publishChannel, stoppingToken);

            for (var i = 0; i < Math.Max(1, options.Value.Segment.Concurrency); i++)
            {
                var channel = await connection.CreateChannelAsync(cancellationToken: stoppingToken);
                await channel.BasicQosAsync(0, 1, false, stoppingToken);
                channel.ChannelShutdownAsync += (_, args) =>
                {
                    if (args.Initiator != ShutdownInitiator.Application)
                    {
                        state.SetReady(false);
                        logger.LogError("Step consumer channel closed by {Initiator}: {Reason}", args.Initiator, args.ReplyText);
                    }

                    return Task.CompletedTask;
                };
                var consumer = new AsyncEventingBasicConsumer(channel);
                consumer.ReceivedAsync += (_, delivery) => HandleAsync(channel, publishChannel, delivery, stoppingToken);
                var tag = await channel.BasicConsumeAsync(VerifyTopology.SegmentQueue, autoAck: false, consumer, stoppingToken);
                consumers.Add((channel, tag));
            }

            state.SetReady(true);
            logger.LogInformation("Verifier consuming {Queue} with {Count} consumers", VerifyTopology.SegmentQueue, consumers.Count);
            try
            {
                await Task.Delay(Timeout.Infinite, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                // Shutting down.
            }

            state.SetReady(false);
            await DrainAsync(consumers);
        }
        catch (OperationCanceledException)
        {
            // Stopped before it started consuming.
        }
    }

    private async Task<IConnection> ConnectAsync(CancellationToken ct)
    {
        var factory = new ConnectionFactory
        {
            Uri = new Uri(configuration["RabbitMq:Uri"]
                          ?? throw new InvalidOperationException("RabbitMq:Uri is not configured.")),
            ClientProvidedName = "rpg-verifier-worker-segment",
            AutomaticRecoveryEnabled = true,
            NetworkRecoveryInterval = StartupRetry,
            RequestedConnectionTimeout = TimeSpan.FromSeconds(2),
        };
        while (true)
        {
            try
            {
                return await factory.CreateConnectionAsync(ct);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning("RabbitMQ unreachable ({Message}); retrying in {Interval}", ex.Message, StartupRetry);
                await Task.Delay(StartupRetry, ct);
            }
        }
    }

    private async Task DrainAsync(List<(IChannel Channel, string Tag)> consumers)
    {
        foreach (var (channel, tag) in consumers)
        {
            try
            {
                await channel.BasicCancelAsync(tag);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogDebug("Consumer {Tag} not cancelled: {Message}", tag, ex.Message);
            }
        }

        // A step replay may run for its whole timeout: the grace covers it (the host's own stop timeout is longer still).
        var grace = options.Value.ShutdownGrace > options.Value.Segment.ProcessTimeout
            ? options.Value.ShutdownGrace
            : options.Value.Segment.ProcessTimeout + TimeSpan.FromSeconds(10);
        var deadline = Stopwatch.StartNew();
        while (Volatile.Read(ref _inFlight) > 0 && deadline.Elapsed < grace)
        {
            await Task.Delay(100);
        }

        foreach (var (channel, _) in consumers)
        {
            try
            {
                await channel.CloseAsync();
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogDebug("Consumer channel closed with an error: {Message}", ex.Message);
            }
        }
    }

    /// <summary>One delivery; public so a test can drive a message without the whole startup.</summary>
    public async Task HandleAsync(IChannel channel, IChannel publishChannel, BasicDeliverEventArgs delivery,
        CancellationToken stoppingToken)
    {
        Interlocked.Increment(ref _inFlight);
        try
        {
            var ct = CancellationToken.None;
            ActivityContext.TryParse(VerifyMessaging.TraceParent(delivery.BasicProperties), null, out var parent);
            using var activity = WorkerTrace.Source.StartActivity("verify.step", ActivityKind.Consumer, parent);

            var job = VerifyMessaging.ParseStepJob(delivery.Body);
            if (job is null)
            {
                logger.LogWarning("Poison step message dropped to the DLQ");
                await PublishRawAsync(publishChannel, delivery, "poison: unreadable step job", ct);
                metrics.StepJob("dead_letter");
                await channel.BasicAckAsync(delivery.DeliveryTag, false, ct);
                return;
            }

            activity?.SetTag("rpg.step_no", job.StepNo);
            JobDecision decision;
            try
            {
                decision = await processor.ProcessAsync(job, ct);
            }
            catch (Exception ex)
            {
                // Unexpected: never loop on it. The main queue's dead-letter exchange sends a rejected message to the DLQ.
                logger.LogError(ex, "Step {Run}/{Step} failed unexpectedly", job.RunId, job.StepNo);
                metrics.StepJob("dead_letter");
                try
                {
                    await store.DeadLetterAsync(job.RunId, job.Epoch, job.StepNo, "error", DateTimeOffset.UtcNow, CancellationToken.None);
                }
                catch (Exception markFailure) when (markFailure is not OperationCanceledException)
                {
                    logger.LogWarning("Could not mark the step dead-lettered: {Message}", markFailure.Message);
                }

                await channel.BasicNackAsync(delivery.DeliveryTag, false, false, ct);
                return;
            }

            switch (decision.Action)
            {
                case JobAction.Retry:
                    await PublishAsync(publishChannel, VerifyTopology.Exchange, decision.Tier!.RoutingKey, job,
                        decision.Attempt, null, ct);
                    break;
                case JobAction.DeadLetter:
                    await PublishAsync(publishChannel, VerifyTopology.DeadLetterExchange, VerifyTopology.SegmentDeadRoutingKey, job,
                        VerifyMessaging.Attempt(delivery.BasicProperties), decision.Reason ?? "unknown", ct);
                    break;
            }

            await channel.BasicAckAsync(delivery.DeliveryTag, false, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // The publish or the ack failed (broker trouble): give the delivery back after a pause.
            logger.LogWarning("Delivery {Tag} not settled ({Message}); requeueing it", delivery.DeliveryTag, ex.Message);
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(1), CancellationToken.None);
                await channel.BasicNackAsync(delivery.DeliveryTag, false, requeue: true, CancellationToken.None);
            }
            catch (Exception nackFailure) when (nackFailure is not OperationCanceledException)
            {
                logger.LogDebug("Delivery {Tag} not requeued: {Message}", delivery.DeliveryTag, nackFailure.Message);
            }
        }
        finally
        {
            Interlocked.Decrement(ref _inFlight);
        }
    }

    private async Task PublishAsync(IChannel publishChannel, string exchange, string routingKey, VerifyStepJob job, int attempt,
        string? reason, CancellationToken ct)
    {
        await _publishGate.WaitAsync(ct);
        try
        {
            await VerifyMessaging.PublishAsync(publishChannel, exchange, routingKey, job, attempt, reason, ct);
        }
        finally
        {
            _publishGate.Release();
        }
    }

    private async Task PublishRawAsync(IChannel publishChannel, BasicDeliverEventArgs delivery, string reason, CancellationToken ct)
    {
        await _publishGate.WaitAsync(ct);
        try
        {
            var properties = new BasicProperties
            {
                Persistent = true,
                Headers = new Dictionary<string, object?> { [VerifyTopology.ReasonHeader] = reason },
            };
            await publishChannel.BasicPublishAsync(VerifyTopology.DeadLetterExchange, VerifyTopology.SegmentDeadRoutingKey, false,
                properties, delivery.Body, ct);
        }
        finally
        {
            _publishGate.Release();
        }
    }
}
