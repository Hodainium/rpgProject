using System.Security.Cryptography;
using Rpg.Contracts.Cards;
using Rpg.Contracts.Events;
using static Rpg.Economy.Cards.CardSql;

namespace Rpg.Economy.Cards;

public sealed partial class CardStore
{
    // ---- buy packs (spec pack-shop 2.1) ----------------------------------------------------------------------------

    /// <summary>
    /// Spends gems for <paramref name="count"/> unopened packs of the type's latest version on sale. One transaction under the
    /// account lock: the wallet ledger, the pack inventory and its ledger, the outbox event and the request row.
    /// </summary>
    public async Task<CardResult<PackBuyResponse>> BuyPacksAsync(Guid playerId, string playerName, string packId, int count,
        int maxPerBuy, Guid key, AccountFence fence, DateTimeOffset now, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        await LockAccountAsync(connection, transaction, playerId, ct);
        await EnsurePlayerAsync(connection, transaction, playerId, playerName, now, ct);

        // A count below 1 (or missing, which reads as 0) is malformed before anything else: no stored answer can match it.
        if (count < 1)
        {
            return CardResult<PackBuyResponse>.Fail(CardFailure.RuleInvalid, $"A buy is 1 to {maxPerBuy} packs; {count} was asked.");
        }

        // The count is part of the request: the same key with another count is a different request (1407). The replay comes
        // before the upper bound, so a committed buy is still answered after Cards:MaxPacksPerBuy is lowered.
        var hash = Hash("pack_buy", $"{packId}|{count}");
        if (await ReplayAsync<PackBuyResponse>(connection, transaction, playerId, key, "pack_buy", hash, ct) is { } replay)
        {
            return replay;
        }

        if (count > maxPerBuy)
        {
            return CardResult<PackBuyResponse>.Fail(CardFailure.RuleInvalid, $"A buy is 1 to {maxPerBuy} packs; {count} was asked.");
        }

        // Spec account-session 2.2: after the replay (a committed buy is answered whatever the session or version now) and the
        // malformed count (a 400 never turns into a refetch).
        if (await FenceAsync(connection, transaction, playerId, fence, ct) is { } fenced)
        {
            return CardResult<PackBuyResponse>.Fail(fenced);
        }

        // The price comes from Postgres inside the transaction, never from a cache: a stale price must not sell.
        var pack = await LatestPackAsync(connection, transaction, packId, ct);
        if (pack is null || pack.Retired)
        {
            return CardResult<PackBuyResponse>.Fail(CardFailure.PackUnavailable, $"No pack type '{packId}' is on sale.");
        }

        // Never sell a pack that cannot be opened. The save already checked it; this is the net for what changed since
        // (a catalog update that retired the cards it draws from, a rate removed).
        await LockNamedSharedAsync(connection, transaction, "card_catalog", ct);
        if (CardRules.OpenProblem(pack.Odds, pack.Pity, pack.FirstGuarantees, await EligibleAsync(connection, transaction, pack.SetIds, ct),
                await LatestRatesAsync(connection, transaction, ct)) is { } closed)
        {
            return CardResult<PackBuyResponse>.Fail(CardFailure.PackUnavailable, $"Pack '{packId}' cannot be sold right now: {closed}.");
        }

        var total = (long)pack.PriceGems * count;
        if (total > int.MaxValue)
        {
            return CardResult<PackBuyResponse>.Fail(CardFailure.RuleInvalid, $"{count} packs at {pack.PriceGems} gems is too large a buy.");
        }

        var (gems, _) = await LockWalletAsync(connection, transaction, playerId, ct);
        if (gems < total)
        {
            return CardResult<PackBuyResponse>.Fail(CardFailure.InsufficientCurrency,
                $"{count} pack(s) cost {total} gems; the account has {gems}.");
        }

        var spent = (int)total;
        var prefix = $"pack_buy:{playerId:D}:{key:D}";
        await LedgerAsync(connection, transaction, playerId, "gems", -spent, "pack_buy", $"{prefix}:gems",
            $"pack:{pack.PackId}:{pack.Version}", now, ct);
        var (gemsAfter, _, version) = await MoveWalletAsync(connection, transaction, playerId, -spent, 0, now, ct);
        var owned = await MovePacksAsync(connection, transaction, playerId, pack.PackId, count, ct);
        await PackLedgerAsync(connection, transaction, playerId, pack.PackId, pack.Version, count, "buy", key, null, ct);

        var response = new PackBuyResponse(pack.PackId, pack.Version, count, spent, gemsAfter, owned, version);
        await RecordRequestAsync(connection, transaction, playerId, key, "pack_buy", hash, response, now, ct);
        await EventAsync(connection, transaction, playerId, EventTypes.PackPurchased, now,
            new PackPurchasedPayload(playerId.ToString("D"), pack.PackId, pack.Version, count, spent), ct);
        await transaction.CommitAsync(ct);
        return CardResult<PackBuyResponse>.Ok(response);
    }

    /// <summary>The player's unopened packs of one type, locked for this transaction (0 when there is no row).</summary>
    private static async Task<int> LockOwnedPacksAsync(Npgsql.NpgsqlConnection connection, Npgsql.NpgsqlTransaction transaction,
        Guid playerId, string packId, CancellationToken ct)
    {
        await using var select = Cmd(connection, transaction,
            "SELECT count FROM pack_inventory WHERE player_id = $1 AND pack_id = $2 FOR UPDATE", playerId, packId);
        return await select.ExecuteScalarAsync(ct) is int count ? count : 0;
    }

    /// <summary>Adds to the inventory (negative = open); the CHECK (count >= 0) is the last guard. Returns the new count.</summary>
    private static async Task<int> MovePacksAsync(Npgsql.NpgsqlConnection connection, Npgsql.NpgsqlTransaction transaction,
        Guid playerId, string packId, int delta, CancellationToken ct)
    {
        // A spend updates the row the caller locked; only a buy may create it (an INSERT of a negative count would trip the
        // CHECK before ON CONFLICT is considered).
        await using var command = Cmd(connection, transaction, delta < 0
            ? "UPDATE pack_inventory SET count = count + $3, updated_at = clock_timestamp() WHERE player_id = $1 AND pack_id = $2 RETURNING count"
            : """
              INSERT INTO pack_inventory (player_id, pack_id, count, updated_at) VALUES ($1, $2, $3, clock_timestamp())
              ON CONFLICT (player_id, pack_id) DO UPDATE SET count = pack_inventory.count + EXCLUDED.count, updated_at = EXCLUDED.updated_at
              RETURNING count
              """, playerId, packId, delta);
        return (int)(await command.ExecuteScalarAsync(ct))!;
    }

    private static Task PackLedgerAsync(Npgsql.NpgsqlConnection connection, Npgsql.NpgsqlTransaction transaction, Guid playerId,
        string packId, int packVersion, int delta, string reason, Guid key, Guid? openingId, CancellationToken ct) =>
        ExecAsync(connection, transaction,
            """
            INSERT INTO pack_ledger (player_id, pack_id, pack_version, delta, reason, request_key, opening_id, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, clock_timestamp())
            """, ct, playerId, packId, packVersion, delta, reason, key, openingId);

    // ---- open a pack (2.2; spec pack-shop 2.2: spends an owned pack, not gems) -------------------------------------

    public async Task<CardResult<PackOpenResponse>> OpenPackAsync(Guid playerId, string playerName, string packId, Guid key,
        AccountFence fence, DateTimeOffset now, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        await LockAccountAsync(connection, transaction, playerId, ct);
        await EnsurePlayerAsync(connection, transaction, playerId, playerName, now, ct);

        var hash = Hash("pack", packId);
        if (await ReplayAsync<PackOpenResponse>(connection, transaction, playerId, key, "pack", hash, ct) is { } replay)
        {
            return replay;
        }

        if (await FenceAsync(connection, transaction, playerId, fence, ct) is { } fenced)
        {
            return CardResult<PackOpenResponse>.Fail(fenced);
        }

        // Spec pack-shop 2.2: an open spends one owned pack. Nothing is written on a refusal (no draw, no pity change).
        var ownedPacks = await LockOwnedPacksAsync(connection, transaction, playerId, packId, ct);
        if (ownedPacks <= 0)
        {
            return CardResult<PackOpenResponse>.Fail(CardFailure.NoPackOwned, $"The account owns no unopened '{packId}' pack.");
        }

        // The type's latest version, retired or not: a pack bought before a retirement still opens with its last version.
        // Rules come from Postgres inside the transaction, never from a cache (F21).
        var pack = await LatestPackAsync(connection, transaction, packId, ct);
        if (pack is null)
        {
            return CardResult<PackOpenResponse>.Fail(CardFailure.PackUnavailable, $"No pack type '{packId}'.");
        }

        if (pack.Refunding)
        {
            // Spec pack-shop 2.5: the type was retired with a refund; the pack stays owned until the Open packs page pays it back,
            // or, held for a support check, until operations settles it.
            return CardResult<PackOpenResponse>.Fail(CardFailure.PackUnavailable,
                await RefundHeldAsync(connection, transaction, playerId, packId, pack.Version, ct)
                    ? $"Pack '{packId}' was retired; refunding the packs you still hold needs a support check."
                    : $"Pack '{packId}' was retired and is being refunded: its gems come back on the Open packs page.");
        }

        var rates = await LatestRatesAsync(connection, transaction, ct);
        // Review fix: the drawn-from cards and the stored catalog_version must be one catalog (an audit re-derives the opening
        // from catalog_versions). A re-seed holds "card_catalog" exclusively while it rewrites `cards`; this waits for it.
        await LockNamedSharedAsync(connection, transaction, "card_catalog", ct);
        var eligible = await EligibleAsync(connection, transaction, pack.SetIds, ct);
        if (CardRules.OpenProblem(pack.Odds, pack.Pity, pack.FirstGuarantees, eligible, rates) is { } closed)
        {
            // Something changed since the save (the catalog, the rates): nothing is spent, the pack stays owned.
            return CardResult<PackOpenResponse>.Fail(CardFailure.PackUnavailable, $"Pack '{packId}' cannot be opened right now: {closed}.");
        }

        var missedBefore = await MissedAsync(connection, transaction, playerId, pack, forUpdate: true, ct);
        var catalogVersion = await CatalogVersionAsync(connection, transaction, ct);

        var drawSeed = BitConverter.ToInt64(RandomNumberGenerator.GetBytes(8));
        var draw = PackDrawer.Draw(drawSeed, pack.Config, eligible, missedBefore);

        var owned = new HashSet<string>(StringComparer.Ordinal);
        await using (var select = Cmd(connection, transaction, "SELECT card_id FROM card_holdings WHERE player_id = $1", playerId))
        await using (var reader = await select.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                owned.Add(reader.GetString(0));
            }
        }

        var openingId = Guid.NewGuid();
        var prefix = $"pack:{playerId:D}:{key:D}";
        var cards = new List<PackCardDto>();
        var dustTotal = 0;
        var newCards = 0;
        for (var i = 0; i < draw.Cards.Count; i++)
        {
            var drawn = draw.Cards[i];
            if (!rates.TryGetValue(drawn.Rarity, out var rate))
            {
                // Review fix: a rules gap, not a server error. Nothing is committed, so nothing is charged.
                return CardResult<PackOpenResponse>.Fail(CardFailure.PackUnavailable,
                    $"Pack '{packId}' cannot be opened right now: rarity '{drawn.Rarity}' has no card rate.");
            }

            if (owned.Add(drawn.CardId))
            {
                newCards++;
                // clock_timestamp(), inside the account lock: the run lock compares it with a run's start taken the same way.
                await ExecAsync(connection, transaction,
                    "INSERT INTO card_holdings (player_id, card_id, acquired_at, source) VALUES ($1, $2, clock_timestamp(), 'pack')", ct,
                    playerId, drawn.CardId);
                await CardLedgerAsync(connection, transaction, playerId, drawn.CardId, 1, "pack", openingId.ToString("D"),
                    $"{prefix}:{i}", now, ct);
                cards.Add(new PackCardDto(drawn.CardId, drawn.Rarity, false, 0, drawn.Pity));
            }
            else
            {
                dustTotal += rate.DustValue;
                await LedgerAsync(connection, transaction, playerId, "dust", rate.DustValue, "duplicate", $"{prefix}:{i}",
                    $"rate:{rate.Rarity}:{rate.Version}", now, ct);
                cards.Add(new PackCardDto(drawn.CardId, drawn.Rarity, true, rate.DustValue, drawn.Pity));
            }
        }

        // An open moves no gems, but it always moves the account's version: the collection's AccountVersion tells a client the
        // cards and owned packs changed, dust or not.
        await WalletRowAsync(connection, transaction, playerId, ct);
        var (gemsAfter, dustAfter, version) = await MoveWalletAsync(connection, transaction, playerId, 0, dustTotal, now, ct);
        var packsLeft = await MovePacksAsync(connection, transaction, playerId, pack.PackId, -1, ct);
        await PackLedgerAsync(connection, transaction, playerId, pack.PackId, pack.Version, -1, "open", key, openingId, ct);

        foreach (var (rarity, missed) in draw.MissedAfter)
        {
            await ExecAsync(connection, transaction,
                """
                INSERT INTO pack_pity (player_id, pack_id, rarity, missed) VALUES ($1, $2, $3, $4)
                ON CONFLICT (player_id, pack_id, rarity) DO UPDATE SET missed = EXCLUDED.missed
                """, ct, playerId, pack.PackId, rarity, missed);
        }

        var response = new PackOpenResponse(openingId.ToString("D"), pack.PackId, pack.Version, 0, cards, gemsAfter,
            dustAfter, drawSeed.ToString(), packsLeft, version);
        await ExecAsync(connection, transaction,
            """
            INSERT INTO pack_openings (opening_id, player_id, pack_id, pack_version, catalog_version, draw_seed, pity_before, result, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            """, ct, openingId, playerId, pack.PackId, pack.Version, catalogVersion, drawSeed, Json(Serialize(missedBefore)),
            Json(Serialize(response)), now.ToUniversalTime());
        await RecordRequestAsync(connection, transaction, playerId, key, "pack", hash, response, now, ct);
        await EventAsync(connection, transaction, playerId, EventTypes.PackOpened, now,
            new PackOpenedPayload(response.OpeningId, playerId.ToString("D"), pack.PackId, pack.Version, 0, cards,
                dustTotal, newCards, response.DrawSeed, catalogVersion, cards.Count(c => c.Pity)), ct);
        await transaction.CommitAsync(ct);
        return CardResult<PackOpenResponse>.Ok(response);
    }

    private static async Task<int> CatalogVersionAsync(Npgsql.NpgsqlConnection connection, Npgsql.NpgsqlTransaction transaction,
        CancellationToken ct)
    {
        await using var command = Cmd(connection, transaction, "SELECT COALESCE(max(catalog_version), 0) FROM catalog_versions");
        return (int)(await command.ExecuteScalarAsync(ct))!;
    }

    // ---- dust (2.3) ------------------------------------------------------------------------------------------------

    public async Task<CardResult<DustResponse>> DustAsync(Guid playerId, string playerName, string cardId, Guid key,
        AccountFence fence, DateTimeOffset now, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        await LockAccountAsync(connection, transaction, playerId, ct);
        await EnsurePlayerAsync(connection, transaction, playerId, playerName, now, ct);

        var hash = Hash("dust", cardId);
        if (await ReplayAsync<DustResponse>(connection, transaction, playerId, key, "dust", hash, ct) is { } replay)
        {
            return replay;
        }

        if (await FenceAsync(connection, transaction, playerId, fence, ct) is { } fenced)
        {
            return CardResult<DustResponse>.Fail(fenced);
        }

        var card = await FindCardAsync(connection, transaction, cardId, ct);
        if (card is null || card.Core)
        {
            return CardResult<DustResponse>.Fail(CardFailure.CardNotCollectible,
                card is null ? $"No card '{cardId}'." : $"'{cardId}' is a core card: every account owns it and it cannot be dusted.");
        }

        DateTimeOffset acquired;
        await using (var select = Cmd(connection, transaction,
                         "SELECT acquired_at FROM card_holdings WHERE player_id = $1 AND card_id = $2 FOR UPDATE", playerId, cardId))
        await using (var reader = await select.ExecuteReaderAsync(ct))
        {
            if (!await reader.ReadAsync(ct))
            {
                return CardResult<DustResponse>.Fail(CardFailure.CardNotOwned, $"The account does not own '{cardId}'.");
            }

            acquired = reader.GetFieldValue<DateTimeOffset>(0);
        }

        // The run lock (spec 2.3): a card held when the active run started is part of what the run was built from.
        if (await ActiveRunAsync(connection, transaction, playerId, ct) is { } run && acquired <= run.StartedAt)
        {
            return CardResult<DustResponse>.Fail(CardFailure.CardLockedByRun,
                $"'{cardId}' was owned when run {run.RunId:D} started; it cannot be dusted until the run ends.",
                run.RunId.ToString("D"), run.Status);
        }

        var rates = await LatestRatesAsync(connection, transaction, ct);
        if (!rates.TryGetValue(card.Rarity, out var rate))
        {
            return CardResult<DustResponse>.Fail(CardFailure.CardNotCollectible,
                $"'{cardId}' cannot be dusted right now: rarity '{card.Rarity}' has no card rate.");
        }

        await ExecAsync(connection, transaction, "DELETE FROM card_holdings WHERE player_id = $1 AND card_id = $2", ct, playerId, cardId);
        var prefix = $"dust:{playerId:D}:{key:D}";
        await CardLedgerAsync(connection, transaction, playerId, cardId, -1, "dust", key.ToString("D"), prefix, now, ct);
        await WalletRowAsync(connection, transaction, playerId, ct);
        await LedgerAsync(connection, transaction, playerId, "dust", rate.DustValue, "dust", prefix, $"rate:{rate.Rarity}:{rate.Version}", now, ct);
        var (_, dust, version) = await MoveWalletAsync(connection, transaction, playerId, 0, rate.DustValue, now, ct);

        var response = new DustResponse(cardId, rate.DustValue, rate.Version, dust, version);
        await RecordRequestAsync(connection, transaction, playerId, key, "dust", hash, response, now, ct);
        await EventAsync(connection, transaction, playerId, EventTypes.CardDusted, now,
            new CardDustedPayload(playerId.ToString("D"), cardId, card.Rarity, rate.DustValue, rate.Version), ct);
        await transaction.CommitAsync(ct);
        return CardResult<DustResponse>.Ok(response);
    }

    // ---- craft (2.4) -----------------------------------------------------------------------------------------------

    public async Task<CardResult<CraftResponse>> CraftAsync(Guid playerId, string playerName, string cardId, Guid key,
        AccountFence fence, DateTimeOffset now, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        await LockAccountAsync(connection, transaction, playerId, ct);
        await EnsurePlayerAsync(connection, transaction, playerId, playerName, now, ct);

        var hash = Hash("craft", cardId);
        if (await ReplayAsync<CraftResponse>(connection, transaction, playerId, key, "craft", hash, ct) is { } replay)
        {
            return replay;
        }

        if (await FenceAsync(connection, transaction, playerId, fence, ct) is { } fenced)
        {
            return CardResult<CraftResponse>.Fail(fenced);
        }

        var card = await FindCardAsync(connection, transaction, cardId, ct);
        if (card is null || card.Core || card.Retired)
        {
            return CardResult<CraftResponse>.Fail(CardFailure.CardNotCollectible,
                card is null ? $"No card '{cardId}'." : $"'{cardId}' cannot be crafted ({(card.Core ? "core" : "retired")}).");
        }

        await using (var owned = Cmd(connection, transaction,
                         "SELECT 1 FROM card_holdings WHERE player_id = $1 AND card_id = $2", playerId, cardId))
        {
            if (await owned.ExecuteScalarAsync(ct) is not null)
            {
                return CardResult<CraftResponse>.Fail(CardFailure.CardAlreadyOwned, $"The account already owns '{cardId}'.");
            }
        }

        var rates = await LatestRatesAsync(connection, transaction, ct);
        if (!rates.TryGetValue(card.Rarity, out var rate))
        {
            return CardResult<CraftResponse>.Fail(CardFailure.CardNotCollectible,
                $"'{cardId}' cannot be crafted right now: rarity '{card.Rarity}' has no card rate.");
        }

        var (_, dust) = await LockWalletAsync(connection, transaction, playerId, ct);
        if (dust < rate.CraftCost)
        {
            return CardResult<CraftResponse>.Fail(CardFailure.InsufficientCurrency,
                $"Crafting '{cardId}' costs {rate.CraftCost} dust; the account has {dust}.");
        }

        var prefix = $"craft:{playerId:D}:{key:D}";
        await ExecAsync(connection, transaction,
            "INSERT INTO card_holdings (player_id, card_id, acquired_at, source) VALUES ($1, $2, clock_timestamp(), 'craft')", ct,
            playerId, cardId);
        await CardLedgerAsync(connection, transaction, playerId, cardId, 1, "craft", key.ToString("D"), prefix, now, ct);
        await LedgerAsync(connection, transaction, playerId, "dust", -rate.CraftCost, "craft", prefix, $"rate:{rate.Rarity}:{rate.Version}", now, ct);
        var (_, dustAfter, version) = await MoveWalletAsync(connection, transaction, playerId, 0, -rate.CraftCost, now, ct);

        var response = new CraftResponse(cardId, rate.CraftCost, rate.Version, dustAfter, version);
        await RecordRequestAsync(connection, transaction, playerId, key, "craft", hash, response, now, ct);
        await EventAsync(connection, transaction, playerId, EventTypes.CardCrafted, now,
            new CardCraftedPayload(playerId.ToString("D"), cardId, card.Rarity, rate.CraftCost, rate.Version), ct);
        await transaction.CommitAsync(ct);
        return CardResult<CraftResponse>.Ok(response);
    }

    private sealed record CardRow(string Rarity, bool Core, bool Retired);

    private static async Task<CardRow?> FindCardAsync(Npgsql.NpgsqlConnection connection, Npgsql.NpgsqlTransaction transaction,
        string cardId, CancellationToken ct)
    {
        await using var select = Cmd(connection, transaction, "SELECT rarity, core, retired FROM cards WHERE card_id = $1", cardId);
        await using var reader = await select.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? new CardRow(reader.GetString(0), reader.GetBoolean(1), reader.GetBoolean(2)) : null;
    }
}
