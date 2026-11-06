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

/// <summary>One version of a challenge's ladder. No tiers = retired.</summary>
public sealed record RewardRule(string ChallengeId, string Currency, IReadOnlyList<int> Tiers, string Cycle, DateTimeOffset? EndsAt,
    int Version, DateTimeOffset EffectiveFrom, string CreatedBy, int Generation = 0)
{
    public bool Retired => Tiers.Count == 0;

    public RewardRuleResponse ToResponse() =>
        new(ChallengeId, Currency, Tiers, Cycle, EndsAt, Generation, Version, EffectiveFrom, CreatedBy);
}

/// <summary>
/// The versioned ladder table (spec economy-challenges 2.1, 3.2). Append-only: a change is a new version holding every
/// tier, written in one transaction, so a reader sees a whole ladder or the previous one.
/// </summary>
public static class RewardRules
{
    public const int DefaultMaxAmount = 100_000;
    public const int DefaultMaxTiers = 10;

    /// <summary>The currencies a rule can pay (the migration's CHECK list; slice 5 widens both).</summary>
    public static readonly string[] Currencies = ["gems"];

    public static readonly string[] Cycles = [RewardCycles.Once, RewardCycles.Weekly];

    /// <summary>The "player" that owns events the system itself writes (seed rules); not a real account.</summary>
    public static readonly Guid SeedPlayer = Guid.Empty;

    /// <summary>Null = the request is fine.</summary>
    public static RuleProblem? Validate(RewardRuleRequest? request, int maxAmount, int maxTiers, DateTimeOffset now)
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

        if (request.Tiers is null || request.Tiers.Count > maxTiers)
        {
            return new RuleProblem($"tiers takes 0 (retire) to {maxTiers} amounts.");
        }

        if (request.Tiers.Any(amount => amount < 1 || amount > maxAmount))
        {
            return new RuleProblem($"every tier amount takes 1–{maxAmount}.");
        }

        if (request.EndsAt is { } endsAt && endsAt <= now)
        {
            return new RuleProblem("endsAt must be in the future.");
        }

        return null;
    }

    /// <summary>
    /// The latest ladder in force for a challenge, read inside the caller's transaction so a grant and the rule it used
    /// can never disagree. A version whose <c>effective_from</c> is in the future is ignored. Time is the database's.
    /// </summary>
    public static async Task<RewardRule?> LookupAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        string challengeId, CancellationToken ct)
    {
        await using var command = new NpgsqlCommand(
            """
            SELECT challenge_id, currency, amount, tier, cycle, ends_at, version, effective_from, created_by FROM reward_rules
            WHERE challenge_id = $1 AND version = (
              SELECT max(version) FROM reward_rules
              WHERE challenge_id = $1 AND effective_from <= clock_timestamp())  -- not now(): a rule committed after this transaction began is still in force
            ORDER BY tier
            """, connection, transaction);
        command.Parameters.Add(new NpgsqlParameter { Value = challengeId });
        await using var reader = await command.ExecuteReaderAsync(ct);
        return ReadLadders(await ReadRowsAsync(reader, ct)).FirstOrDefault();
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

    /// <summary>The latest ladder in force per challenge, with its global generation, for the admin list.</summary>
    public static async Task<IReadOnlyList<RewardRule>> ListLatestAsync(NpgsqlDataSource dataSource, CancellationToken ct)
    {
        List<RewardRule> ladders;
        await using (var command = dataSource.CreateCommand(
            """
            SELECT r.challenge_id, r.currency, r.amount, r.tier, r.cycle, r.ends_at, r.version, r.effective_from, r.created_by
            FROM reward_rules r
            WHERE r.version = (SELECT max(x.version) FROM reward_rules x
                               WHERE x.challenge_id = r.challenge_id AND x.effective_from <= clock_timestamp())
            ORDER BY r.challenge_id, r.tier
            """))
        {
            await using var reader = await command.ExecuteReaderAsync(ct);
            ladders = ReadLadders(await ReadRowsAsync(reader, ct));
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

        return [.. ladders.Select(l => generations.TryGetValue(l.ChallengeId, out var g) ? l with { Generation = g } : l)];
    }

    /// <summary>
    /// A new version of the ladder plus its <c>RewardRuleChanged</c> event, in one transaction. The advisory lock on the
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

    /// <summary>The same inside a transaction the caller owns (lets a test prove the lock and the whole-ladder write).</summary>
    public static async Task<RewardRule> InsertVersionAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        RewardRuleRequest request, Guid adminId, string adminName, DateTimeOffset now, CancellationToken ct)
    {
        await LockAsync(connection, transaction, $"reward_rule|{request.ChallengeId}", ct);

        IReadOnlyList<int>? previousTiers = null;
        var version = 1;
        await using (var latest = new NpgsqlCommand(
            "SELECT amount, version FROM reward_rules WHERE challenge_id = $1 AND version = (SELECT max(version) FROM reward_rules WHERE challenge_id = $1) ORDER BY tier",
            connection, transaction))
        {
            latest.Parameters.Add(new NpgsqlParameter { Value = request.ChallengeId });
            await using var reader = await latest.ExecuteReaderAsync(ct);
            var amounts = new List<int>();
            while (await reader.ReadAsync(ct))
            {
                amounts.Add(reader.GetInt32(0));
                version = reader.GetInt32(1) + 1;
            }

            if (amounts.Count > 0)
            {
                previousTiers = amounts is [0] ? [] : amounts;
            }
        }

        // Retire = one row, tier 1, amount 0.
        IReadOnlyList<int> tiers = request.Tiers.Count == 0 ? [0] : request.Tiers;
        DateTimeOffset effectiveFrom = default;
        for (var i = 0; i < tiers.Count; i++)
        {
            await using var insert = new NpgsqlCommand(
                """
                INSERT INTO reward_rules (challenge_id, currency, amount, tier, cycle, ends_at, version, created_by)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING effective_from
                """, connection, transaction);
            insert.Parameters.Add(new NpgsqlParameter { Value = request.ChallengeId });
            insert.Parameters.Add(new NpgsqlParameter { Value = request.Currency });
            insert.Parameters.Add(new NpgsqlParameter { Value = tiers[i] });
            insert.Parameters.Add(new NpgsqlParameter { Value = i + 1 });
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
            new RewardRuleChangedPayload(request.ChallengeId, request.Currency, request.Tiers, request.Cycle, request.EndsAt,
                version, previousTiers, adminName), ct);
        return new RewardRule(request.ChallengeId, request.Currency, [.. request.Tiers], request.Cycle, request.EndsAt, version,
            effectiveFrom, adminName);
    }

    /// <summary>
    /// Fills challenges that have NO rule yet: a restart never overwrites an admin's version. Returns how many ladders it
    /// created. Each is a normal version 1 with its event.
    /// </summary>
    public static async Task<int> SeedAsync(NpgsqlDataSource dataSource, IEnumerable<RewardRuleRequest> seeds,
        int maxAmount, int maxTiers, DateTimeOffset now, CancellationToken ct)
    {
        var created = 0;
        foreach (var seed in seeds)
        {
            if (Validate(seed, maxAmount, maxTiers, now) is not null || seed.Tiers.Count == 0)  // a seed never retires
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

    private sealed record TierRow(string ChallengeId, string Currency, int Amount, int Tier, string Cycle, DateTimeOffset? EndsAt,
        int Version, DateTimeOffset EffectiveFrom, string CreatedBy);

    private static async Task<List<TierRow>> ReadRowsAsync(NpgsqlDataReader reader, CancellationToken ct)
    {
        var rows = new List<TierRow>();
        while (await reader.ReadAsync(ct))
        {
            rows.Add(new TierRow(reader.GetString(0), reader.GetString(1), reader.GetInt32(2), reader.GetInt32(3), reader.GetString(4),
                reader.IsDBNull(5) ? null : reader.GetFieldValue<DateTimeOffset>(5), reader.GetInt32(6),
                reader.GetFieldValue<DateTimeOffset>(7), reader.GetString(8)));
        }

        return rows;
    }

    /// <summary>Rows come ordered by challenge then tier; one ladder per challenge (the caller selected one version each).</summary>
    private static List<RewardRule> ReadLadders(List<TierRow> rows) =>
    [
        .. rows.GroupBy(r => r.ChallengeId).Select(g =>
        {
            var first = g.First();
            IReadOnlyList<int> tiers = first.Amount == 0 ? [] : [.. g.Select(r => r.Amount)];  // a retired version is one row of 0
            return new RewardRule(first.ChallengeId, first.Currency, tiers, first.Cycle, first.EndsAt, first.Version,
                first.EffectiveFrom, first.CreatedBy);
        }),
    ];
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
