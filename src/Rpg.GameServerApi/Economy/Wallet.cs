using System.Text.Json;
using Npgsql;
using Rpg.Contracts.Economy;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Infrastructure;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Observability;
using Rpg.Verification;

namespace Rpg.GameServerApi.Economy;

/// <summary>The wallet read model from Postgres (spec settlement-outbox 2.4). Read-only: money moves only in the worker's transaction.</summary>
public sealed class WalletStore(NpgsqlDataSource dataSource, MigrationRunner migrations)
{
    public const int RecentEntries = 20;

    public async Task<WalletResponse> GetAsync(Guid playerId, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        int gems = 0;
        long version = 0;
        await using (var wallet = dataSource.CreateCommand("SELECT gems, version FROM wallets WHERE player_id = $1"))
        {
            wallet.Parameters.Add(new NpgsqlParameter { Value = playerId });
            await using var reader = await wallet.ExecuteReaderAsync(ct);
            if (await reader.ReadAsync(ct))
            {
                gems = reader.GetInt32(0);
                version = reader.GetInt64(1);
            }
        }

        var recent = new List<LedgerEntryDto>();
        await using (var ledger = dataSource.CreateCommand(
            "SELECT currency, delta, reason, ref_battle_id, created_at, rule_version, challenge_id, tier, cycle_key FROM wallet_ledger WHERE player_id = $1 ORDER BY id DESC LIMIT $2"))
        {
            ledger.Parameters.Add(new NpgsqlParameter { Value = playerId });
            ledger.Parameters.Add(new NpgsqlParameter { Value = RecentEntries });
            await using var reader = await ledger.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                recent.Add(new LedgerEntryDto(reader.GetString(0), reader.GetInt32(1), reader.GetString(2),
                    reader.IsDBNull(3) ? null : reader.GetString(3), reader.GetFieldValue<DateTimeOffset>(4),
                    reader.IsDBNull(5) ? null : reader.GetInt32(5), reader.IsDBNull(6) ? null : reader.GetString(6),
                    reader.IsDBNull(7) ? null : reader.GetInt32(7), reader.IsDBNull(8) ? null : reader.GetString(8)));
            }
        }

        return new WalletResponse(gems, version, recent);
    }
}

/// <summary>Cache-aside for <c>wallet:{playerId}</c>, 60 s (spec settlement-outbox 3.5). Any Redis error is a counted miss.</summary>
public sealed class WalletCache(RedisConnection redis, RpgMetrics metrics, ILogger<WalletCache> logger)
{
    public static readonly TimeSpan Ttl = TimeSpan.FromSeconds(60);

    public async Task<WalletResponse?> GetAsync(Guid playerId)
    {
        try
        {
            var value = await redis.Database().StringGetAsync(VerifyPolicy.WalletKey(playerId));
            return value.IsNullOrEmpty ? null : JsonSerializer.Deserialize<WalletResponse>(value.ToString(), RpgJson.Options);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex) || ex is JsonException)
        {
            metrics.CacheError("get");
            logger.LogDebug("Redis get of a wallet failed: {Message}", ex.Message);
            return null;
        }
    }

    public async Task SetAsync(Guid playerId, WalletResponse wallet)
    {
        try
        {
            await redis.Database().StringSetAsync(VerifyPolicy.WalletKey(playerId),
                JsonSerializer.Serialize(wallet, RpgJson.Options), Ttl);
        }
        catch (Exception ex) when (RedisConnection.IsError(ex))
        {
            metrics.CacheError("set");
            logger.LogDebug("Redis set of a wallet failed: {Message}", ex.Message);
        }
    }
}

public static class WalletEndpoints
{
    public static void MapWalletEndpoints(this WebApplication app) =>
        app.MapGet("/api/v1/wallet", async (HttpContext context, WalletStore store, WalletCache cache, RpgMetrics metrics,
            CancellationToken ct) =>
        {
            var player = context.User.Player();
            if (await cache.GetAsync(player.Id) is { } cached)
            {
                metrics.WalletRead("redis");
                return Results.Ok(cached);
            }

            var wallet = await store.GetAsync(player.Id, ct);
            metrics.WalletRead("postgres");
            await cache.SetAsync(player.Id, wallet);
            return Results.Ok(wallet);
        }).RequireAuthorization();
}
