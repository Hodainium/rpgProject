using System.Text.Json;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Serialization;
using Rpg.Verification;
using StackExchange.Redis;

namespace Rpg.VerifierWorker;

/// <summary>
/// The worker's Redis use (spec battle-verify 3.4, settlement-outbox 3.5): the verdict cache and the wallet cache; the dedup lock is gone. Every operation fails open.
/// Redis is an optimisation here; correctness is the guarded Postgres transaction.
/// </summary>
public sealed class VerifierRedis(IConfiguration configuration, ILogger<VerifierRedis> logger) : IAsyncDisposable
{
    private static readonly TimeSpan CacheTtl = TimeSpan.FromMinutes(30);

    private readonly Lazy<Task<ConnectionMultiplexer>> _connection = new(() =>
    {
        var options = ConfigurationOptions.Parse(
            configuration.GetConnectionString("Redis")
            ?? throw new InvalidOperationException("ConnectionStrings:Redis is not configured."));
        options.AbortOnConnectFail = false;
        options.ConnectTimeout = 2000;
        // Fail open fast: with Redis down every job makes two calls, and the default 5 s each would stall the consumer.
        options.SyncTimeout = 1000;
        options.AsyncTimeout = 1000;
        options.ClientName = "rpg-verifier-worker";
        return ConnectionMultiplexer.ConnectAsync(options);
    });

    private async Task<IDatabase> DatabaseAsync() => (await _connection.Value).GetDatabase();

    /// <summary>After a settlement: the cached wallet is stale. Returns false on a Redis error (the 60 s TTL bounds it).</summary>
    public async Task<bool> InvalidateWalletAsync(Guid playerId)
    {
        try
        {
            var database = await DatabaseAsync();
            await database.KeyDeleteAsync(VerifyPolicy.WalletKey(playerId));
            return true;
        }
        catch (Exception ex) when (IsRedisError(ex))
        {
            logger.LogDebug("Wallet cache not cleared: {Message}", ex.Message);
            return false;
        }
    }

    /// <summary>After the commit: the verdict cache is filled and the Submitted copy deleted. Returns false on a Redis error.</summary>
    public async Task<bool> PublishVerdictAsync(StoredBattle battle)
    {
        try
        {
            var database = await DatabaseAsync();
            var runId = Guid.Parse(battle.Session.RunId);
            await database.StringSetAsync(VerifyPolicy.VerdictKey(runId, battle.Session.RunSeq),
                JsonSerializer.Serialize(battle, RpgJson.Options), CacheTtl);
            await database.KeyDeleteAsync(VerifyPolicy.SessionKey(runId, battle.Session.RunSeq));
            return true;
        }
        catch (Exception ex) when (IsRedisError(ex))
        {
            logger.LogDebug("Verdict not cached: {Message}", ex.Message);
            return false;
        }
    }

    private static bool IsRedisError(Exception ex) =>
        ex is RedisException or TimeoutException or ObjectDisposedException or InvalidOperationException;

    public async ValueTask DisposeAsync()
    {
        if (_connection.IsValueCreated && _connection.Value.IsCompletedSuccessfully)
        {
            await _connection.Value.Result.DisposeAsync();
        }
    }
}
