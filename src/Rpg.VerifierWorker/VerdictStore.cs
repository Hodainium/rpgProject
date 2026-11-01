using System.Text.Json;
using Npgsql;
using NpgsqlTypes;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Serialization;

namespace Rpg.VerifierWorker;

/// <param name="ConditionsJson">The stored conditions, as text.</param>
/// <param name="ActionLogJson">The stored action log, as text.</param>
public sealed record BattleRow(string BattleId, Guid RunId, int RunSeq, Guid PlayerId, string Status, string Ruleset,
    string ConditionsJson, string ActionLogJson, DateTimeOffset SubmittedAt, int Attempts);

/// <summary>
/// The worker's Postgres access (spec battle-verify 3.2). The verdict write is guarded by <c>status = 'Submitted'</c>:
/// that conditional update, not the Redis lock and not the queue, is what makes redelivery a no-op.
/// </summary>
public sealed class VerdictStore(NpgsqlDataSource dataSource)
{
    public const string RequiredMigration = "0003_battle_verdicts.sql";

    /// <summary>Blocks until the API has applied the verdict migration (the worker never migrates).</summary>
    public async Task WaitForSchemaAsync(TimeSpan interval, CancellationToken ct)
    {
        while (true)
        {
            try
            {
                await using var command = dataSource.CreateCommand("SELECT 1 FROM schema_migrations WHERE name = $1");
                command.Parameters.Add(new NpgsqlParameter { Value = RequiredMigration });
                if (await command.ExecuteScalarAsync(ct) is not null)
                {
                    return;
                }
            }
            catch (Exception ex) when (ex is NpgsqlException)
            {
                // Postgres down, or no migrations table yet: keep waiting.
            }

            await Task.Delay(interval, ct);
        }
    }

    public async Task<BattleRow?> LoadAsync(string battleId, CancellationToken ct)
    {
        await using var command = dataSource.CreateCommand(
            """
            SELECT b.run_id, b.run_seq, r.player_id, b.status, b.ruleset_version, b.conditions::text, b.action_log::text,
                   b.submitted_at, b.attempts
            FROM battle_sessions b JOIN runs r ON r.run_id = b.run_id
            WHERE b.battle_id = $1
            """);
        command.Parameters.Add(new NpgsqlParameter { Value = battleId });
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct)
            ? new BattleRow(battleId, reader.GetGuid(0), reader.GetInt32(1), reader.GetGuid(2), reader.GetString(3),
                reader.GetString(4), reader.GetString(5), reader.GetString(6), reader.GetFieldValue<DateTimeOffset>(7),
                reader.GetInt32(8))
            : null;
    }

    /// <summary>
    /// Commits the verdict if the session is still Submitted. False means someone else already did (a redelivery, a
    /// second worker): nothing changed.
    /// </summary>
    public async Task<bool> CommitVerdictAsync(string battleId, BattleVerdict verdict, DateTimeOffset now, CancellationToken ct)
    {
        await using var command = dataSource.CreateCommand(
            """
            UPDATE battle_sessions
            SET status = $2, verdict = $3, verified_at = $4, verifier_version = $5, attempts = attempts + 1
            WHERE battle_id = $1 AND status = 'Submitted'
            """);
        command.Parameters.Add(new NpgsqlParameter { Value = battleId });
        command.Parameters.Add(new NpgsqlParameter { Value = verdict.Status.ToString() });
        command.Parameters.Add(new NpgsqlParameter
        {
            NpgsqlDbType = NpgsqlDbType.Jsonb, Value = JsonSerializer.Serialize(verdict, RpgJson.Options),
        });
        command.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
        command.Parameters.Add(new NpgsqlParameter { Value = verdict.VerifierRulesetVersion });
        return await command.ExecuteNonQueryAsync(ct) == 1;
    }

    /// <summary>
    /// A worker took the job: the session's <c>enqueued_at</c> becomes now, so the API's sweeper never sees a job that is
    /// being replayed as one that was lost (spec battle-verify 2.4).
    /// </summary>
    public async Task RenewLeaseAsync(string battleId, DateTimeOffset now, CancellationToken ct)
    {
        await using var command = dataSource.CreateCommand(
            "UPDATE battle_sessions SET enqueued_at = $2 WHERE battle_id = $1 AND status = 'Submitted'");
        command.Parameters.Add(new NpgsqlParameter { Value = battleId });
        command.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
        await command.ExecuteNonQueryAsync(ct);
    }

    /// <summary>Counts one runner error; returns the attempts so far.</summary>
    public async Task<int> RecordAttemptAsync(string battleId, CancellationToken ct)
    {
        await using var command = dataSource.CreateCommand(
            "UPDATE battle_sessions SET attempts = attempts + 1 WHERE battle_id = $1 RETURNING attempts");
        command.Parameters.Add(new NpgsqlParameter { Value = battleId });
        return await command.ExecuteScalarAsync(ct) is int attempts ? attempts : 0;
    }

    /// <summary>Marks the session dead-lettered so the sweeper leaves it alone (3.2).</summary>
    public async Task DeadLetterAsync(string battleId, string reason, DateTimeOffset now, CancellationToken ct)
    {
        await using var command = dataSource.CreateCommand(
            """
            UPDATE battle_sessions SET dead_lettered_at = $2, dead_letter_reason = $3
            WHERE battle_id = $1 AND status = 'Submitted'
            """);
        command.Parameters.Add(new NpgsqlParameter { Value = battleId });
        command.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
        command.Parameters.Add(new NpgsqlParameter { Value = reason });
        await command.ExecuteNonQueryAsync(ct);
    }
}
