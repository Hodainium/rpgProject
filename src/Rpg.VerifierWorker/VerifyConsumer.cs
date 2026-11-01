using System.Diagnostics;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using Rpg.Contracts.Battle;
using Rpg.Verification;

namespace Rpg.VerifierWorker;

/// <summary>
/// The RabbitMQ side of the worker (spec battle-verify 2.1, 2.3): <c>Verifier:Concurrency</c> consumers with prefetch 1.
/// A message is acked only after the processor's decision has been carried out (the verdict is committed, or the job was
/// published to a retry queue or the DLQ and the broker confirmed it).
/// </summary>
public sealed class VerifyConsumer(IConfiguration configuration, VerifyProcessor processor, VerdictStore store,
    IReplayRunner runner, WorkerState state, IOptions<VerifierOptions> options, WorkerMetrics metrics,
    ILogger<VerifyConsumer> logger) : BackgroundService
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
                    // A cold or slow Godot start must leave the worker not-ready and trying again, never stopped.
                    logger.LogWarning("Ruleset version not read ({Message}); retrying in {Interval}", ex.Message, StartupRetry);
                    await Task.Delay(StartupRetry, stoppingToken);
                }
            }

            logger.LogInformation("Verifier ruleset version {Version}", state.RulesetVersion);
            await store.WaitForSchemaAsync(StartupRetry, stoppingToken);
            var consumers = new List<(IChannel Channel, string Tag)>();
            await using var connection = await ConnectAsync(stoppingToken);
            // Readiness follows the connection: down while it is shut, up again when automatic recovery succeeds.
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
                // Ready again only when every consumer channel is open: one the broker closed is not brought back.
                var allOpen = consumers.Count > 0 && consumers.All(c => c.Channel.IsOpen);
                state.SetReady(allOpen);
                logger.LogInformation("RabbitMQ connection recovered; {State}", allOpen ? "consuming" : "a consumer channel is closed");
                return Task.CompletedTask;
            };
            await using var publishChannel = await connection.CreateChannelAsync(VerifyMessaging.ConfirmedChannel, stoppingToken);
            await VerifyMessaging.DeclareAsync(publishChannel, stoppingToken);

            for (var i = 0; i < Math.Max(1, options.Value.Concurrency); i++)
            {
                var channel = await connection.CreateChannelAsync(cancellationToken: stoppingToken);
                await channel.BasicQosAsync(0, 1, false, stoppingToken);
                // A channel the broker closes (a failed precondition, say) takes its consumer with it and nothing
                // brings it back: not ready, so the failure is visible.
                channel.ChannelShutdownAsync += (_, args) =>
                {
                    if (args.Initiator != ShutdownInitiator.Application)
                    {
                        state.SetReady(false);
                        logger.LogError("Consumer channel closed by {Initiator}: {Reason}", args.Initiator, args.ReplyText);
                    }

                    return Task.CompletedTask;
                };
                var consumer = new AsyncEventingBasicConsumer(channel);
                consumer.ReceivedAsync += (_, delivery) => HandleAsync(channel, publishChannel, delivery, stoppingToken);
                var tag = await channel.BasicConsumeAsync(VerifyTopology.Queue, autoAck: false, consumer, stoppingToken);
                consumers.Add((channel, tag));
            }

            state.SetReady(true);
            logger.LogInformation("Verifier consuming {Queue} with {Count} consumers", VerifyTopology.Queue, consumers.Count);
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
            ClientProvidedName = "rpg-verifier-worker",
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

    /// <summary>Stop taking jobs, let the running ones finish within the grace period; unacked ones go back to the broker.</summary>
    private async Task DrainAsync(List<(IChannel Channel, string Tag)> consumers)
    {
        // Cancel the consumers first, so the broker sends nothing new while the running jobs finish.
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

        var deadline = Stopwatch.StartNew();
        while (Volatile.Read(ref _inFlight) > 0 && deadline.Elapsed < options.Value.ShutdownGrace)
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
            // The grace period belongs to shutdown: a running job is not cancelled by the stop signal.
            var ct = CancellationToken.None;
            ActivityContext.TryParse(VerifyMessaging.TraceParent(delivery.BasicProperties), null, out var parent);
            using var activity = VerifyProcessor.Source.StartActivity("verify.battle", ActivityKind.Consumer, parent);

            var job = VerifyMessaging.ParseJob(delivery.Body);
            if (job is null)
            {
                logger.LogWarning("Poison message dropped to the DLQ");
                await DeadLetterAsync(publishChannel, delivery, "poison: unreadable job", ct);
                metrics.Job("dead_lettered");
                await channel.BasicAckAsync(delivery.DeliveryTag, false, ct);
                return;
            }

            activity?.SetTag("rpg.battle_id", job.BattleId);
            JobDecision decision;
            try
            {
                decision = await processor.ProcessAsync(job, ct);
            }
            catch (Exception ex)
            {
                // Unexpected: never loop on it. The main queue's dead-letter exchange sends a rejected message to the DLQ.
                logger.LogError(ex, "Verify of {BattleId} failed unexpectedly", job.BattleId);
                metrics.Job("dead_lettered");
                try
                {
                    // Without this mark the API sweeper would republish the same poison battle every RepublishAfter.
                    await store.DeadLetterAsync(job.BattleId, "error", DateTimeOffset.UtcNow, CancellationToken.None);
                }
                catch (Exception markFailure) when (markFailure is not OperationCanceledException)
                {
                    logger.LogWarning("Could not mark {BattleId} dead-lettered: {Message}", job.BattleId, markFailure.Message);
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
                    await DeadLetterAsync(publishChannel, delivery, decision.Reason ?? "unknown", ct, job);
                    break;
            }

            await channel.BasicAckAsync(delivery.DeliveryTag, false, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // The publish or the ack failed (broker trouble). An unacked message is not redelivered while its channel stays
            // open, and with prefetch 1 this consumer would take nothing more: give it back explicitly, after a pause so a
            // persistent failure does not spin. The processor treats a repeat as a duplicate or replays again, both safe.
            logger.LogWarning("Delivery {Tag} not settled ({Message}); requeueing it", delivery.DeliveryTag, ex.Message);
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(1), CancellationToken.None);
                await channel.BasicNackAsync(delivery.DeliveryTag, false, requeue: true, CancellationToken.None);
            }
            catch (Exception nackFailure) when (nackFailure is not OperationCanceledException)
            {
                // The channel is gone: the broker requeues everything unacked on it.
                logger.LogDebug("Delivery {Tag} not requeued: {Message}", delivery.DeliveryTag, nackFailure.Message);
            }
        }
        finally
        {
            Interlocked.Decrement(ref _inFlight);
        }
    }

    private async Task DeadLetterAsync(IChannel publishChannel, BasicDeliverEventArgs delivery, string reason,
        CancellationToken ct, VerifyBattleJob? job = null)
    {
        if (job is null)
        {
            await PublishRawAsync(publishChannel, delivery, reason, ct);
        }
        else
        {
            await PublishAsync(publishChannel, VerifyTopology.DeadLetterExchange, VerifyTopology.DeadRoutingKey, job,
                VerifyMessaging.Attempt(delivery.BasicProperties), reason, ct);
        }
    }

    private async Task PublishAsync(IChannel publishChannel, string exchange, string routingKey, VerifyBattleJob job,
        int attempt, string? reason, CancellationToken ct)
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

    /// <summary>An unreadable body is forwarded as it is, with the reason.</summary>
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
            await publishChannel.BasicPublishAsync(VerifyTopology.DeadLetterExchange, VerifyTopology.DeadRoutingKey, false,
                properties, delivery.Body, ct);
        }
        finally
        {
            _publishGate.Release();
        }
    }
}
