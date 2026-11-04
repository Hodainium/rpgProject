using Npgsql;
using Rpg.GameServerApi.Migrations;

namespace Rpg.GameServerApi.Outbox;

/// <summary>A leased outbox row. <paramref name="Attempts"/> already counts this lease.</summary>
public sealed record OutboxRow(Guid Id, long Seq, string Destination, string Topic, string Key, string Type,
    string PayloadJson, string? TraceParent, int Attempts);

/// <param name="Pending">Unpublished, not dead-lettered rows.</param>
/// <param name="OldestAge">Seconds since the oldest of them was created (0 when none).</param>
public sealed record OutboxStats(string Destination, long Pending, double OldestAge, long DeadLettered);

/// <summary>
/// The relay's Postgres access (spec settlement-outbox 2.1, 3.4). A row is leased with one short statement and published
/// with no lock held. A row is leased only when no earlier unpublished row has the same destination and key, so one
/// player's events stay in order across retries.
/// </summary>
public sealed class OutboxStore(NpgsqlDataSource dataSource, MigrationRunner migrations)
{
    public async Task<IReadOnlyList<OutboxRow>> LeaseAsync(int limit, TimeSpan lease, DateTimeOffset now, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand(
            """
            UPDATE outbox SET leased_until = $1, attempts = attempts + 1
            WHERE id IN (
              SELECT c.id FROM outbox c
              WHERE c.published_at IS NULL AND c.dead_lettered_at IS NULL
                AND (c.leased_until IS NULL OR c.leased_until < $2)
                AND NOT EXISTS (
                  SELECT 1 FROM outbox e
                  WHERE e.destination = c.destination AND e.key = c.key AND e.seq < c.seq
                    AND e.published_at IS NULL AND e.dead_lettered_at IS NULL)
              ORDER BY c.seq
              LIMIT $3
              FOR UPDATE OF c SKIP LOCKED)
            RETURNING id, seq, destination, topic, key, type, payload::text, traceparent, attempts
            """);
        command.Parameters.Add(new NpgsqlParameter { Value = (now + lease).ToUniversalTime() });
        command.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
        command.Parameters.Add(new NpgsqlParameter { Value = limit });
        var rows = new List<OutboxRow>();
        await using var reader = await command.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            rows.Add(new OutboxRow(reader.GetGuid(0), reader.GetInt64(1), reader.GetString(2), reader.GetString(3),
                reader.GetString(4), reader.GetString(5), reader.GetString(6),
                reader.IsDBNull(7) ? null : reader.GetString(7), reader.GetInt32(8)));
        }

        return [.. rows.OrderBy(r => r.Seq)];
    }

    public Task MarkPublishedAsync(Guid id, DateTimeOffset now, CancellationToken ct) => ExecuteAsync(
        "UPDATE outbox SET published_at = $2, leased_until = NULL WHERE id = $1", ct, id, now.ToUniversalTime());

    /// <summary>The row stays unpublished and invisible until <paramref name="retryAt"/>: the backoff.</summary>
    public Task ScheduleRetryAsync(Guid id, DateTimeOffset retryAt, CancellationToken ct) => ExecuteAsync(
        "UPDATE outbox SET leased_until = $2 WHERE id = $1 AND published_at IS NULL", ct, id, retryAt.ToUniversalTime());

    /// <summary>Gives a lease back unused (the attempt is not counted): the rest of a batch after a transient failure.</summary>
    public Task ReleaseAsync(IReadOnlyCollection<Guid> ids, CancellationToken ct) => ExecuteAsync(
        "UPDATE outbox SET leased_until = NULL, attempts = attempts - 1 WHERE id = ANY($1) AND published_at IS NULL", ct,
        ids.ToArray());

    public Task DeadLetterAsync(Guid id, string reason, DateTimeOffset now, CancellationToken ct) => ExecuteAsync(
        "UPDATE outbox SET dead_lettered_at = $2, dead_letter_reason = $3, leased_until = NULL WHERE id = $1 AND published_at IS NULL",
        ct, id, now.ToUniversalTime(), reason);

    public async Task<IReadOnlyList<OutboxStats>> StatsAsync(DateTimeOffset now, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand(
            """
            SELECT destination,
                   count(*) FILTER (WHERE published_at IS NULL AND dead_lettered_at IS NULL),
                   min(created_at) FILTER (WHERE published_at IS NULL AND dead_lettered_at IS NULL),
                   count(*) FILTER (WHERE published_at IS NULL AND dead_lettered_at IS NOT NULL)
            FROM outbox GROUP BY destination
            """);
        var stats = new List<OutboxStats>();
        await using var reader = await command.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var oldest = reader.IsDBNull(2) ? (DateTimeOffset?)null : reader.GetFieldValue<DateTimeOffset>(2);
            stats.Add(new OutboxStats(reader.GetString(0), reader.GetInt64(1),
                oldest is null ? 0 : Math.Max(0, (now - oldest.Value).TotalSeconds), reader.GetInt64(3)));
        }

        return stats;
    }

    private async Task ExecuteAsync(string sql, CancellationToken ct, params object[] parameters)
    {
        await using var command = dataSource.CreateCommand(sql);
        foreach (var value in parameters)
        {
            command.Parameters.Add(new NpgsqlParameter { Value = value });
        }

        await command.ExecuteNonQueryAsync(ct);
    }
}
