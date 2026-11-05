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
/// </summary>
public static class OutboxWriter
{
    public static async Task InsertAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, OutboxMessage message,
        CancellationToken ct)
    {
        await using var command = new NpgsqlCommand(
            """
            INSERT INTO outbox (id, destination, topic, key, type, payload, traceparent)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
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
