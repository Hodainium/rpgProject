using RabbitMQ.Client;
using RabbitMQ.Client.Exceptions;

namespace Rpg.GameServerApi.Infrastructure;

/// <summary>
/// Owns the one long-lived RabbitMQ connection. Retries the initial connect in the background so startup never
/// blocks; after that, the client's automatic recovery reconnects when the broker comes back.
/// No exchanges or queues are declared here (slice 3 adds them).
/// </summary>
public sealed class RabbitMqConnection(IConfiguration configuration, ILogger<RabbitMqConnection> logger)
    : BackgroundService
{
    private static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(2);

    private IConnection? _connection;

    public bool IsOpen => Volatile.Read(ref _connection)?.IsOpen ?? false;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var factory = new ConnectionFactory
        {
            Uri = new Uri(configuration["RabbitMq:Uri"]
                          ?? throw new InvalidOperationException("RabbitMq:Uri is not configured.")),
            ClientProvidedName = "rpg-game-server-api",
            AutomaticRecoveryEnabled = true,
            NetworkRecoveryInterval = RetryInterval,
            RequestedConnectionTimeout = TimeSpan.FromSeconds(2),
        };

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                Volatile.Write(ref _connection, await factory.CreateConnectionAsync(stoppingToken));
                logger.LogInformation("Connected to RabbitMQ at {Host}", factory.HostName);
                return;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning("RabbitMQ unreachable ({Message}); retrying in {Interval}", ex.Message, RetryInterval);
                await Task.Delay(RetryInterval, stoppingToken);
            }
        }
    }

    /// <summary>Safe to call more than once; a connection the broker already closed is just disposed.</summary>
    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        await base.StopAsync(cancellationToken);
        if (Interlocked.Exchange(ref _connection, null) is not { } connection)
        {
            return;
        }

        try
        {
            if (connection.IsOpen)
            {
                await connection.CloseAsync(cancellationToken);
            }
        }
        catch (AlreadyClosedException)
        {
            // Closed between the check and the call; nothing left to do.
        }
        finally
        {
            await connection.DisposeAsync();
        }
    }
}
