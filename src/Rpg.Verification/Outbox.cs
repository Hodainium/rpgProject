using System.Diagnostics;
using Npgsql;
using NpgsqlTypes;

namespace Rpg.Verification;

public static class OutboxDestination
{
    public const string Rabbit = "rabbit";
    public const string Redpanda = "redpanda";
}

/// <summary>One row to write to the outbox (spec settlement-outbox 3.2).</summary>
/// <param name="Id">The event id.</param>
/// <param name="Topic">RabbitMQ routing key or Redpanda topic.</param>
/// <param name="Key">The ordering scope: battleId for jobs, playerId for events.</param>
/// <param name="PayloadJson">The message body, as JSON text (the event envelope, or the job).</param>
/// <param name="TraceParent">W3C <c>traceparent</c> to store; null = the writing code's <c>Activity.Current</c> (spec economy-rewards 3.8).</param>
public sealed record OutboxMessage(Guid Id, string Destination, string Topic, string Key, string Type, string PayloadJson,
    string? TraceParent = null);

/// <summary>
/// Writes outbox rows inside the caller's transaction, so a row exists exactly when the change it announces committed
/// (spec settlement-outbox 2.1, 2.2). Nothing is ever published from request or worker code.
/// <para>
/// Order: the relay publishes a key's rows in <c>seq</c> order and never leases a row while an earlier row of its key is
/// unpublished. But <c>seq</c> is drawn at insert and the relay sees only committed rows, so two transactions writing one
/// key could commit in the other order. The insert therefore takes a SHARED transaction-scoped advisory lock on
/// (destination, key) before it draws <c>seq</c>, held until the transaction ends; the relay leases a key's rows only when
/// it gets the EXCLUSIVE lock with a try (<c>OutboxStore.LeaseAsync</c>), i.e. when no writer of the key is still open.
/// Writers never wait for each other (shared locks), and the relay never waits at all, so this adds no deadlock.
/// </para>
/// </summary>
public static class OutboxWriter
{
    public static async Task InsertAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, OutboxMessage message,
        CancellationToken ct)
    {
        await using var command = new NpgsqlCommand(
            """
            WITH key_lock AS (
              SELECT pg_advisory_xact_lock_shared(hashtextextended('outbox:' || $2::text || ':' || $4::text, 0)))
            INSERT INTO outbox (id, destination, topic, key, type, payload, traceparent)
            SELECT $1, $2, $3, $4, $5, $6, $7 FROM key_lock
            """, connection, transaction);
        command.Parameters.Add(new NpgsqlParameter { Value = message.Id });
        command.Parameters.Add(new NpgsqlParameter { Value = message.Destination });
        command.Parameters.Add(new NpgsqlParameter { Value = message.Topic });
        command.Parameters.Add(new NpgsqlParameter { Value = message.Key });
        command.Parameters.Add(new NpgsqlParameter { Value = message.Type });
        command.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Jsonb, Value = message.PayloadJson });
        command.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Text, Value = (object?)(message.TraceParent ?? Activity.Current?.Id) ?? DBNull.Value });
        await command.ExecuteNonQueryAsync(ct);
    }
}
