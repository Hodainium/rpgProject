using System.Text.Json;
using Npgsql;
using Rpg.Contracts.Economy;
using Rpg.Contracts.Events;
using Rpg.Contracts.Serialization;
using Rpg.Verification;

namespace Rpg.Economy;

/// <summary>Why a <see cref="RewardRuleRequest"/> is refused (spec economy-rewards F5).</summary>
public sealed record RuleProblem(string Detail);

public sealed record RewardRule(string SourceKind, string SourceId, string Currency, int Amount, int Version,
    DateTimeOffset EffectiveFrom, string CreatedBy)
{
    public RewardRuleResponse ToResponse() => new(SourceKind, SourceId, Currency, Amount, Version, EffectiveFrom, CreatedBy);
}

/// <summary>The versioned reward-rule table (spec economy-rewards 2.1, 2.2, 3.2). Append-only: a change is a new version.</summary>
public static class RewardRules
{
    public const int DefaultMaxAmount = 100_000;

    /// <summary>The currencies a rule can pay (the migration's CHECK list; slice 5 widens both).</summary>
    public static readonly string[] Currencies = ["gems"];

    public static readonly string[] SourceKinds = [RewardSourceKinds.Boss];

    /// <summary>The "player" that owns events the system itself writes (seed rules); not a real account.</summary>
    public static readonly Guid SeedPlayer = Guid.Empty;

    public const int MaxIdLength = 200;

    /// <summary>A content id that can sit inside a ledger key: 1–200 characters, no ':' and no whitespace (the one rule for rules, bosses and characters).</summary>
    public static bool IsKeySafeId(string? id) =>
        !string.IsNullOrEmpty(id) && id.Length <= MaxIdLength && !id.Any(c => c == ':' || char.IsWhiteSpace(c));

    /// <summary>Null = the request is fine.</summary>
    public static RuleProblem? Validate(RewardRuleRequest? request, int maxAmount)
    {
        if (request?.SourceKind is null || !SourceKinds.Contains(request.SourceKind))
        {
            return new RuleProblem("sourceKind must be one of: " + string.Join(", ", SourceKinds) + ".");
        }

        if (request.Currency is null || !Currencies.Contains(request.Currency))
        {
            return new RuleProblem("currency must be one of: " + string.Join(", ", Currencies) + ".");
        }

        if (!IsKeySafeId(request.SourceId))
        {
            return new RuleProblem("sourceId takes 1–200 characters with no ':' and no whitespace.");
        }

        if (request.Amount < 0 || request.Amount > maxAmount)
        {
            return new RuleProblem($"amount takes 0 (retire) or 1–{maxAmount}.");
        }

        return null;
    }

    /// <summary>
    /// The latest version in force for a source, read inside the caller's transaction so a grant and the rule it used
    /// can never disagree. A version whose <c>effective_from</c> is in the future is ignored. Time is the database's.
    /// </summary>
    public static async Task<RewardRule?> LookupAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        string sourceKind, string sourceId, CancellationToken ct)
    {
        await using var command = new NpgsqlCommand(
            """
            SELECT source_kind, source_id, currency, amount, version, effective_from, created_by FROM reward_rules
            WHERE source_kind = $1 AND source_id = $2 AND effective_from <= clock_timestamp()  -- not now(): a rule committed after this transaction began is still in force
            ORDER BY version DESC LIMIT 1
            """, connection, transaction);
        command.Parameters.Add(new NpgsqlParameter { Value = sourceKind });
        command.Parameters.Add(new NpgsqlParameter { Value = sourceId });
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? Read(reader) : null;
    }

    /// <summary>The latest version in force per source, for the admin list.</summary>
    public static async Task<IReadOnlyList<RewardRule>> ListLatestAsync(NpgsqlDataSource dataSource, CancellationToken ct)
    {
        await using var command = dataSource.CreateCommand(
            """
            SELECT DISTINCT ON (source_kind, source_id)
                   source_kind, source_id, currency, amount, version, effective_from, created_by
            FROM reward_rules WHERE effective_from <= clock_timestamp()
            ORDER BY source_kind, source_id, version DESC
            """);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rules = new List<RewardRule>();
        while (await reader.ReadAsync(ct))
        {
            rules.Add(Read(reader));
        }

        return rules;
    }

    /// <summary>
    /// A new version of the rule plus its <c>RewardRuleChanged</c> event, in one transaction (F4, F8). The advisory lock on
    /// (kind, id) serialises two admins on the same source, so versions are consecutive.
    /// </summary>
    public static async Task<RewardRule> PutAsync(NpgsqlDataSource dataSource, RewardRuleRequest request, Guid adminId,
        string adminName, DateTimeOffset now, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        var rule = await InsertVersionAsync(connection, transaction, request, adminId, adminName, now, ct);
        await transaction.CommitAsync(ct);
        return rule;
    }

    /// <summary>The same inside a transaction the caller owns (lets a test prove F8).</summary>
    public static async Task<RewardRule> InsertVersionAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        RewardRuleRequest request, Guid adminId, string adminName, DateTimeOffset now, CancellationToken ct)
    {
        await LockAsync(connection, transaction, request.SourceKind, request.SourceId, ct);

        int? previousAmount = null;
        var version = 1;
        await using (var latest = new NpgsqlCommand(
            "SELECT amount, version FROM reward_rules WHERE source_kind = $1 AND source_id = $2 ORDER BY version DESC LIMIT 1",
            connection, transaction))
        {
            latest.Parameters.Add(new NpgsqlParameter { Value = request.SourceKind });
            latest.Parameters.Add(new NpgsqlParameter { Value = request.SourceId });
            await using var reader = await latest.ExecuteReaderAsync(ct);
            if (await reader.ReadAsync(ct))
            {
                previousAmount = reader.GetInt32(0);
                version = reader.GetInt32(1) + 1;
            }
        }

        DateTimeOffset effectiveFrom;
        await using (var insert = new NpgsqlCommand(
            """
            INSERT INTO reward_rules (source_kind, source_id, currency, amount, version, created_by)
            VALUES ($1, $2, $3, $4, $5, $6) RETURNING effective_from
            """, connection, transaction))
        {
            insert.Parameters.Add(new NpgsqlParameter { Value = request.SourceKind });
            insert.Parameters.Add(new NpgsqlParameter { Value = request.SourceId });
            insert.Parameters.Add(new NpgsqlParameter { Value = request.Currency });
            insert.Parameters.Add(new NpgsqlParameter { Value = request.Amount });
            insert.Parameters.Add(new NpgsqlParameter { Value = version });
            insert.Parameters.Add(new NpgsqlParameter { Value = adminName });
            await using var inserted = await insert.ExecuteReaderAsync(ct);
            await inserted.ReadAsync(ct);
            effectiveFrom = inserted.GetFieldValue<DateTimeOffset>(0);
        }

        await EconomyEvents.WriteAsync(connection, transaction, adminId, null, "economy", EventTypes.RewardRuleChanged,
            EventTopics.Economy, $"rule:{request.SourceKind}:{request.SourceId}", now,
            new RewardRuleChangedPayload(request.SourceKind, request.SourceId, request.Currency, request.Amount, version,
                previousAmount, adminName), ct);
        return new RewardRule(request.SourceKind, request.SourceId, request.Currency, request.Amount, version,
            effectiveFrom, adminName);
    }

    /// <summary>
    /// Fills sources that have NO rule yet (spec economy-rewards F9): a restart never overwrites an admin's version.
    /// Returns how many rules it created. Each is a normal version 1 with its event.
    /// </summary>
    public static async Task<int> SeedAsync(NpgsqlDataSource dataSource, IEnumerable<RewardRuleRequest> seeds,
        int maxAmount, DateTimeOffset now, CancellationToken ct)
    {
        var created = 0;
        foreach (var seed in seeds)
        {
            if (Validate(seed, maxAmount) is not null || seed.Amount == 0)  // a seed never retires
            {
                continue;
            }

            await using var connection = await dataSource.OpenConnectionAsync(ct);
            await using var transaction = await connection.BeginTransactionAsync(ct);
            await LockAsync(connection, transaction, seed.SourceKind, seed.SourceId, ct);
            await using (var exists = new NpgsqlCommand(
                "SELECT 1 FROM reward_rules WHERE source_kind = $1 AND source_id = $2 LIMIT 1", connection, transaction))
            {
                exists.Parameters.Add(new NpgsqlParameter { Value = seed.SourceKind });
                exists.Parameters.Add(new NpgsqlParameter { Value = seed.SourceId });
                if (await exists.ExecuteScalarAsync(ct) is not null)
                {
                    continue;
                }
            }

            await InsertVersionAsync(connection, transaction, seed, SeedPlayer, "seed", now, ct);
            await transaction.CommitAsync(ct);
            created++;
        }

        return created;
    }

    private static async Task LockAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, string kind, string id,
        CancellationToken ct)
    {
        await using var command = new NpgsqlCommand("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", connection, transaction);
        command.Parameters.Add(new NpgsqlParameter { Value = $"reward_rule|{kind}|{id}" });
        await command.ExecuteNonQueryAsync(ct);
    }

    private static RewardRule Read(NpgsqlDataReader reader) => new(reader.GetString(0), reader.GetString(1),
        reader.GetString(2), reader.GetInt32(3), reader.GetInt32(4), reader.GetFieldValue<DateTimeOffset>(5), reader.GetString(6));
}

/// <summary>Writes economy events into the outbox inside the caller's transaction (spec settlement-outbox 2.2).</summary>
internal static class EconomyEvents
{
    public static Task WriteAsync<TPayload>(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid playerId,
        Guid? runId, string ruleset, string type, string topic, string key, DateTimeOffset now, TPayload payload,
        CancellationToken ct)
    {
        var id = Guid.NewGuid();
        var envelope = new DomainEvent<TPayload>(id, type, 1, playerId, runId, now, ruleset, payload);
        return OutboxWriter.InsertAsync(connection, transaction,
            new OutboxMessage(id, OutboxDestination.Redpanda, topic, key, type, JsonSerializer.Serialize(envelope, RpgJson.Options)),
            ct);
    }
}
