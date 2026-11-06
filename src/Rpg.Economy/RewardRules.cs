using System.Text.Json;
using Npgsql;
using NpgsqlTypes;
using Rpg.Contracts.Economy;
using Rpg.Contracts.Events;
using Rpg.Contracts.Serialization;
using Rpg.Verification;

namespace Rpg.Economy;

/// <summary>Why a <see cref="RewardRuleRequest"/> or a reset is refused (spec economy-challenges F15).</summary>
public sealed record RuleProblem(string Detail);

/// <summary>One version of a challenge's reward. An amount of 0 means retired.</summary>
public sealed record RewardRule(string ChallengeId, string Currency, int Amount, string Cycle, DateTimeOffset? EndsAt,
    int Version, DateTimeOffset EffectiveFrom, string CreatedBy, int Generation = 0)
{
    public bool Retired => Amount == 0;

    public RewardRuleResponse ToResponse() =>
        new(ChallengeId, Currency, Amount, Cycle, EndsAt, Generation, Version, EffectiveFrom, CreatedBy);
}

/// <summary>
/// The versioned reward table (spec economy-challenges 2.1, 3.2). Append-only: a change is a new version.
/// </summary>
public static class RewardRules
{
    public const int DefaultMaxAmount = 100_000;

    /// <summary>The currencies a rule can pay (the migration's CHECK list; slice 5 widens both).</summary>
    public static readonly string[] Currencies = ["gems"];

    public static readonly string[] Cycles = [RewardCycles.Once, RewardCycles.Weekly];

    /// <summary>The "player" that owns events the system itself writes (seed rules); not a real account.</summary>
    public static readonly Guid SeedPlayer = Guid.Empty;

    /// <summary>Null = the request is fine.</summary>
    public static RuleProblem? Validate(RewardRuleRequest? request, int maxAmount, DateTimeOffset now)
    {
        if (request is null || !ChallengeIds.IsKeySafe(request.ChallengeId))
        {
            return new RuleProblem("challengeId takes 1–200 characters with no ':' and no whitespace.");
        }

        if (request.Currency is null || !Currencies.Contains(request.Currency))
        {
            return new RuleProblem("currency must be one of: " + string.Join(", ", Currencies) + ".");
        }

        if (request.Cycle is null || !Cycles.Contains(request.Cycle))
        {
            return new RuleProblem("cycle must be one of: " + string.Join(", ", Cycles) + ".");
        }

        if (request.Amount < 0 || request.Amount > maxAmount)
        {
            return new RuleProblem($"amount takes 0 (retire) or 1–{maxAmount}.");
        }

        if (request.EndsAt is { } endsAt && endsAt <= now)
        {
            return new RuleProblem("endsAt must be in the future.");
        }

        return null;
    }

    /// <summary>
    /// The latest version in force for a challenge, read inside the caller's transaction so a grant and the rule it used
    /// can never disagree. A version whose <c>effective_from</c> is in the future is ignored. Time is the database's.
    /// </summary>
    public static async Task<RewardRule?> LookupAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        string challengeId, CancellationToken ct)
    {
        await using var command = new NpgsqlCommand(
            """
            SELECT challenge_id, currency, amount, cycle, ends_at, version, effective_from, created_by FROM reward_rules
            WHERE challenge_id = $1 AND effective_from <= clock_timestamp()  -- not now(): a rule committed after this transaction began is still in force
            ORDER BY version DESC LIMIT 1
            """, connection, transaction);
        command.Parameters.Add(new NpgsqlParameter { Value = challengeId });
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? Read(reader) : null;
    }

    /// <summary>The generation of the resets for everyone (<paramref name="playerId"/> null) or for one player; 0 if none.</summary>
    public static async Task<int> GenerationAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        string challengeId, Guid? playerId, CancellationToken ct)
    {
        await using var command = new NpgsqlCommand(
            "SELECT COALESCE(max(generation), 0) FROM reward_cycle_resets WHERE challenge_id = $1 AND player_id IS NOT DISTINCT FROM $2",
            connection, transaction);
        command.Parameters.Add(new NpgsqlParameter { Value = challengeId });
        command.Parameters.Add(new NpgsqlParameter<Guid?> { TypedValue = playerId, NpgsqlDbType = NpgsqlDbType.Uuid });
        return (int)(await command.ExecuteScalarAsync(ct))!;
    }

    /// <summary>The latest version in force per challenge, with its global generation, for the admin list.</summary>
    public static async Task<IReadOnlyList<RewardRule>> ListLatestAsync(NpgsqlDataSource dataSource, CancellationToken ct)
    {
        var rules = new List<RewardRule>();
        await using (var command = dataSource.CreateCommand(
            """
            SELECT DISTINCT ON (challenge_id) challenge_id, currency, amount, cycle, ends_at, version, effective_from, created_by
            FROM reward_rules WHERE effective_from <= clock_timestamp()
            ORDER BY challenge_id, version DESC
            """))
        {
            await using var reader = await command.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                rules.Add(Read(reader));
            }
        }

        var generations = new Dictionary<string, int>();
        await using (var command = dataSource.CreateCommand(
            "SELECT challenge_id, max(generation) FROM reward_cycle_resets WHERE player_id IS NULL GROUP BY challenge_id"))
        {
            await using var reader = await command.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                generations[reader.GetString(0)] = reader.GetInt32(1);
            }
        }

        return [.. rules.Select(r => generations.TryGetValue(r.ChallengeId, out var g) ? r with { Generation = g } : r)];
    }

    /// <summary>
    /// A new version of the rule plus its <c>RewardRuleChanged</c> event, in one transaction. The advisory lock on the
    /// challenge id serialises two admins, so versions are consecutive.
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

    /// <summary>The same inside a transaction the caller owns (lets a test prove the lock and the event write).</summary>
    public static async Task<RewardRule> InsertVersionAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        RewardRuleRequest request, Guid adminId, string adminName, DateTimeOffset now, CancellationToken ct)
    {
        await LockAsync(connection, transaction, $"reward_rule|{request.ChallengeId}", ct);

        int? previousAmount = null;
        var version = 1;
        await using (var latest = new NpgsqlCommand(
            "SELECT amount, version FROM reward_rules WHERE challenge_id = $1 ORDER BY version DESC LIMIT 1", connection, transaction))
        {
            latest.Parameters.Add(new NpgsqlParameter { Value = request.ChallengeId });
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
            INSERT INTO reward_rules (challenge_id, currency, amount, cycle, ends_at, version, created_by)
            VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING effective_from
            """, connection, transaction))
        {
            insert.Parameters.Add(new NpgsqlParameter { Value = request.ChallengeId });
            insert.Parameters.Add(new NpgsqlParameter { Value = request.Currency });
            insert.Parameters.Add(new NpgsqlParameter { Value = request.Amount });
            insert.Parameters.Add(new NpgsqlParameter { Value = request.Cycle });
            insert.Parameters.Add(new NpgsqlParameter<DateTimeOffset?>
            {
                TypedValue = request.EndsAt?.ToUniversalTime(), NpgsqlDbType = NpgsqlDbType.TimestampTz,
            });
            insert.Parameters.Add(new NpgsqlParameter { Value = version });
            insert.Parameters.Add(new NpgsqlParameter { Value = adminName });
            effectiveFrom = new DateTimeOffset(DateTime.SpecifyKind((DateTime)(await insert.ExecuteScalarAsync(ct))!, DateTimeKind.Utc));
        }

        await EconomyEvents.WriteAsync(connection, transaction, adminId, null, "economy", EventTypes.RewardRuleChanged,
            EventTopics.Economy, $"rule:{request.ChallengeId}", now,
            new RewardRuleChangedPayload(request.ChallengeId, request.Currency, request.Amount, request.Cycle, request.EndsAt,
                version, previousAmount, adminName), ct);
        return new RewardRule(request.ChallengeId, request.Currency, request.Amount, request.Cycle, request.EndsAt, version,
            effectiveFrom, adminName);
    }

    /// <summary>
    /// Fills challenges that have NO rule yet: a restart never overwrites an admin's version. Returns how many rules it
    /// created. Each is a normal version 1 with its event.
    /// </summary>
    public static async Task<int> SeedAsync(NpgsqlDataSource dataSource, IEnumerable<RewardRuleRequest> seeds,
        int maxAmount, DateTimeOffset now, CancellationToken ct)
    {
        var created = 0;
        foreach (var seed in seeds)
        {
            if (Validate(seed, maxAmount, now) is not null || seed.Amount == 0)  // a seed never retires
            {
                continue;
            }

            await using var connection = await dataSource.OpenConnectionAsync(ct);
            await using var transaction = await connection.BeginTransactionAsync(ct);
            await LockAsync(connection, transaction, $"reward_rule|{seed.ChallengeId}", ct);
            await using (var exists = new NpgsqlCommand(
                "SELECT 1 FROM reward_rules WHERE challenge_id = $1 LIMIT 1", connection, transaction))
            {
                exists.Parameters.Add(new NpgsqlParameter { Value = seed.ChallengeId });
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

    /// <summary>Null = the challenge id is well formed.</summary>
    public static RuleProblem? ValidateReset(RewardCycleResetRequest? request) =>
        request is null || !ChallengeIds.IsKeySafe(request.ChallengeId)
            ? new RuleProblem("challengeId takes 1–200 characters with no ':' and no whitespace.")
            : null;

    /// <summary>
    /// Raises the generation of one scope (everyone, or one player) by one and writes <c>RewardCycleReset</c>, in one
    /// transaction under an advisory lock (spec economy-challenges 2.2). Null when the challenge has no rule or the player
    /// does not exist (404 1303).
    /// </summary>
    public static async Task<RewardCycleResetResponse?> ResetAsync(NpgsqlDataSource dataSource, RewardCycleResetRequest request,
        Guid adminId, string adminName, DateTimeOffset now, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);

        await using (var rule = new NpgsqlCommand("SELECT 1 FROM reward_rules WHERE challenge_id = $1 LIMIT 1", connection, transaction))
        {
            rule.Parameters.Add(new NpgsqlParameter { Value = request.ChallengeId });
            if (await rule.ExecuteScalarAsync(ct) is null)
            {
                return null;
            }
        }

        if (request.PlayerId is { } player)
        {
            await using var exists = new NpgsqlCommand("SELECT 1 FROM players WHERE player_id = $1", connection, transaction);
            exists.Parameters.Add(new NpgsqlParameter { Value = player });
            if (await exists.ExecuteScalarAsync(ct) is null)
            {
                return null;
            }
        }

        await LockAsync(connection, transaction, $"reward_reset|{request.ChallengeId}|{request.PlayerId?.ToString("D") ?? "all"}", ct);
        var generation = await GenerationAsync(connection, transaction, request.ChallengeId, request.PlayerId, ct) + 1;
        DateTimeOffset resetAt;
        await using (var insert = new NpgsqlCommand(
            """
            INSERT INTO reward_cycle_resets (challenge_id, player_id, generation, reset_by, reason)
            VALUES ($1, $2, $3, $4, $5) RETURNING reset_at
            """, connection, transaction))
        {
            insert.Parameters.Add(new NpgsqlParameter { Value = request.ChallengeId });
            insert.Parameters.Add(new NpgsqlParameter<Guid?> { TypedValue = request.PlayerId, NpgsqlDbType = NpgsqlDbType.Uuid });
            insert.Parameters.Add(new NpgsqlParameter { Value = generation });
            insert.Parameters.Add(new NpgsqlParameter { Value = adminName });
            insert.Parameters.Add(new NpgsqlParameter<string?> { TypedValue = request.Reason, NpgsqlDbType = NpgsqlDbType.Text });
            resetAt = new DateTimeOffset(DateTime.SpecifyKind((DateTime)(await insert.ExecuteScalarAsync(ct))!, DateTimeKind.Utc));
        }

        await EconomyEvents.WriteAsync(connection, transaction, adminId, null, "economy", EventTypes.RewardCycleReset,
            EventTopics.Economy, $"rule:{request.ChallengeId}", now,
            new RewardCycleResetPayload(request.ChallengeId, request.PlayerId, generation, adminName, request.Reason), ct);
        await transaction.CommitAsync(ct);
        return new RewardCycleResetResponse(request.ChallengeId, request.PlayerId, generation, resetAt, adminName);
    }

    private static async Task LockAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, string name, CancellationToken ct)
    {
        await using var command = new NpgsqlCommand("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", connection, transaction);
        command.Parameters.Add(new NpgsqlParameter { Value = name });
        await command.ExecuteNonQueryAsync(ct);
    }

    private static RewardRule Read(NpgsqlDataReader reader) => new(reader.GetString(0), reader.GetString(1), reader.GetInt32(2),
        reader.GetString(3), reader.IsDBNull(4) ? null : reader.GetFieldValue<DateTimeOffset>(4), reader.GetInt32(5),
        reader.GetFieldValue<DateTimeOffset>(6), reader.GetString(7));
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
