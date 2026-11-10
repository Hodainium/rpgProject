using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Npgsql;
using NpgsqlTypes;
using Rpg.Contracts.Cards;
using Rpg.Contracts.Serialization;

namespace Rpg.Economy.Cards;

/// <summary>Small Npgsql helpers shared by the card store files (spec card-collection 3).</summary>
internal static class CardSql
{
    public static NpgsqlCommand Cmd(NpgsqlConnection connection, NpgsqlTransaction transaction, string sql, params object?[] values)
    {
        var command = new NpgsqlCommand(sql, connection, transaction);
        foreach (var value in values)
        {
            command.Parameters.Add(value switch
            {
                NpgsqlParameter p => p,
                null => new NpgsqlParameter { Value = DBNull.Value },
                _ => new NpgsqlParameter { Value = value },
            });
        }

        return command;
    }

    public static NpgsqlParameter Json(string json) => new() { NpgsqlDbType = NpgsqlDbType.Jsonb, Value = json };

    public static NpgsqlParameter Text(string? value) =>
        new NpgsqlParameter<string?> { TypedValue = value, NpgsqlDbType = NpgsqlDbType.Text };

    public static async Task<int> ExecAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, string sql,
        CancellationToken ct, params object?[] values)
    {
        await using var command = Cmd(connection, transaction, sql, values);
        return await command.ExecuteNonQueryAsync(ct);
    }

    /// <summary>The one lock every account action and the run start take, first (spec card-collection 3.3).</summary>
    public static Task LockAccountAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid playerId, CancellationToken ct) =>
        ExecAsync(connection, transaction, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ct, "acct:" + playerId.ToString("D"));

    public static Task LockNamedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, string name, CancellationToken ct) =>
        ExecAsync(connection, transaction, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ct, name);

    /// <summary>The shared form of <see cref="LockNamedAsync"/>: readers that must see one version of what the named lock guards.</summary>
    public static Task LockNamedSharedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, string name, CancellationToken ct) =>
        ExecAsync(connection, transaction, "SELECT pg_advisory_xact_lock_shared(hashtextextended($1, 0))", ct, name);

    public static Task EnsurePlayerAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid playerId, string name,
        DateTimeOffset now, CancellationToken ct) =>
        ExecAsync(connection, transaction,
            "INSERT INTO players (player_id, display_name, created_at) VALUES ($1, $2, $3) ON CONFLICT (player_id) DO NOTHING",
            ct, playerId, name, now.ToUniversalTime());

    public static string Hash(string kind, string target) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(kind + "|" + target)));

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, RpgJson.Options);

    public static T Deserialize<T>(string json) => JsonSerializer.Deserialize<T>(json, RpgJson.Options)!;

    public static IReadOnlyDictionary<string, int> IntMap(string json) =>
        JsonSerializer.Deserialize<Dictionary<string, int>>(json, RpgJson.Options) ?? [];

    /// <summary>The latest version of every rarity's rates in force (database time).</summary>
    public static async Task<Dictionary<string, CardRate>> LatestRatesAsync(NpgsqlConnection connection, NpgsqlTransaction? transaction,
        CancellationToken ct)
    {
        var rates = new Dictionary<string, CardRate>();
        await using var command = new NpgsqlCommand(
            """
            SELECT DISTINCT ON (rarity) rarity, dust_value, craft_cost, version, effective_from, created_by
            FROM card_rates WHERE effective_from <= clock_timestamp() ORDER BY rarity, version DESC
            """, connection, transaction);
        await using var reader = await command.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            rates[reader.GetString(0)] = new CardRate(reader.GetString(0), reader.GetInt32(1), reader.GetInt32(2),
                reader.GetInt32(3), reader.GetFieldValue<DateTimeOffset>(4), reader.GetString(5));
        }

        return rates;
    }

    private const string PackColumns =
        "pack_id, name, version, price_gems, card_count, odds::text, set_ids, retired, pity::text, first_guarantees::text, min_rarity, effective_from, created_by";

    private static PackType ReadPack(NpgsqlDataReader reader) => new(reader.GetString(0), reader.GetString(1), reader.GetInt32(2),
        reader.GetInt32(3), reader.GetInt32(4), IntMap(reader.GetString(5)), reader.GetFieldValue<string[]>(6), reader.GetBoolean(7),
        IntMap(reader.GetString(8)), IntMap(reader.GetString(9)), reader.IsDBNull(10) ? null : reader.GetString(10),
        reader.GetFieldValue<DateTimeOffset>(11), reader.GetString(12));

    public static async Task<PackType?> LatestPackAsync(NpgsqlConnection connection, NpgsqlTransaction? transaction, string packId,
        CancellationToken ct)
    {
        await using var command = new NpgsqlCommand(
            $"SELECT {PackColumns} FROM pack_types WHERE pack_id = $1 AND effective_from <= clock_timestamp() ORDER BY version DESC LIMIT 1",
            connection, transaction);
        command.Parameters.Add(new NpgsqlParameter { Value = packId });
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? ReadPack(reader) : null;
    }

    public static async Task<List<PackType>> LatestPacksAsync(NpgsqlConnection connection, NpgsqlTransaction? transaction,
        CancellationToken ct)
    {
        var packs = new List<PackType>();
        await using var command = new NpgsqlCommand(
            $"SELECT DISTINCT ON (pack_id) {PackColumns} FROM pack_types WHERE effective_from <= clock_timestamp() ORDER BY pack_id, version DESC",
            connection, transaction);
        await using var reader = await command.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            packs.Add(ReadPack(reader));
        }

        return packs;
    }

    /// <summary>The player's Active or Verifying run: id, status, start. Null when there is none.</summary>
    public static async Task<(Guid RunId, string Status, DateTimeOffset StartedAt)?> ActiveRunAsync(NpgsqlConnection connection,
        NpgsqlTransaction? transaction, Guid playerId, CancellationToken ct)
    {
        await using var command = new NpgsqlCommand(
            "SELECT run_id, status, started_at FROM runs WHERE player_id = $1 AND status IN ('Active', 'Verifying') LIMIT 1",
            connection, transaction);
        command.Parameters.Add(new NpgsqlParameter { Value = playerId });
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct)
            ? (reader.GetGuid(0), reader.GetString(1), reader.GetFieldValue<DateTimeOffset>(2))
            : null;
    }

    /// <summary>Eligible cards by rarity for a pack: in its sets, not core, not retired, sorted ordinally by id (spec 3.4).</summary>
    public static async Task<Dictionary<string, IReadOnlyList<string>>> EligibleAsync(NpgsqlConnection connection,
        NpgsqlTransaction? transaction, IReadOnlyList<string> setIds, CancellationToken ct)
    {
        var ids = new Dictionary<string, List<string>>();
        await using var command = new NpgsqlCommand(
            "SELECT card_id, rarity FROM cards WHERE set_id = ANY($1) AND NOT core AND NOT retired", connection, transaction);
        command.Parameters.Add(new NpgsqlParameter { Value = setIds.ToArray() });
        await using var reader = await command.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            if (!ids.TryGetValue(reader.GetString(1), out var list))
            {
                ids[reader.GetString(1)] = list = [];
            }

            list.Add(reader.GetString(0));
        }

        return ids.ToDictionary(kv => kv.Key, kv => (IReadOnlyList<string>)[.. kv.Value.Order(StringComparer.Ordinal)]);
    }
}
