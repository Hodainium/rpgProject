using Npgsql;
using Rpg.GameServerApi.Migrations;

namespace Rpg.GameServerApi.Outbox;

/// <summary>A leased outbox row. <paramref name="Attempts"/> already counts this lease. <paramref name="LeaseToken"/> is the
/// lease call's token: every follow-up write checks it, so a relay that lost the lease changes nothing.</summary>
public sealed record OutboxRow(Guid Id, long Seq, string Destination, string Topic, string Key, string Type,
    string PayloadJson, string? TraceParent, int Attempts, Guid LeaseToken = default);

/// <param name="Pending">Unpublished, not dead-lettered rows.</param>
/// <param name="OldestAge">Seconds since the oldest of them was created (0 when none).</param>
public sealed record OutboxStats(string Destination, long Pending, double OldestAge, long DeadLettered);

/// <summary>
/// The relay's Postgres access (spec settlement-outbox 2.1, 3.4). A row is leased with one short statement and published
/// with no lock held. A row is leased only when no earlier unpublished row has the same destination and key, so one
/// player's events stay in order across retries. Two more things make that hold. A key's rows are leased only while no
/// transaction that wrote one is still open: the writer holds a shared advisory lock on the key until it commits
/// (<see cref="Rpg.Verification.OutboxWriter"/>) and the lease takes the exclusive one with a try, so an earlier row
/// that commits after a later one is never skipped. And the lease is fenced by a token (migration 0009), so a relay
/// whose lease ran out mid-batch can no longer publish or update the row (<see cref="RenewAsync"/> before each publish).
/// </summary>
public sealed class OutboxStore(NpgsqlDataSource dataSource, MigrationRunner migrations)
{
    public async Task<IReadOnlyList<OutboxRow>> LeaseAsync(int limit, TimeSpan lease, DateTimeOffset now, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand(
            """
            WITH candidates AS MATERIALIZED (
              SELECT c.id, c.destination, c.key FROM outbox c
              WHERE c.published_at IS NULL AND c.dead_lettered_at IS NULL
                AND (c.leased_until IS NULL OR c.leased_until < $2)
                AND NOT EXISTS (
                  SELECT 1 FROM outbox e
                  WHERE e.destination = c.destination AND e.key = c.key AND e.seq < c.seq
                    AND e.published_at IS NULL AND e.dead_lettered_at IS NULL)
              ORDER BY c.seq
              LIMIT $3
              FOR UPDATE OF c SKIP LOCKED),
            -- No transaction that wrote a row of this key is still open (OutboxWriter holds the key's shared lock until it
            -- ends), so no earlier row of the key can commit after this one is leased. A try: the relay never waits. Run
            -- over the materialized candidates only (at most $3 locks), never over the backlog.
            free AS MATERIALIZED (
              SELECT id FROM candidates
              WHERE pg_try_advisory_xact_lock(hashtextextended('outbox:' || destination || ':' || key, 0)))
            UPDATE outbox SET leased_until = $1, attempts = attempts + 1, lease_token = $4
            WHERE id IN (SELECT id FROM free)
            RETURNING id, seq, destination, topic, key, type, payload::text, traceparent, attempts
            """);
        command.Parameters.Add(new NpgsqlParameter { Value = (now + lease).ToUniversalTime() });
        command.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
        command.Parameters.Add(new NpgsqlParameter { Value = limit });
        var token = Guid.NewGuid();
        command.Parameters.Add(new NpgsqlParameter { Value = token });
        var rows = new List<OutboxRow>();
        await using var reader = await command.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            rows.Add(new OutboxRow(reader.GetGuid(0), reader.GetInt64(1), reader.GetString(2), reader.GetString(3),
                reader.GetString(4), reader.GetString(5), reader.GetString(6),
                reader.IsDBNull(7) ? null : reader.GetString(7), reader.GetInt32(8), token));
        }

        return [.. rows.OrderBy(r => r.Seq)];
    }

    /// <summary>
    /// Extends the row's lease to <paramref name="until"/> if this relay still holds it (same token, not published, not
    /// dead-lettered). The relay calls it right before each publish: false means another relay took the row after this
    /// lease ran out, so publishing it now could put it after a later row of its key. Skip it.
    /// </summary>
    public async Task<bool> RenewAsync(OutboxRow row, DateTimeOffset until, CancellationToken ct) => await ExecuteAsync(
        """
        UPDATE outbox SET leased_until = $3
        WHERE id = $1 AND lease_token = $2 AND published_at IS NULL AND dead_lettered_at IS NULL
        """, ct, row.Id, row.LeaseToken, until.ToUniversalTime()) == 1;

    public Task<int> MarkPublishedAsync(OutboxRow row, DateTimeOffset now, CancellationToken ct) => ExecuteAsync(
        "UPDATE outbox SET published_at = $3, leased_until = NULL WHERE id = $1 AND lease_token = $2 AND published_at IS NULL",
        ct, row.Id, row.LeaseToken, now.ToUniversalTime());

    /// <summary>The row stays unpublished and invisible until <paramref name="retryAt"/>: the backoff.</summary>
    public Task<int> ScheduleRetryAsync(OutboxRow row, DateTimeOffset retryAt, CancellationToken ct) => ExecuteAsync(
        "UPDATE outbox SET leased_until = $3 WHERE id = $1 AND lease_token = $2 AND published_at IS NULL", ct, row.Id,
        row.LeaseToken, retryAt.ToUniversalTime());

    /// <summary>Gives a lease back unused (the attempt is not counted): the rest of a batch after a transient failure. Rows
    /// another relay has leased since (a different token) are left alone.</summary>
    public Task<int> ReleaseAsync(IReadOnlyCollection<OutboxRow> rows, CancellationToken ct) => ExecuteAsync(
        """
        UPDATE outbox SET leased_until = NULL, attempts = attempts - 1
        WHERE id = ANY($1) AND lease_token = $2 AND published_at IS NULL
        """, ct, rows.Select(r => r.Id).ToArray(), rows.First().LeaseToken);

    public Task<int> DeadLetterAsync(OutboxRow row, string reason, DateTimeOffset now, CancellationToken ct) => ExecuteAsync(
        """
        UPDATE outbox SET dead_lettered_at = $3, dead_letter_reason = $4, leased_until = NULL
        WHERE id = $1 AND lease_token = $2 AND published_at IS NULL
        """, ct, row.Id, row.LeaseToken, now.ToUniversalTime(), reason);

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

    private async Task<int> ExecuteAsync(string sql, CancellationToken ct, params object[] parameters)
    {
        await using var command = dataSource.CreateCommand(sql);
        foreach (var value in parameters)
        {
            command.Parameters.Add(new NpgsqlParameter { Value = value });
        }

        return await command.ExecuteNonQueryAsync(ct);
    }
}
