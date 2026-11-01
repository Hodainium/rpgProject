using System.Text.Json;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Serialization;
using Rpg.Verification;
using StackExchange.Redis;

namespace Rpg.VerifierWorker;

public enum LockResult { Acquired, Busy, Unavailable }

/// <summary>
/// The worker's Redis use (spec battle-verify 3.4): the dedup lock and the verdict cache. Every operation fails open.
/// Redis is an optimisation here; correctness is the guarded Postgres update.
/// </summary>
public sealed class VerifierRedis(IConfiguration configuration, ILogger<VerifierRedis> logger) : IAsyncDisposable
{
    private const string ReleaseScript =
        "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end";

    private static readonly TimeSpan CacheTtl = TimeSpan.FromMinutes(30);

    private readonly Lazy<Task<ConnectionMultiplexer>> _connection = new(() =>
    {
        var options = ConfigurationOptions.Parse(
            configuration.GetConnectionString("Redis")
            ?? throw new InvalidOperationException("ConnectionStrings:Redis is not configured."));
        options.AbortOnConnectFail = false;
        options.ConnectTimeout = 2000;
        // Fail open fast: with Redis down every job makes three calls, and the default 5 s each would stall the consumer.
        options.SyncTimeout = 1000;
        options.AsyncTimeout = 1000;
        options.ClientName = "rpg-verifier-worker";
        return ConnectionMultiplexer.ConnectAsync(options);
    });

    private async Task<IDatabase> DatabaseAsync() => (await _connection.Value).GetDatabase();

    public async Task<LockResult> TryLockAsync(string battleId, string token, TimeSpan ttl)
    {
        try
        {
            var database = await DatabaseAsync();
            return await database.StringSetAsync(VerifyPolicy.LockKey(battleId), token, ttl, When.NotExists)
                ? LockResult.Acquired
                : LockResult.Busy;
        }
        catch (Exception ex) when (IsRedisError(ex))
        {
            logger.LogDebug("Redis lock unavailable: {Message}", ex.Message);
            return LockResult.Unavailable;
        }
    }

    /// <summary>Compare-and-delete: only the holder's token releases it.</summary>
    public async Task ReleaseAsync(string battleId, string token)
    {
        try
        {
            var database = await DatabaseAsync();
            await database.ScriptEvaluateAsync(ReleaseScript, [VerifyPolicy.LockKey(battleId)], [token]);
        }
        catch (Exception ex) when (IsRedisError(ex))
        {
            logger.LogDebug("Redis lock not released (it expires on its own): {Message}", ex.Message);
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
