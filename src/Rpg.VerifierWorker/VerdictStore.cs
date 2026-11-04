using System.Text.Json;
using Npgsql;
using NpgsqlTypes;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Events;
using Rpg.Contracts.Serialization;
using Rpg.Verification;

namespace Rpg.VerifierWorker;

/// <param name="ConditionsJson">The stored conditions, as text.</param>
/// <param name="ActionLogJson">The stored action log, as text.</param>
public sealed record BattleRow(string BattleId, Guid RunId, int RunSeq, Guid PlayerId, string Status, string Ruleset,
    string ConditionsJson, string ActionLogJson, DateTimeOffset SubmittedAt, int Attempts);

public enum SettlementResult { None, Rejected, NoReward, AlreadyMarked, Granted }

/// <param name="Committed">False: someone else already decided this battle, nothing changed.</param>
public sealed record CommitResult(bool Committed, SettlementResult Result, IReadOnlyList<Grant> Grants);

public sealed record Grant(string CharacterId, string BossId, int Gems, int BalanceAfter);

/// <summary>
/// The worker's Postgres access (spec battle-verify 3.2, settlement-outbox 2.2). The verdict write is guarded by
/// <c>status = 'Submitted'</c>: that conditional update, not a lock and not the queue, is what makes redelivery a no-op.
/// </summary>
public sealed class VerdictStore(NpgsqlDataSource dataSource)
{
    public const string RequiredMigration = "0004_settlement_outbox.sql";

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
    /// The verdict, the settlement and the events that describe them, in ONE transaction (spec settlement-outbox 2.2).
    /// The guarded update is the first idempotency gate: zero rows means someone else already decided, and nothing
    /// below runs. The completion-mark primary key and the ledger's unique key are the second.
    /// </summary>
    public async Task<CommitResult> CommitAsync(BattleRow row, BattleVerdict verdict, SettlementOptions settlement,
        DateTimeOffset now, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);

        await using (var update = new NpgsqlCommand(
            """
            UPDATE battle_sessions
            SET status = $2, verdict = $3, verified_at = $4, verifier_version = $5, attempts = attempts + 1
            WHERE battle_id = $1 AND status = 'Submitted'
            """, connection, transaction))
        {
            update.Parameters.Add(new NpgsqlParameter { Value = row.BattleId });
            update.Parameters.Add(new NpgsqlParameter { Value = verdict.Status.ToString() });
            update.Parameters.Add(new NpgsqlParameter
            {
                NpgsqlDbType = NpgsqlDbType.Jsonb, Value = JsonSerializer.Serialize(verdict, RpgJson.Options),
            });
            update.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            update.Parameters.Add(new NpgsqlParameter { Value = verdict.VerifierRulesetVersion });
            if (await update.ExecuteNonQueryAsync(ct) != 1)
            {
                await transaction.RollbackAsync(CancellationToken.None);
                return new CommitResult(false, SettlementResult.None, []);
            }
        }

        var result = verdict.Status == ReplayVerdict.Verified ? SettlementResult.NoReward : SettlementResult.Rejected;
        if (verdict.Status == ReplayVerdict.Verified)
        {
            await WriteEventAsync(connection, transaction, row, EventTypes.BattleVerified, EventTopics.Battle, now,
                new BattleVerifiedPayload(row.BattleId, row.RunSeq, verdict.Outcome, verdict.Turns, verdict.FinalStateHash,
                    verdict.Facts?.EncounterId), ct);
        }
        else
        {
            await WriteEventAsync(connection, transaction, row, EventTypes.BattleRejected, EventTopics.Battle, now,
                new BattleRejectedPayload(row.BattleId, row.RunSeq, verdict.ErrorCode ?? ReplayErrors.ReplayMismatchCode,
                    verdict.Mismatch?.Reason), ct);
        }

        var grants = new List<Grant>();
        if (settlement.Enabled && settlement.GemsPerBossMark > 0 && verdict.Status == ReplayVerdict.Verified
            && verdict.Outcome == BattleOutcome.Victory && verdict.Facts is { BossIds.Count: > 0 } facts)
        {
            var claimed = false;
            foreach (var character in facts.PartyCharacterIds.Distinct())
            {
                foreach (var boss in facts.BossIds.Distinct())
                {
                    claimed = true;
                    if (await GrantMarkAsync(connection, transaction, row, character, boss, settlement.GemsPerBossMark, now, ct)
                        is { } grant)
                    {
                        grants.Add(grant);
                    }
                }
            }

            result = grants.Count > 0 ? SettlementResult.Granted : claimed ? SettlementResult.AlreadyMarked : result;
        }

        await transaction.CommitAsync(ct);
        return new CommitResult(true, result, grants);
    }

    /// <summary>The first win of this character over this boss pays once, ever; null when the mark exists already.</summary>
    private static async Task<Grant?> GrantMarkAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        BattleRow row, string character, string boss, int gems, DateTimeOffset now, CancellationToken ct)
    {
        await using (var mark = new NpgsqlCommand(
            """
            INSERT INTO completion_marks (player_id, character_id, boss_id, battle_id, granted_at)
            VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING
            """, connection, transaction))
        {
            mark.Parameters.Add(new NpgsqlParameter { Value = row.PlayerId });
            mark.Parameters.Add(new NpgsqlParameter { Value = character });
            mark.Parameters.Add(new NpgsqlParameter { Value = boss });
            mark.Parameters.Add(new NpgsqlParameter { Value = row.BattleId });
            mark.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            if (await mark.ExecuteNonQueryAsync(ct) != 1)
            {
                return null;
            }
        }

        await using (var ledger = new NpgsqlCommand(
            """
            INSERT INTO wallet_ledger (player_id, currency, delta, reason, ref_battle_id, idempotency_key, created_at)
            VALUES ($1, 'gems', $2, 'completion_mark', $3, $4, $5) ON CONFLICT (idempotency_key) DO NOTHING
            """, connection, transaction))
        {
            ledger.Parameters.Add(new NpgsqlParameter { Value = row.PlayerId });
            ledger.Parameters.Add(new NpgsqlParameter { Value = gems });
            ledger.Parameters.Add(new NpgsqlParameter { Value = row.BattleId });
            ledger.Parameters.Add(new NpgsqlParameter { Value = $"mark:{row.BattleId}:{character}:{boss}" });
            ledger.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            if (await ledger.ExecuteNonQueryAsync(ct) != 1)
            {
                return null;  // the ledger already holds this grant: no money moves twice
            }
        }

        int balance;
        await using (var wallet = new NpgsqlCommand(
            """
            INSERT INTO wallets (player_id, gems, version, updated_at) VALUES ($1, $2, 1, $3)
            ON CONFLICT (player_id) DO UPDATE
              SET gems = wallets.gems + EXCLUDED.gems, version = wallets.version + 1, updated_at = EXCLUDED.updated_at
            RETURNING gems
            """, connection, transaction))
        {
            wallet.Parameters.Add(new NpgsqlParameter { Value = row.PlayerId });
            wallet.Parameters.Add(new NpgsqlParameter { Value = gems });
            wallet.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            balance = (int)(await wallet.ExecuteScalarAsync(ct))!;
        }

        await WriteEventAsync(connection, transaction, row, EventTypes.RewardGranted, EventTopics.Economy, now,
            new RewardGrantedPayload("completion_mark", row.BattleId, character, boss, "gems", gems, balance), ct);
        return new Grant(character, boss, gems, balance);
    }

    private static Task WriteEventAsync<TPayload>(NpgsqlConnection connection, NpgsqlTransaction transaction, BattleRow row,
        string type, string topic, DateTimeOffset now, TPayload payload, CancellationToken ct)
    {
        var id = Guid.NewGuid();
        var envelope = new DomainEvent<TPayload>(id, type, 1, row.PlayerId, row.RunId, now, row.Ruleset, payload);
        return OutboxWriter.InsertAsync(connection, transaction,
            new OutboxMessage(id, OutboxDestination.Redpanda, topic, row.PlayerId.ToString("D"), type,
                JsonSerializer.Serialize(envelope, RpgJson.Options)), ct);
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
