using Npgsql;
using Rpg.Contracts.Cards;
using Rpg.Contracts.Events;
using static Rpg.Economy.Cards.CardSql;

namespace Rpg.Economy.Cards;

public sealed partial class CardStore
{
    // ---- rules admin (2.7) -----------------------------------------------------------------------------------------

    /// <summary>A new version of one rarity's rates plus its event, in one transaction under an advisory lock.</summary>
    public async Task<CardResult<CardRate>> PutRateAsync(CardRateRequest request, Guid adminId, string adminName, DateTimeOffset now,
        int maxCost, CancellationToken ct, bool onlyIfAbsent = false)
    {
        if (CardRules.ValidateRate(request, maxCost) is { } problem)
        {
            return CardResult<CardRate>.Fail(CardFailure.RuleInvalid, problem);
        }

        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        await LockNamedAsync(connection, transaction, $"card_rate|{request.Rarity}", ct);
        var version = 1;
        await using (var latest = Cmd(connection, transaction, "SELECT COALESCE(max(version), 0) FROM card_rates WHERE rarity = $1", request.Rarity))
        {
            version = (int)(await latest.ExecuteScalarAsync(ct))! + 1;
        }

        if (onlyIfAbsent && version > 1)
        {
            return new CardResult<CardRate>(null, null);   // a row exists: the seed leaves it alone
        }

        DateTimeOffset effectiveFrom;
        await using (var insert = Cmd(connection, transaction,
                         "INSERT INTO card_rates (rarity, version, dust_value, craft_cost, created_by) VALUES ($1, $2, $3, $4, $5) RETURNING effective_from",
                         request.Rarity, version, request.DustValue, request.CraftCost, adminName))
        {
            effectiveFrom = new DateTimeOffset(DateTime.SpecifyKind((DateTime)(await insert.ExecuteScalarAsync(ct))!, DateTimeKind.Utc));
        }

        await EconomyEvents.WriteAsync(connection, transaction, adminId, null, "economy", EventTypes.CardRatesChanged,
            EventTopics.Economy, $"rule:rate:{request.Rarity}", now,
            new CardRatesChangedPayload(request.Rarity, request.DustValue, request.CraftCost, version, adminName), ct);
        await transaction.CommitAsync(ct);
        return CardResult<CardRate>.Ok(new CardRate(request.Rarity, request.DustValue, request.CraftCost, version, effectiveFrom, adminName));
    }

    public async Task<CardResult<PackType>> PutPackTypeAsync(PackTypeRequest request, Guid adminId, string adminName, DateTimeOffset now,
        int maxPrice, CancellationToken ct, bool onlyIfAbsent = false)
    {
        if (CardRules.ValidatePackType(request, maxPrice) is { } problem)
        {
            return CardResult<PackType>.Fail(CardFailure.RuleInvalid, problem);
        }

        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        await LockNamedAsync(connection, transaction, $"pack_type|{request.PackId}", ct);

        var distinctSets = request.SetIds.Distinct().ToArray();
        await using (var sets = Cmd(connection, transaction, "SELECT count(DISTINCT set_id) FROM cards WHERE set_id = ANY($1)", new NpgsqlParameter { Value = distinctSets }))
        {
            if ((long)(await sets.ExecuteScalarAsync(ct))! != distinctSets.Length)
            {
                return CardResult<PackType>.Fail(CardFailure.RuleInvalid, "setIds names a set that has no cards in the catalog.");
            }
        }

        // A pack nobody can draw from (every rarity with odds has no eligible card) would fail every open: refuse it here.
        if (!request.Retired && !PackDrawer.CanDraw(request.OddsPer10000, await EligibleAsync(connection, transaction, distinctSets, ct)))
        {
            return CardResult<PackType>.Fail(CardFailure.RuleInvalid,
                "No rarity with odds above 0 has an eligible card (non-core, not retired) in the pack's sets.");
        }

        int version;
        await using (var latest = Cmd(connection, transaction, "SELECT COALESCE(max(version), 0) FROM pack_types WHERE pack_id = $1", request.PackId))
        {
            version = (int)(await latest.ExecuteScalarAsync(ct))! + 1;
        }

        if (onlyIfAbsent && version > 1)
        {
            return new CardResult<PackType>(null, null);
        }

        var pity = request.PityPacks ?? new Dictionary<string, int>();
        var first = request.FirstGuarantees ?? new Dictionary<string, int>();
        DateTimeOffset effectiveFrom;
        await using (var insert = Cmd(connection, transaction,
                         """
                         INSERT INTO pack_types (pack_id, version, name, price_gems, card_count, odds, set_ids, retired, pity, first_guarantees,
                                                 min_rarity, created_by)
                         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) RETURNING effective_from
                         """,
                         request.PackId, version, request.Name, request.PriceGems, request.CardCount, Json(Serialize(request.OddsPer10000)),
                         distinctSets, request.Retired, Json(Serialize(pity)), Json(Serialize(first)), Text(request.MinRarityPerPack), adminName))
        {
            effectiveFrom = new DateTimeOffset(DateTime.SpecifyKind((DateTime)(await insert.ExecuteScalarAsync(ct))!, DateTimeKind.Utc));
        }

        await EconomyEvents.WriteAsync(connection, transaction, adminId, null, "economy", EventTypes.PackTypeChanged,
            EventTopics.Economy, $"rule:pack:{request.PackId}", now,
            new PackTypeChangedPayload(request.PackId, version, request.PriceGems, request.Retired, adminName), ct);
        await transaction.CommitAsync(ct);
        return CardResult<PackType>.Ok(new PackType(request.PackId, request.Name, version, request.PriceGems, request.CardCount,
            request.OddsPer10000, distinctSets, request.Retired, pity, first, request.MinRarityPerPack, effectiveFrom, adminName));
    }

    public async Task<IReadOnlyList<CardRate>> ListRatesAsync(CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        return [.. (await LatestRatesAsync(connection, null, ct)).Values.OrderBy(r => PackDrawer.Rank(r.Rarity))];
    }

    public async Task<IReadOnlyList<PackType>> ListPackTypesAsync(CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        return [.. (await CardSql.LatestPacksAsync(connection, null, ct)).OrderBy(p => p.PackId, StringComparer.Ordinal)];
    }

    // ---- the run's pool (2.5) --------------------------------------------------------------------------------------

    /// <summary>
    /// Inside the run-start transaction, after <see cref="CardSql.LockAccountAsync"/>: the unlocked characters (core and owned)
    /// and the item pool (core item cards and owned ones), or a null value when no catalog is seeded. A party member the account does not have is
    /// <see cref="CardFailure.CharacterLocked"/>. The result is stored on the run and never read from the client again.
    /// </summary>
    public static async Task<CardResult<RunPool>> SnapshotForRunAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        Guid playerId, IReadOnlyList<string> characterIds, CancellationToken ct)
    {
        // A server that has no catalog yet (nothing seeded) has no cards to enforce: the run starts as it always did, no pool.
        await using (var any = Cmd(connection, transaction, "SELECT EXISTS (SELECT 1 FROM cards)"))
        {
            if (!(bool)(await any.ExecuteScalarAsync(ct))!)
            {
                return new CardResult<RunPool>(null, null);
            }
        }

        var characters = new List<string>();
        var items = new List<string>();
        await using (var select = Cmd(connection, transaction,
                         """
                         SELECT c.card_id, c.kind FROM cards c
                         WHERE (c.core AND NOT c.retired)
                            OR EXISTS (SELECT 1 FROM card_holdings h WHERE h.player_id = $1 AND h.card_id = c.card_id)
                         """, playerId))
        await using (var reader = await select.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                (reader.GetString(1) == CardKinds.Character ? characters : items).Add(reader.GetString(0));
            }
        }

        characters.Sort(StringComparer.Ordinal);
        items.Sort(StringComparer.Ordinal);
        if (characterIds.FirstOrDefault(id => !characters.Contains(id)) is { } locked)
        {
            return CardResult<RunPool>.Fail(CardFailure.CharacterLocked, $"The account has not unlocked '{locked}'.");
        }

        return CardResult<RunPool>.Ok(new RunPool(characters, items));
    }
}
