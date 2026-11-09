using System.Security.Cryptography;
using Rpg.Contracts.Cards;
using Rpg.Contracts.Events;
using static Rpg.Economy.Cards.CardSql;

namespace Rpg.Economy.Cards;

public sealed partial class CardStore
{
    // ---- open a pack (2.2) -----------------------------------------------------------------------------------------

    public async Task<CardResult<PackOpenResponse>> OpenPackAsync(Guid playerId, string playerName, string packId, Guid key,
        DateTimeOffset now, CancellationToken ct)
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

        // Rules come from Postgres inside the transaction, never from a cache: a stale price must not sell (F21).
        var pack = await LatestPackAsync(connection, transaction, packId, ct);
        if (pack is null || pack.Retired)
        {
            return CardResult<PackOpenResponse>.Fail(CardFailure.PackUnavailable, $"No pack type '{packId}' is on sale.");
        }

        var (gems, _) = await LockWalletAsync(connection, transaction, playerId, ct);
        if (gems < pack.PriceGems)
        {
            return CardResult<PackOpenResponse>.Fail(CardFailure.InsufficientCurrency,
                $"The pack costs {pack.PriceGems} gems; the account has {gems}.");
        }

        var rates = await LatestRatesAsync(connection, transaction, ct);
        var eligible = await EligibleAsync(connection, transaction, pack.SetIds, ct);
        if (!PackDrawer.CanDraw(pack.Odds, eligible))
        {
            // A later catalog change retired everything the pack could draw: nothing is charged.
            return CardResult<PackOpenResponse>.Fail(CardFailure.PackUnavailable, $"Pack '{packId}' has no cards to draw right now.");
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
                throw new InvalidOperationException($"No card rate for rarity '{drawn.Rarity}'.");
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

        await LedgerAsync(connection, transaction, playerId, "gems", -pack.PriceGems, "pack_open", $"{prefix}:gems",
            $"pack:{pack.PackId}:{pack.Version}", now, ct);
        var (gemsAfter, dustAfter) = await MoveWalletAsync(connection, transaction, playerId, -pack.PriceGems, dustTotal, now, ct);

        foreach (var (rarity, missed) in draw.MissedAfter)
        {
            await ExecAsync(connection, transaction,
                """
                INSERT INTO pack_pity (player_id, pack_id, rarity, missed) VALUES ($1, $2, $3, $4)
                ON CONFLICT (player_id, pack_id, rarity) DO UPDATE SET missed = EXCLUDED.missed
                """, ct, playerId, pack.PackId, rarity, missed);
        }

        var response = new PackOpenResponse(openingId.ToString("D"), pack.PackId, pack.Version, pack.PriceGems, cards, gemsAfter,
            dustAfter, drawSeed.ToString());
        await ExecAsync(connection, transaction,
            """
            INSERT INTO pack_openings (opening_id, player_id, pack_id, pack_version, catalog_version, draw_seed, pity_before, result, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            """, ct, openingId, playerId, pack.PackId, pack.Version, catalogVersion, drawSeed, Json(Serialize(missedBefore)),
            Json(Serialize(response)), now.ToUniversalTime());
        await RecordRequestAsync(connection, transaction, playerId, key, "pack", hash, response, now, ct);
        await EventAsync(connection, transaction, playerId, EventTypes.PackOpened, now,
            new PackOpenedPayload(response.OpeningId, playerId.ToString("D"), pack.PackId, pack.Version, pack.PriceGems, cards,
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
        DateTimeOffset now, CancellationToken ct)
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
            throw new InvalidOperationException($"No card rate for rarity '{card.Rarity}'.");
        }

        await ExecAsync(connection, transaction, "DELETE FROM card_holdings WHERE player_id = $1 AND card_id = $2", ct, playerId, cardId);
        var prefix = $"dust:{playerId:D}:{key:D}";
        await CardLedgerAsync(connection, transaction, playerId, cardId, -1, "dust", key.ToString("D"), prefix, now, ct);
        await WalletRowAsync(connection, transaction, playerId, ct);
        await LedgerAsync(connection, transaction, playerId, "dust", rate.DustValue, "dust", prefix, $"rate:{rate.Rarity}:{rate.Version}", now, ct);
        var (_, dust) = await MoveWalletAsync(connection, transaction, playerId, 0, rate.DustValue, now, ct);

        var response = new DustResponse(cardId, rate.DustValue, rate.Version, dust);
        await RecordRequestAsync(connection, transaction, playerId, key, "dust", hash, response, now, ct);
        await EventAsync(connection, transaction, playerId, EventTypes.CardDusted, now,
            new CardDustedPayload(playerId.ToString("D"), cardId, card.Rarity, rate.DustValue, rate.Version), ct);
        await transaction.CommitAsync(ct);
        return CardResult<DustResponse>.Ok(response);
    }

    // ---- craft (2.4) -----------------------------------------------------------------------------------------------

    public async Task<CardResult<CraftResponse>> CraftAsync(Guid playerId, string playerName, string cardId, Guid key,
        DateTimeOffset now, CancellationToken ct)
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
            throw new InvalidOperationException($"No card rate for rarity '{card.Rarity}'.");
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
        var (_, dustAfter) = await MoveWalletAsync(connection, transaction, playerId, 0, -rate.CraftCost, now, ct);

        var response = new CraftResponse(cardId, rate.CraftCost, rate.Version, dustAfter);
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
