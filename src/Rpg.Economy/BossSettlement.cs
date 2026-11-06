using Npgsql;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Economy;
using Rpg.Contracts.Events;

namespace Rpg.Economy;

/// <summary>Who a settlement is for: the battle's owner and where it came from.</summary>
public sealed record SettlementContext(Guid PlayerId, Guid RunId, string BattleId, string Ruleset);

public sealed record Grant(string CharacterId, string BossId, int Gems, int BalanceAfter, int RuleVersion);

/// <summary>What one settlement did (spec economy-rewards 2.2). Callers map it to metrics.</summary>
/// <param name="Claimed">Marks the settlement tried to write (granted or already held).</param>
/// <param name="Found">Bosses whose rule paid.</param>
/// <param name="Missing">Bosses with no rule in force.</param>
/// <param name="Retired">Bosses whose latest rule has amount 0.</param>
/// <param name="BadIds">Character or boss ids that cannot sit in a ledger key (F10).</param>
public sealed record SettlementSummary(IReadOnlyList<Grant> Grants, int Claimed, int Found, int Missing, int Retired, int BadIds);

/// <summary>
/// The first win of a character over a boss pays once, ever, at the rule in force when it is settled (spec
/// economy-rewards 2.2). Everything is written in the caller's transaction: the mark, the ledger row, the wallet and the
/// <c>RewardGranted</c> event. The mark's primary key and the ledger's unique key are the exactly-once gates.
/// </summary>
public static class BossSettlement
{
    public static async Task<SettlementSummary> SettleAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        SettlementContext context, BattleFacts facts, DateTimeOffset now, CancellationToken ct)
    {
        var grants = new List<Grant>();
        int claimed = 0, found = 0, missing = 0, retired = 0, badIds = 0;
        var characters = facts.PartyCharacterIds.Distinct().ToList();
        foreach (var boss in facts.BossIds.Distinct())
        {
            if (!RewardRules.IsKeySafeId(boss))
            {
                badIds++;
                continue;
            }

            var rule = await RewardRules.LookupAsync(connection, transaction, RewardSourceKinds.Boss, boss, ct);
            if (rule is null)
            {
                missing++;
                continue;
            }

            if (rule.Amount == 0)
            {
                retired++;
                continue;
            }

            found++;
            foreach (var character in characters)
            {
                if (!RewardRules.IsKeySafeId(character))
                {
                    badIds++;
                    continue;
                }

                claimed++;
                if (await GrantMarkAsync(connection, transaction, context, character, boss, rule, now, ct) is { } grant)
                {
                    grants.Add(grant);
                }
            }
        }

        return new SettlementSummary(grants, claimed, found, missing, retired, badIds);
    }

    /// <summary>Null when the mark or the ledger row exists already: no money moves twice.</summary>
    private static async Task<Grant?> GrantMarkAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        SettlementContext context, string character, string boss, RewardRule rule, DateTimeOffset now, CancellationToken ct)
    {
        await using (var mark = new NpgsqlCommand(
            """
            INSERT INTO completion_marks (player_id, character_id, boss_id, battle_id, granted_at)
            VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING
            """, connection, transaction))
        {
            mark.Parameters.Add(new NpgsqlParameter { Value = context.PlayerId });
            mark.Parameters.Add(new NpgsqlParameter { Value = character });
            mark.Parameters.Add(new NpgsqlParameter { Value = boss });
            mark.Parameters.Add(new NpgsqlParameter { Value = context.BattleId });
            mark.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            if (await mark.ExecuteNonQueryAsync(ct) != 1)
            {
                return null;
            }
        }

        await using (var ledger = new NpgsqlCommand(
            """
            INSERT INTO wallet_ledger (player_id, currency, delta, reason, ref_battle_id, idempotency_key, created_at,
                                       source_kind, source_id, rule_version)
            VALUES ($1, $2, $3, 'completion_mark', $4, $5, $6, $7, $8, $9) ON CONFLICT (idempotency_key) DO NOTHING
            """, connection, transaction))
        {
            ledger.Parameters.Add(new NpgsqlParameter { Value = context.PlayerId });
            ledger.Parameters.Add(new NpgsqlParameter { Value = rule.Currency });
            ledger.Parameters.Add(new NpgsqlParameter { Value = rule.Amount });
            ledger.Parameters.Add(new NpgsqlParameter { Value = context.BattleId });
            ledger.Parameters.Add(new NpgsqlParameter { Value = $"mark:{context.BattleId}:{character}:{boss}" });
            ledger.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            ledger.Parameters.Add(new NpgsqlParameter { Value = rule.SourceKind });
            ledger.Parameters.Add(new NpgsqlParameter { Value = boss });
            ledger.Parameters.Add(new NpgsqlParameter { Value = rule.Version });
            if (await ledger.ExecuteNonQueryAsync(ct) != 1)
            {
                return null;
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
            wallet.Parameters.Add(new NpgsqlParameter { Value = context.PlayerId });
            wallet.Parameters.Add(new NpgsqlParameter { Value = rule.Amount });
            wallet.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            balance = (int)(await wallet.ExecuteScalarAsync(ct))!;
        }

        await EconomyEvents.WriteAsync(connection, transaction, context.PlayerId, context.RunId, context.Ruleset,
            EventTypes.RewardGranted, EventTopics.Economy, context.PlayerId.ToString("D"), now,
            new RewardGrantedPayload("completion_mark", context.BattleId, character, boss, rule.Currency, rule.Amount, balance,
                rule.Version), ct);
        return new Grant(character, boss, rule.Amount, balance, rule.Version);
    }
}
