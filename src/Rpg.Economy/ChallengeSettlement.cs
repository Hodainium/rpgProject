using Npgsql;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Economy;
using Rpg.Contracts.Events;

namespace Rpg.Economy;

/// <summary>Who a settlement is for and when it counts.</summary>
/// <param name="CycleAt">The battle's <c>submitted_at</c> (plus the Development-only clock offset): the week and the expiry are decided at battle time, so redelivery computes the same key.</param>
public sealed record SettlementContext(Guid PlayerId, Guid RunId, string BattleId, string Ruleset, DateTimeOffset CycleAt);

/// <summary>One paid tier.</summary>
public sealed record Grant(string CharacterId, string ChallengeId, int Tier, int Gems, int BalanceAfter, int RuleVersion);

/// <summary>What one settlement did (spec economy-challenges 2.3). Callers map it to metrics.</summary>
/// <param name="Claimed">Marks the settlement looked at (a challenge and a character).</param>
/// <param name="Found">Challenges whose ladder paid or could pay.</param>
/// <param name="Missing">Challenges with no rule.</param>
/// <param name="Retired">Challenges whose latest ladder is retired.</param>
/// <param name="Expired">Challenges whose ladder ended before the battle was submitted.</param>
/// <param name="BadIds">Boss, challenge or character ids that cannot sit in a ledger key.</param>
/// <param name="IgnoredFacts">Completion facts dropped: a tier below 1, a bad id or the reserved <c>boss/</c> prefix.</param>
/// <param name="MarksNew">Marks created.</param>
/// <param name="MarksAdvanced">Marks whose best tier rose.</param>
/// <param name="MarksUnchanged">Marks the battle did not raise.</param>
/// <param name="MarksCapped">Marks where the reported tier was above the ladder.</param>
public sealed record SettlementSummary(IReadOnlyList<Grant> Grants, int Claimed, int Found, int Missing, int Retired, int Expired,
    int BadIds, int IgnoredFacts, int MarksNew, int MarksAdvanced, int MarksUnchanged, int MarksCapped);

/// <summary>
/// A challenge is a ladder of tiers; a higher tier pays the difference, each tier once per cycle (spec economy-challenges
/// 2.3). Everything is written in the caller's transaction: the mark, one ledger row, the wallet and one
/// <c>RewardGranted</c> event per tier. The session guard, the mark's <c>best_tier</c> and the ledger's unique key are the
/// exactly-once gates.
/// </summary>
public static class ChallengeSettlement
{
    public static async Task<SettlementSummary> SettleAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        SettlementContext context, BattleFacts facts, DateTimeOffset now, CancellationToken ct)
    {
        var grants = new List<Grant>();
        int claimed = 0, found = 0, missing = 0, retired = 0, expired = 0, badIds = 0, ignored = 0;
        int marksNew = 0, marksAdvanced = 0, marksUnchanged = 0, marksCapped = 0;

        // Bosses become (boss/<id>, tier 1); authored completions are checked; both merge by challenge id, keeping the highest tier.
        var reached = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var boss in facts.BossIds)
        {
            if (ChallengeIds.ForBoss(boss) is not { } challenge)
            {
                badIds++;
                continue;
            }

            reached[challenge] = Math.Max(reached.GetValueOrDefault(challenge), 1);
        }

        foreach (var completion in facts.Completions ?? [])
        {
            if (completion is null || completion.Tier < 1 || !ChallengeIds.IsKeySafe(completion.ChallengeId)
                || ChallengeIds.IsBossChallenge(completion.ChallengeId))
            {
                ignored++;
                continue;
            }

            reached[completion.ChallengeId] = Math.Max(reached.GetValueOrDefault(completion.ChallengeId), completion.Tier);
        }

        var characters = facts.PartyCharacterIds.Distinct().ToList();
        foreach (var (challengeId, tierReached) in reached)
        {
            var ladder = await RewardRules.LookupAsync(connection, transaction, challengeId, ct);
            if (ladder is null)
            {
                missing++;
                continue;
            }

            if (ladder.Retired)
            {
                retired++;
                continue;
            }

            if (ladder.EndsAt is { } endsAt && endsAt <= context.CycleAt)
            {
                expired++;
                continue;
            }

            found++;
            var global = await RewardRules.GenerationAsync(connection, transaction, challengeId, null, ct);
            var player = await RewardRules.GenerationAsync(connection, transaction, challengeId, context.PlayerId, ct);
            var cycleKey = RewardCycleKeys.Compute(ladder.Cycle, context.CycleAt, global, player);
            var top = Math.Min(tierReached, ladder.Tiers.Count);
            foreach (var character in characters)
            {
                if (!ChallengeIds.IsKeySafe(character))
                {
                    badIds++;
                    continue;
                }

                claimed++;
                var (best, created) = await LockMarkAsync(connection, transaction, context, character, challengeId, cycleKey, now, ct);
                if (created)
                {
                    marksNew++;
                }

                if (top < tierReached)
                {
                    marksCapped++;
                }

                if (top <= best)
                {
                    marksUnchanged++;
                    continue;
                }

                if (!created)
                {
                    marksAdvanced++;
                }

                for (var tier = best + 1; tier <= top; tier++)
                {
                    if (await PayTierAsync(connection, transaction, context, character, challengeId, ladder, tier, cycleKey, now, ct)
                        is { } grant)
                    {
                        grants.Add(grant);
                    }
                }

                await using var update = new NpgsqlCommand(
                    """
                    UPDATE completion_marks SET best_tier = $5, battle_id = $6
                    WHERE player_id = $1 AND character_id = $2 AND challenge_id = $3 AND cycle_key = $4
                    """, connection, transaction);
                update.Parameters.Add(new NpgsqlParameter { Value = context.PlayerId });
                update.Parameters.Add(new NpgsqlParameter { Value = character });
                update.Parameters.Add(new NpgsqlParameter { Value = challengeId });
                update.Parameters.Add(new NpgsqlParameter { Value = cycleKey });
                update.Parameters.Add(new NpgsqlParameter { Value = top });
                update.Parameters.Add(new NpgsqlParameter { Value = context.BattleId });
                await update.ExecuteNonQueryAsync(ct);
            }
        }

        return new SettlementSummary(grants, claimed, found, missing, retired, expired, badIds, ignored, marksNew, marksAdvanced,
            marksUnchanged, marksCapped);
    }

    /// <summary>Creates the mark at best tier 0 if absent, then locks it: a second battle of the same player and character waits and sees the first's best tier.</summary>
    private static async Task<(int Best, bool Created)> LockMarkAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        SettlementContext context, string character, string challengeId, string cycleKey, DateTimeOffset now, CancellationToken ct)
    {
        bool created;
        await using (var insert = new NpgsqlCommand(
            """
            INSERT INTO completion_marks (player_id, character_id, challenge_id, cycle_key, best_tier, battle_id, granted_at)
            VALUES ($1, $2, $3, $4, 0, $5, $6) ON CONFLICT DO NOTHING
            """, connection, transaction))
        {
            insert.Parameters.Add(new NpgsqlParameter { Value = context.PlayerId });
            insert.Parameters.Add(new NpgsqlParameter { Value = character });
            insert.Parameters.Add(new NpgsqlParameter { Value = challengeId });
            insert.Parameters.Add(new NpgsqlParameter { Value = cycleKey });
            insert.Parameters.Add(new NpgsqlParameter { Value = context.BattleId });
            insert.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            created = await insert.ExecuteNonQueryAsync(ct) == 1;
        }

        await using var select = new NpgsqlCommand(
            """
            SELECT best_tier FROM completion_marks
            WHERE player_id = $1 AND character_id = $2 AND challenge_id = $3 AND cycle_key = $4 FOR UPDATE
            """, connection, transaction);
        select.Parameters.Add(new NpgsqlParameter { Value = context.PlayerId });
        select.Parameters.Add(new NpgsqlParameter { Value = character });
        select.Parameters.Add(new NpgsqlParameter { Value = challengeId });
        select.Parameters.Add(new NpgsqlParameter { Value = cycleKey });
        return ((int)(await select.ExecuteScalarAsync(ct))!, created);
    }

    /// <summary>Null when the ledger row exists already: no money moves twice.</summary>
    private static async Task<Grant?> PayTierAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        SettlementContext context, string character, string challengeId, RewardRule ladder, int tier, string cycleKey,
        DateTimeOffset now, CancellationToken ct)
    {
        var amount = ladder.Tiers[tier - 1];
        await using (var ledger = new NpgsqlCommand(
            """
            INSERT INTO wallet_ledger (player_id, currency, delta, reason, ref_battle_id, idempotency_key, created_at,
                                       challenge_id, rule_version, tier, cycle_key)
            VALUES ($1, $2, $3, 'completion_mark', $4, $5, $6, $7, $8, $9, $10) ON CONFLICT (idempotency_key) DO NOTHING
            """, connection, transaction))
        {
            ledger.Parameters.Add(new NpgsqlParameter { Value = context.PlayerId });
            ledger.Parameters.Add(new NpgsqlParameter { Value = ladder.Currency });
            ledger.Parameters.Add(new NpgsqlParameter { Value = amount });
            ledger.Parameters.Add(new NpgsqlParameter { Value = context.BattleId });
            ledger.Parameters.Add(new NpgsqlParameter { Value = $"mark:{context.BattleId}:{character}:{challengeId}:{tier}" });
            ledger.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            ledger.Parameters.Add(new NpgsqlParameter { Value = challengeId });
            ledger.Parameters.Add(new NpgsqlParameter { Value = ladder.Version });
            ledger.Parameters.Add(new NpgsqlParameter { Value = tier });
            ledger.Parameters.Add(new NpgsqlParameter { Value = cycleKey });
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
            wallet.Parameters.Add(new NpgsqlParameter { Value = amount });
            wallet.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            balance = (int)(await wallet.ExecuteScalarAsync(ct))!;
        }

        var bossId = ChallengeIds.IsBossChallenge(challengeId) ? challengeId[ChallengeIds.BossPrefix.Length..] : null;
        await EconomyEvents.WriteAsync(connection, transaction, context.PlayerId, context.RunId, context.Ruleset,
            EventTypes.RewardGranted, EventTopics.Economy, context.PlayerId.ToString("D"), now,
            new RewardGrantedPayload("completion_mark", context.BattleId, character, bossId, ladder.Currency, amount, balance,
                ladder.Version, challengeId, tier, cycleKey), ct);
        return new Grant(character, challengeId, tier, amount, balance, ladder.Version);
    }
}
