using Npgsql;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Economy;
using Rpg.Contracts.Events;

namespace Rpg.Economy;

/// <summary>Who a settlement is for and when it counts.</summary>
/// <param name="CycleAt">The battle's <c>submitted_at</c> (plus the Development-only clock offset): the week and the expiry are decided at battle time, so redelivery computes the same key.</param>
public sealed record SettlementContext(Guid PlayerId, Guid RunId, string BattleId, string Ruleset, DateTimeOffset CycleAt);

/// <summary>One payment.</summary>
public sealed record Grant(string CharacterId, string ChallengeId, int Gems, int BalanceAfter, int RuleVersion);

/// <summary>What one settlement did (spec economy-challenges 2.3). Callers map it to metrics.</summary>
/// <param name="Claimed">Marks the settlement looked at (a challenge and a character).</param>
/// <param name="Found">Challenges whose rule could pay.</param>
/// <param name="Missing">Challenges with no rule.</param>
/// <param name="Retired">Challenges whose latest rule is retired (amount 0).</param>
/// <param name="Expired">Challenges that ended before the battle was submitted.</param>
/// <param name="BadIds">Boss, challenge or character ids that cannot sit in a ledger key.</param>
/// <param name="IgnoredFacts">Completion facts dropped: a bad id or the reserved <c>boss/</c> prefix.</param>
/// <param name="MarksNew">Marks created (a payment each).</param>
/// <param name="MarksExisting">Marks that already held this cycle: nothing paid.</param>
public sealed record SettlementSummary(IReadOnlyList<Grant> Grants, int Claimed, int Found, int Missing, int Retired, int Expired,
    int BadIds, int IgnoredFacts, int MarksNew, int MarksExisting);

/// <summary>
/// A challenge pays its amount once per character per cycle (spec economy-challenges 2.3). Everything is written in the
/// caller's transaction: the mark, the ledger row, the wallet and the <c>RewardGranted</c> event. The session guard, the
/// mark's primary key and the ledger's unique key are the exactly-once gates.
/// </summary>
public static class ChallengeSettlement
{
    public static async Task<SettlementSummary> SettleAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        SettlementContext context, BattleFacts facts, DateTimeOffset now, CancellationToken ct, bool pending = false)
    {
        var grants = new List<Grant>();
        int claimed = 0, found = 0, missing = 0, retired = 0, expired = 0, badIds = 0, ignored = 0, marksNew = 0, marksExisting = 0;

        // A boss becomes boss/<id>; an authored completion is checked; both merge by challenge id, one pass each.
        var reached = new List<string>();
        foreach (var boss in facts.BossIds)
        {
            if (ChallengeIds.ForBoss(boss) is not { } challenge)
            {
                badIds++;
            }
            else if (!reached.Contains(challenge))
            {
                reached.Add(challenge);
            }
        }

        foreach (var completion in facts.Completions ?? [])
        {
            if (completion is null || !ChallengeIds.IsKeySafe(completion.ChallengeId) || ChallengeIds.IsBossChallenge(completion.ChallengeId))
            {
                ignored++;
            }
            else if (!reached.Contains(completion.ChallengeId))
            {
                reached.Add(completion.ChallengeId);
            }
        }

        var characters = facts.PartyCharacterIds.Distinct().ToList();
        foreach (var challengeId in reached)
        {
            var rule = await RewardRules.LookupAsync(connection, transaction, challengeId, context.CycleAt, ct);
            if (rule is null)
            {
                missing++;
                continue;
            }

            if (rule.Retired)
            {
                retired++;
                continue;
            }

            if (rule.EndsAt is { } endsAt && endsAt <= context.CycleAt)
            {
                expired++;
                continue;
            }

            found++;
            var global = await RewardRules.GenerationAsync(connection, transaction, challengeId, null, ct, context.CycleAt);
            var player = await RewardRules.GenerationAsync(connection, transaction, challengeId, context.PlayerId, ct, context.CycleAt);
            var cycleKey = RewardCycleKeys.Compute(rule.Cycle, context.CycleAt, global, player);
            foreach (var character in characters)
            {
                if (!ChallengeIds.IsKeySafe(character))
                {
                    badIds++;
                    continue;
                }

                claimed++;
                if (await PayAsync(connection, transaction, context, character, rule, cycleKey, now, pending, ct) is { } grant)
                {
                    marksNew++;
                    grants.Add(grant);
                }
                else
                {
                    marksExisting++;
                }
            }
        }

        return new SettlementSummary(grants, claimed, found, missing, retired, expired, badIds, ignored, marksNew, marksExisting);
    }

    /// <summary>
    /// Null when the mark or the ledger row exists already: no money moves twice. With <paramref name="pending"/> (a
    /// verifier step's settlement, spec run-verify 2.5) the ledger row is written as pending, the wallet is untouched and
    /// the event is <c>RewardPending</c>; <see cref="PendingGems.ReleaseAsync"/> pays it later. A pending row does NOT claim the
    /// completion mark: the mark is claimed when the row is released, so an unverified or later rejected run never blocks the
    /// payment of another one (spec run-verify 2.5). It only looks: a mark already held means this cycle is paid.
    /// </summary>
    private static async Task<Grant?> PayAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        SettlementContext context, string character, RewardRule rule, string cycleKey, DateTimeOffset now, bool pending,
        CancellationToken ct)
    {
        if (pending)
        {
            await using var held = new NpgsqlCommand(
                """
                SELECT 1 FROM completion_marks
                WHERE player_id = $1 AND character_id = $2 AND challenge_id = $3 AND cycle_key = $4
                """, connection, transaction);
            held.Parameters.Add(new NpgsqlParameter { Value = context.PlayerId });
            held.Parameters.Add(new NpgsqlParameter { Value = character });
            held.Parameters.Add(new NpgsqlParameter { Value = rule.ChallengeId });
            held.Parameters.Add(new NpgsqlParameter { Value = cycleKey });
            if (await held.ExecuteScalarAsync(ct) is not null)
            {
                return null;
            }
        }
        else
        {
            await using var mark = new NpgsqlCommand(
                """
                INSERT INTO completion_marks (player_id, character_id, challenge_id, cycle_key, battle_id, granted_at)
                VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT DO NOTHING
                """, connection, transaction);
            mark.Parameters.Add(new NpgsqlParameter { Value = context.PlayerId });
            mark.Parameters.Add(new NpgsqlParameter { Value = character });
            mark.Parameters.Add(new NpgsqlParameter { Value = rule.ChallengeId });
            mark.Parameters.Add(new NpgsqlParameter { Value = cycleKey });
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
                                       challenge_id, rule_version, cycle_key, status, character_id)
            VALUES ($1, $2, $3, 'completion_mark', $4, $5, $6, $7, $8, $9, $10, $11) ON CONFLICT (idempotency_key) DO NOTHING
            """, connection, transaction))
        {
            ledger.Parameters.Add(new NpgsqlParameter { Value = context.PlayerId });
            ledger.Parameters.Add(new NpgsqlParameter { Value = rule.Currency });
            ledger.Parameters.Add(new NpgsqlParameter { Value = rule.Amount });
            ledger.Parameters.Add(new NpgsqlParameter { Value = context.BattleId });
            ledger.Parameters.Add(new NpgsqlParameter { Value = $"mark:{context.BattleId}:{character}:{rule.ChallengeId}" });
            ledger.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            ledger.Parameters.Add(new NpgsqlParameter { Value = rule.ChallengeId });
            ledger.Parameters.Add(new NpgsqlParameter { Value = rule.Version });
            ledger.Parameters.Add(new NpgsqlParameter { Value = cycleKey });
            ledger.Parameters.Add(new NpgsqlParameter { Value = pending ? "pending" : "released" });
            ledger.Parameters.Add(new NpgsqlParameter { Value = character });
            if (await ledger.ExecuteNonQueryAsync(ct) != 1)
            {
                return null;
            }
        }

        if (pending)
        {
            await EconomyEvents.WriteAsync(connection, transaction, context.PlayerId, context.RunId, context.Ruleset,
                EventTypes.RewardPending, EventTopics.Economy, context.PlayerId.ToString("D"), now,
                new RewardPendingPayload(context.BattleId, character, rule.ChallengeId, cycleKey, rule.Amount, rule.Version), ct);
            return new Grant(character, rule.ChallengeId, rule.Amount, 0, rule.Version);
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

        var bossId = ChallengeIds.IsBossChallenge(rule.ChallengeId) ? rule.ChallengeId[ChallengeIds.BossPrefix.Length..] : null;
        await EconomyEvents.WriteAsync(connection, transaction, context.PlayerId, context.RunId, context.Ruleset,
            EventTypes.RewardGranted, EventTopics.Economy, context.PlayerId.ToString("D"), now,
            new RewardGrantedPayload("completion_mark", context.BattleId, character, bossId, rule.Currency, rule.Amount, balance,
                rule.Version, rule.ChallengeId, cycleKey), ct);
        return new Grant(character, rule.ChallengeId, rule.Amount, balance, rule.Version);
    }
}
