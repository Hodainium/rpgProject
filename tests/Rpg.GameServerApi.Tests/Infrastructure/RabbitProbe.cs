using System.Text.Json;
using RabbitMQ.Client;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;
using Rpg.Verification;

namespace Rpg.GameServerApi.Tests.Infrastructure;

/// <summary>
/// Looks at the verify queue from outside (spec battle-verify 6). Tests of a collection run one at a time, so a test
/// purges the queues it reads first.
/// </summary>
public sealed class RabbitProbe : IAsyncDisposable
{
    private readonly IConnection _connection;
    private readonly IChannel _channel;

    private RabbitProbe(IConnection connection, IChannel channel)
    {
        _connection = connection;
        _channel = channel;
    }

    public static async Task<RabbitProbe> OpenAsync(string uri)
    {
        var connection = await new ConnectionFactory { Uri = new Uri(uri) }.CreateConnectionAsync();
        var channel = await connection.CreateChannelAsync();
        await VerifyMessaging.DeclareAsync(channel, CancellationToken.None);
        return new RabbitProbe(connection, channel);
    }

    /// <summary>Empties the main queue, the retry queues and the DLQ.</summary>
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

    /// <summary>Takes (and acks) every step job on verify.segment within a short wait (spec run-verify 3.4).</summary>
    public async Task<List<(VerifyStepJob Job, int Attempt)>> TakeStepsAsync(TimeSpan? wait = null)
    {
        var jobs = new List<(VerifyStepJob, int)>();
        var deadline = DateTime.UtcNow + (wait ?? TimeSpan.FromSeconds(3));
        while (DateTime.UtcNow < deadline)
        {
            var message = await _channel.BasicGetAsync(VerifyTopology.SegmentQueue, autoAck: true);
            if (message is null)
            {
                if (jobs.Count > 0)
                {
                    break;
                }

                await Task.Delay(100);
                continue;
            }

            jobs.Add((JsonSerializer.Deserialize<VerifyStepJob>(message.Body.Span, RpgJson.Options)!,
                VerifyMessaging.Attempt(message.BasicProperties)));
        }

        return jobs;
    }

    /// <summary>Takes (and acks) every job on <paramref name="queue"/> within a short wait.</summary>
    public async Task<List<(VerifyBattleJob Job, int Attempt)>> TakeAsync(string queue = VerifyTopology.Queue,
        TimeSpan? wait = null)
    {
        var jobs = new List<(VerifyBattleJob, int)>();
        var deadline = DateTime.UtcNow + (wait ?? TimeSpan.FromSeconds(3));
        while (DateTime.UtcNow < deadline)
        {
            var message = await _channel.BasicGetAsync(queue, autoAck: true);
            if (message is null)
            {
                if (jobs.Count > 0)
                {
                    break;
                }

                await Task.Delay(100);
                continue;
            }

            jobs.Add((JsonSerializer.Deserialize<VerifyBattleJob>(message.Body.Span, RpgJson.Options)!,
                VerifyMessaging.Attempt(message.BasicProperties)));
        }

        return jobs;
    }

    public async Task<uint> DepthAsync(string queue) => (await _channel.QueueDeclarePassiveAsync(queue)).MessageCount;

    public async ValueTask DisposeAsync()
    {
        await _channel.DisposeAsync();
        await _connection.DisposeAsync();
    }
}
