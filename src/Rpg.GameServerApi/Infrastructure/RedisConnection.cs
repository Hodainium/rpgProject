using StackExchange.Redis;

namespace Rpg.GameServerApi.Infrastructure;

/// <summary>
/// Owns the Redis multiplexer. Connecting starts in the background at startup and never blocks it;
/// the multiplexer reconnects on its own after the initial connect (abortConnect=false).
/// </summary>
public sealed class RedisConnection(IConfiguration configuration) : IHostedService, IAsyncDisposable
{
    private readonly TaskCompletionSource<ConnectionMultiplexer> _connected =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Task<ConnectionMultiplexer>? _connecting;

    /// <summary>The multiplexer once the initial connect call has returned, otherwise null.</summary>
    public IConnectionMultiplexer? Multiplexer =>
        _connecting is { IsCompletedSuccessfully: true } task ? task.Result : null;

    /// <summary>The database, or <see cref="NotConnectedException"/> while the first connect hasn't returned.</summary>
    public IDatabase Database() => (Multiplexer ?? throw new NotConnectedException()).GetDatabase();

    /// <summary>Errors that mean "Redis is unavailable": callers count them and fall back, never fail.</summary>
    public static bool IsError(Exception ex) =>
        ex is RedisException or NotConnectedException or TimeoutException or ObjectDisposedException;

    /// <summary>
    /// Runs <paramref name="action"/> once the initial connect call has returned (at once if it already has); never if
    /// it fails. For things that attach to the multiplexer, such as the Redis trace instrumentation.
    /// </summary>
    public void WhenConnected(Action<IConnectionMultiplexer> action) =>
        _connected.Task.ContinueWith(task => action(task.Result), CancellationToken.None,
            TaskContinuationOptions.OnlyOnRanToCompletion, TaskScheduler.Default);

    public Task StartAsync(CancellationToken cancellationToken)
    {
        var options = ConfigurationOptions.Parse(
            configuration.GetConnectionString("Redis")
            ?? throw new InvalidOperationException("ConnectionStrings:Redis is not configured."));
        options.AbortOnConnectFail = false;
        options.ConnectTimeout = 2000;
        options.ClientName = "rpg-game-server-api";
        _connecting = ConnectionMultiplexer.ConnectAsync(options);
        _connecting.ContinueWith(task =>
        {
            if (task.IsCompletedSuccessfully)
            {
                _connected.TrySetResult(task.Result);
            }
        }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public async ValueTask DisposeAsync()
    {
        if (Multiplexer is { } multiplexer)
        {
            await multiplexer.DisposeAsync();
        }
    }
}

/// <summary>The multiplexer's first connect hasn't returned yet.</summary>
public sealed class NotConnectedException() : Exception("Redis has not connected yet.");
