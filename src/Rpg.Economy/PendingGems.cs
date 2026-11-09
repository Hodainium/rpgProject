using Npgsql;
using Rpg.Contracts.Events;

namespace Rpg.Economy;

/// <summary>
/// Pending gems (spec run-verify 2.5): a settlement run on a verifier step writes ledger rows as <c>pending</c> and leaves
/// the wallet and the completion marks alone. A row is released when the battle's step is inside the run's verified prefix:
/// that is when the mark is claimed, and a row whose mark is already held (another run was paid first) is voided as
/// <c>AlreadyPaid</c> instead. A rollback voids the rows of the battles it drops. Every transition is a guarded
/// <c>UPDATE … WHERE status = 'pending'</c>, so it happens exactly once however often it is tried.
/// </summary>
public static class PendingGems
{
    private sealed record PendingRow(long Id, Guid PlayerId, int Delta, string? CharacterId, string BattleId,
        string? ChallengeId, int? RuleVersion, string? CycleKey, string Ruleset);

    /// <param name="Gems">Gems paid out.</param>
    /// <param name="Claimed">Completion marks claimed with a payment.</param>
    /// <param name="AlreadyPaid">Rows voided because the mark was already held.</param>
    public sealed record ReleaseResult(int Gems, int Claimed, int AlreadyPaid);

    /// <summary>Releases the pending rows of every battle of the run whose seq is at most <paramref name="upToSeq"/>.</summary>
    public static async Task<ReleaseResult> ReleaseAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        int upToSeq, DateTimeOffset now, CancellationToken ct)
    {
        var released = 0;
        var paid = 0;
        var alreadyPaid = 0;
        foreach (var row in await LoadAsync(connection, transaction, runId, "b.run_seq <= $2", upToSeq, ct))
        {
            await using (var update = new NpgsqlCommand(
                "UPDATE wallet_ledger SET status = 'released', released_at = $2 WHERE id = $1 AND status = 'pending'",
                connection, transaction))
            {
                update.Parameters.Add(new NpgsqlParameter { Value = row.Id });
                update.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
                if (await update.ExecuteNonQueryAsync(ct) != 1)
                {
                    continue;
                }
            }

            // The mark is claimed now, with the payment: the first row released for this player, character, challenge and cycle
            // wins it, whichever run it belongs to or order the battles were fought in.
            int claimed;
            await using (var mark = new NpgsqlCommand(
                """
                INSERT INTO completion_marks (player_id, character_id, challenge_id, cycle_key, battle_id, granted_at)
                VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT DO NOTHING
                """, connection, transaction))
            {
                mark.Parameters.Add(new NpgsqlParameter { Value = row.PlayerId });
                mark.Parameters.Add(new NpgsqlParameter { Value = row.CharacterId ?? "" });
                mark.Parameters.Add(new NpgsqlParameter { Value = row.ChallengeId ?? "" });
                mark.Parameters.Add(new NpgsqlParameter { Value = row.CycleKey ?? "" });
                mark.Parameters.Add(new NpgsqlParameter { Value = row.BattleId });
                mark.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
                claimed = await mark.ExecuteNonQueryAsync(ct);
            }

            if (claimed != 1)
            {
                await using (var already = new NpgsqlCommand(
                    """
                    UPDATE wallet_ledger SET status = 'voided', released_at = NULL, idempotency_key = idempotency_key || '#voided:' || id
                    WHERE id = $1
                    """, connection, transaction))
                {
                    already.Parameters.Add(new NpgsqlParameter { Value = row.Id });
                    await already.ExecuteNonQueryAsync(ct);
                }

                await EconomyEvents.WriteAsync(connection, transaction, row.PlayerId, runId, row.Ruleset,
                    EventTypes.RewardVoided, EventTopics.Economy, row.PlayerId.ToString("D"), now,
                    new RewardVoidedPayload(row.BattleId, row.CharacterId ?? "", row.ChallengeId ?? "", row.CycleKey ?? "",
                        row.Delta, "AlreadyPaid"), ct);
                alreadyPaid++;
                continue;
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
                wallet.Parameters.Add(new NpgsqlParameter { Value = row.Delta });
                wallet.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
                balance = (int)(await wallet.ExecuteScalarAsync(ct))!;
            }

            var bossId = row.ChallengeId is not null && ChallengeIds.IsBossChallenge(row.ChallengeId)
                ? row.ChallengeId[ChallengeIds.BossPrefix.Length..]
                : null;
            await EconomyEvents.WriteAsync(connection, transaction, row.PlayerId, runId, row.Ruleset,
                EventTypes.RewardGranted, EventTopics.Economy, row.PlayerId.ToString("D"), now,
                new RewardGrantedPayload("completion_mark", row.BattleId, row.CharacterId ?? "", bossId, "gems", row.Delta,
                    balance, row.RuleVersion ?? 0, row.ChallengeId ?? "", row.CycleKey ?? ""), ct);
            released += row.Delta;
            paid++;
        }

        return new ReleaseResult(released, paid, alreadyPaid);
    }

    /// <summary>
    /// Voids the pending rows of every battle of the run whose seq is greater than <paramref name="afterSeq"/>. A pending row
    /// holds no completion mark (the mark is claimed at release), so there is nothing to free: a legitimate replay of the boss
    /// pays when its own row is released. Run this <b>before</b> the battle sessions are deleted: it reads them to find the
    /// run's battles.
    /// </summary>
    /// <returns>The gems voided.</returns>
    public static async Task<int> VoidAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        int afterSeq, string reason, DateTimeOffset now, CancellationToken ct)
    {
        var voided = 0;
        foreach (var row in await LoadAsync(connection, transaction, runId, "b.run_seq > $2", afterSeq, ct))
        {
            await using (var update = new NpgsqlCommand(
                // The idempotency key is freed with the void, so a legitimate replay of the same battle (the same deterministic
                // id) can pay again; the voided row keeps a unique, marked key for the record.
                "UPDATE wallet_ledger SET status = 'voided', idempotency_key = idempotency_key || '#voided:' || id WHERE id = $1 AND status = 'pending'",
                connection, transaction))
            {
                update.Parameters.Add(new NpgsqlParameter { Value = row.Id });
                if (await update.ExecuteNonQueryAsync(ct) != 1)
                {
                    continue;
                }
            }


            await EconomyEvents.WriteAsync(connection, transaction, row.PlayerId, runId, row.Ruleset,
                EventTypes.RewardVoided, EventTopics.Economy, row.PlayerId.ToString("D"), now,
                new RewardVoidedPayload(row.BattleId, row.CharacterId ?? "", row.ChallengeId ?? "", row.CycleKey ?? "",
                    row.Delta, reason), ct);
            voided += row.Delta;
        }

        return voided;
    }

    private static async Task<List<PendingRow>> LoadAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        Guid runId, string seqFilter, int seq, CancellationToken ct)
    {
        var rows = new List<PendingRow>();
        await using var select = new NpgsqlCommand(
            $"""
            SELECT l.id, l.player_id, l.delta, l.character_id, l.ref_battle_id, l.challenge_id, l.rule_version, l.cycle_key,
                   r.ruleset_version
            FROM wallet_ledger l
            JOIN battle_sessions b ON b.battle_id = l.ref_battle_id
            JOIN runs r ON r.run_id = b.run_id
            WHERE l.status = 'pending' AND b.run_id = $1 AND {seqFilter}
            ORDER BY l.id
            FOR UPDATE OF l
            """, connection, transaction);
        select.Parameters.Add(new NpgsqlParameter { Value = runId });
        select.Parameters.Add(new NpgsqlParameter { Value = seq });
        await using var reader = await select.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            rows.Add(new PendingRow(reader.GetInt64(0), reader.GetGuid(1), reader.GetInt32(2),
                reader.IsDBNull(3) ? null : reader.GetString(3), reader.GetString(4),
                reader.IsDBNull(5) ? null : reader.GetString(5), reader.IsDBNull(6) ? null : reader.GetInt32(6),
                reader.IsDBNull(7) ? null : reader.GetString(7), reader.GetString(8)));
        }

        return rows;
    }
}
