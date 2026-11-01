using RabbitMQ.Client;
using Rpg.Contracts.Battle;
using Rpg.GameServerApi.Infrastructure;
using Rpg.GameServerApi.Observability;
using Rpg.Verification;

namespace Rpg.GameServerApi.Battle;

/// <summary>
/// Publishes verify jobs to <c>verify.battle</c> with a publisher confirm (spec battle-verify 2.1). Never throws for a
/// broker problem: the caller gets false and the sweeper tries again (2.4).
/// </summary>
public sealed class VerifyJobPublisher(RabbitMqConnection rabbit, RpgMetrics metrics, ILogger<VerifyJobPublisher> logger)
{
    private static readonly TimeSpan PublishTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan GateTimeout = TimeSpan.FromSeconds(60);

    private readonly SemaphoreSlim _gate = new(1, 1);
    private IChannel? _channel;

    /// <param name="source">upload | sweeper (a metric label).</param>
    public async Task<bool> TryPublishAsync(VerifyBattleJob job, string source, CancellationToken ct)
    {
        try
        {
            // Waiting behind other publishers is not the broker being slow: the 5 s budget starts at the gate.
            using var turn = CancellationTokenSource.CreateLinkedTokenSource(ct);
            turn.CancelAfter(GateTimeout);
            await _gate.WaitAsync(turn.Token);
            try
            {
                using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
                limit.CancelAfter(PublishTimeout);
                var channel = await ChannelAsync(limit.Token);
                if (channel is null)
                {
                    metrics.VerifyJobPublished(source, "failed");
                    return false;
                }

                try
                {
                    await VerifyMessaging.PublishAsync(channel, VerifyTopology.Exchange, VerifyTopology.RoutingKey, job, 0,
                        null, limit.Token);
                }
                catch
                {
                    // A channel that failed a publish is not trusted again; the next call opens a new one.
                    _channel = null;
                    await channel.DisposeAsync();
                    throw;
                }
            }
            finally
            {
                _gate.Release();
            }

            metrics.VerifyJobPublished(source, "ok");
            return true;
        }
        catch (Exception ex) when (!(ex is OperationCanceledException && ct.IsCancellationRequested))
        {
            metrics.VerifyJobPublished(source, "failed");
            logger.LogWarning("Verify job for {BattleId} not published ({Message}); the sweeper will retry", job.BattleId,
                ex.Message);
            return false;
        }
    }

    /// <summary>
    /// Jobs waiting in <c>verify.battle</c> and the retry queues (ready messages; a job a worker is replaying is not
    /// counted, which is why workers renew the session's lease). Null when the broker cannot be asked.
    /// </summary>
    public async Task<long?> BacklogAsync(CancellationToken ct)
    {
        try
        {
            if (rabbit.OpenConnection is not { } connection)
            {
                return null;
            }

            await using var channel = await connection.CreateChannelAsync(cancellationToken: ct);
            await VerifyMessaging.DeclareAsync(channel, ct);  // idempotent; a queue never published to still exists
            long waiting = (await channel.QueueDeclarePassiveAsync(VerifyTopology.Queue, ct)).MessageCount;
            foreach (var tier in VerifyTopology.RetryTiers)
            {
                waiting += (await channel.QueueDeclarePassiveAsync(tier.Queue, ct)).MessageCount;
            }

            return waiting;
        }
        catch (Exception ex) when (!(ex is OperationCanceledException && ct.IsCancellationRequested))
        {
            logger.LogDebug("Verify backlog not read: {Message}", ex.Message);
            return null;
        }
    }

    /// <summary>The shared confirm channel, opened (and the topology declared) when there is none or it has closed.</summary>
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
            await channel.DisposeAsync();  // a failed declare must not leak a channel per attempt
            throw;
        }

        _channel = channel;
        return channel;
    }
}
