using Npgsql;
using Rpg.Contracts.Cards;
using Rpg.Contracts.Events;
using static Rpg.Economy.Cards.CardSql;

namespace Rpg.Economy.Cards;

/// <summary>Thrown by the seeder when a catalog would take a core card away from every account (spec card-collection F18).</summary>
public sealed class CatalogDemotionException(string cardId, string reason)
    : InvalidOperationException($"Catalog refused: core card '{cardId}' {reason}.");

/// <summary>The pool a run is started with (spec card-collection 2.5).</summary>
public sealed record RunPool(IReadOnlyList<string> UnlockedCharacterIds, IReadOnlyList<string> CardPool);

/// <summary>
/// The card catalog and the account's cards (spec card-collection 2). The one module that reads and writes <c>cards</c>,
/// <c>card_holdings</c>, <c>card_ledger</c>, <c>pack_*</c>, <c>card_rates</c> and the dust side of the wallet. Every account
/// action is ONE transaction under the player's account lock with its ledger rows, its request row and its outbox event.
/// No game logic: the server never reads what a card does, only its id, rarity, set and pools.
/// </summary>
public sealed partial class CardStore(NpgsqlDataSource dataSource)
{
    // ---- catalog (2.1) ---------------------------------------------------------------------------------------------

    /// <summary>
    /// Seeds the catalog file. A new hash is a new catalog version; cards missing from the file are retired (still owned,
    /// out of packs and new pools). A core card that would stop being core, or vanish, refuses the whole file.
    /// </summary>
    public async Task<(int Version, bool Changed)> SeedCatalogAsync(CardCatalogFile file, DateTimeOffset now, CancellationToken ct)
    {
        ValidateCatalog(file);
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        await LockNamedAsync(connection, transaction, "card_catalog", ct);

        var version = 0;
        string? latestHash = null;
        await using (var latest = Cmd(connection, transaction,
                         "SELECT catalog_version, catalog_hash FROM catalog_versions ORDER BY catalog_version DESC LIMIT 1"))
        await using (var reader = await latest.ExecuteReaderAsync(ct))
        {
            if (await reader.ReadAsync(ct))
            {
                version = reader.GetInt32(0);
                latestHash = reader.GetString(1);
            }
        }

        if (latestHash == file.CatalogHash)
        {
            return (version, false);
        }

        var incoming = file.Cards.ToDictionary(c => c.Id);
        await using (var core = Cmd(connection, transaction, "SELECT card_id FROM cards WHERE core"))
        await using (var reader = await core.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                var id = reader.GetString(0);
                if (!incoming.TryGetValue(id, out var card))
                {
                    throw new CatalogDemotionException(id, "is missing from the file");
                }

                if (!card.Core)
                {
                    throw new CatalogDemotionException(id, "would stop being core");
                }
            }
        }

        version++;
        await ExecAsync(connection, transaction,
            "INSERT INTO catalog_versions (catalog_version, catalog_hash, document, created_at) VALUES ($1, $2, $3, $4)", ct,
            version, file.CatalogHash, Json(Serialize(file)), now.ToUniversalTime());
        foreach (var card in file.Cards)
        {
            await ExecAsync(connection, transaction,
                """
                INSERT INTO cards (card_id, kind, rarity, set_id, core, pools, retired, catalog_version)
                VALUES ($1, $2, $3, $4, $5, $6, false, $7)
                ON CONFLICT (card_id) DO UPDATE
                  SET kind = EXCLUDED.kind, rarity = EXCLUDED.rarity, set_id = EXCLUDED.set_id, core = EXCLUDED.core,
                      pools = EXCLUDED.pools, retired = false, catalog_version = EXCLUDED.catalog_version
                """, ct, card.Id, card.Kind, card.Rarity, card.SetId, card.Core, card.Pools.ToArray(), version);
        }

        await ExecAsync(connection, transaction,
            "UPDATE cards SET retired = true, catalog_version = $2 WHERE NOT (card_id = ANY($1)) AND NOT retired", ct,
            new NpgsqlParameter { Value = file.Cards.Select(c => c.Id).ToArray() }, version);
        await transaction.CommitAsync(ct);
        return (version, true);
    }

    private static void ValidateCatalog(CardCatalogFile file)
    {
        if (string.IsNullOrWhiteSpace(file.CatalogHash))
        {
            throw new ArgumentException("The catalog needs a catalogHash.");
        }

        if (file.Cards.Select(c => c.Id).Distinct().Count() != file.Cards.Count || file.Cards.Any(c => string.IsNullOrWhiteSpace(c.Id)))
        {
            throw new ArgumentException("Card ids must be non-empty and unique.");
        }

        foreach (var card in file.Cards)
        {
            if (card.Kind is not (CardKinds.Character or CardKinds.Item) || !CardRarities.Order.Contains(card.Rarity)
                || string.IsNullOrWhiteSpace(card.SetId))
            {
                throw new ArgumentException($"Card '{card.Id}' has an unknown kind or rarity, or no set.");
            }

            // Spec card-collection 3.1: characters are Mythic, a tier above Legendary, and items never are.
            if ((card.Kind == CardKinds.Character) != (card.Rarity == CardRarities.Mythic))
            {
                throw new ArgumentException($"Card '{card.Id}': characters are always Mythic and items never are.");
            }
        }
    }

    /// <summary>Fills rates and pack types that have no row yet: a restart never overwrites an admin's version.</summary>
    public async Task<(int Rates, int Packs, int Skipped)> SeedEconomyAsync(CardEconomySeed seed, int maxPrice, int maxCost, DateTimeOffset now,
        CancellationToken ct)
    {
        // "Only where no row exists" is decided inside each put's lock, so two instances starting together seed once.
        var rates = 0;
        var packs = 0;
        var skipped = 0;
        foreach (var rate in seed.Rates)
        {
            var result = await PutRateAsync(rate, Guid.Empty, "seed", now, maxCost, ct, onlyIfAbsent: true);
            if (result.Value is not null)
            {
                rates++;
            }
            else if (result.Problem is not null)
            {
                skipped++;
            }
        }

        foreach (var pack in seed.Packs)
        {
            var result = await PutPackTypeAsync(pack, Guid.Empty, "seed", now, maxPrice, ct, onlyIfAbsent: true);
            if (result.Value is not null)
            {
                packs++;
            }
            else if (result.Problem is not null)
            {
                skipped++;   // invalid, or its sets have no cards yet: the seeder logs it
            }
        }

        return (rates, packs, skipped);
    }

    // ---- reads (2.6) -----------------------------------------------------------------------------------------------

    public async Task<CatalogResponse> GetCatalogAsync(CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        var rates = await LatestRatesAsync(connection, null, ct);
        var version = 0;
        var hash = "";
        await using (var latest = new NpgsqlCommand(
            "SELECT catalog_version, catalog_hash FROM catalog_versions ORDER BY catalog_version DESC LIMIT 1", connection))
        await using (var reader = await latest.ExecuteReaderAsync(ct))
        {
            if (await reader.ReadAsync(ct))
            {
                version = reader.GetInt32(0);
                hash = reader.GetString(1);
            }
        }

        var cards = new List<CardDto>();
        await using (var select = new NpgsqlCommand(
            "SELECT card_id, kind, rarity, set_id, core, pools, retired FROM cards ORDER BY card_id COLLATE \"C\"", connection))
        await using (var reader = await select.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                var rarity = reader.GetString(2);
                rates.TryGetValue(rarity, out var rate);
                cards.Add(new CardDto(reader.GetString(0), reader.GetString(1), rarity, reader.GetString(3), reader.GetBoolean(4),
                    reader.GetFieldValue<string[]>(5), reader.GetBoolean(6), rate?.DustValue ?? 0, rate?.CraftCost ?? 0));
            }
        }

        return new CatalogResponse(version, hash, cards);
    }

    public async Task<PackListResponse> ListPacksAsync(CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        var packs = new List<PackTypeDto>();
        foreach (var pack in (await CardSql.LatestPacksAsync(connection, null, ct)).Where(p => !p.Retired).OrderBy(p => p.PackId, StringComparer.Ordinal))
        {
            var eligible = await EligibleAsync(connection, null, pack.SetIds, ct);
            packs.Add(new PackTypeDto(pack.PackId, pack.Name, pack.Version, pack.PriceGems, pack.CardCount, pack.Odds, pack.SetIds,
                [.. eligible.Values.SelectMany(v => v).Order(StringComparer.Ordinal)], pack.Pity, pack.FirstGuarantees, pack.MinRarity));
        }

        return new PackListResponse(packs);
    }

    public async Task<CollectionResponse> GetCollectionAsync(Guid playerId, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        var active = await ActiveRunAsync(connection, null, playerId, ct);
        var owned = new List<OwnedCardDto>();
        await using (var select = new NpgsqlCommand(
            "SELECT card_id, acquired_at, source FROM card_holdings WHERE player_id = $1 ORDER BY card_id COLLATE \"C\"", connection))
        {
            select.Parameters.Add(new NpgsqlParameter { Value = playerId });
            await using var reader = await select.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                var acquired = reader.GetFieldValue<DateTimeOffset>(1);
                owned.Add(new OwnedCardDto(reader.GetString(0), acquired, reader.GetString(2),
                    active is { } run && acquired <= run.StartedAt ? run.RunId.ToString("D") : null));
            }
        }

        int gems = 0, dust = 0;
        long version = 0;
        await using (var wallet = new NpgsqlCommand("SELECT gems, dust, version FROM wallets WHERE player_id = $1", connection))
        {
            wallet.Parameters.Add(new NpgsqlParameter { Value = playerId });
            await using var reader = await wallet.ExecuteReaderAsync(ct);
            if (await reader.ReadAsync(ct))
            {
                (gems, dust, version) = (reader.GetInt32(0), reader.GetInt32(1), reader.GetInt64(2));
            }
        }

        var pity = new List<PityStateDto>();
        foreach (var pack in (await CardSql.LatestPacksAsync(connection, null, ct)).Where(p => !p.Retired && p.Pity.Any(x => x.Value > 0))
                     .OrderBy(p => p.PackId, StringComparer.Ordinal))
        {
            pity.Add(new PityStateDto(pack.PackId, await MissedAsync(connection, null, playerId, pack, forUpdate: false, ct)));
        }

        return new CollectionResponse(owned, gems, dust, version, active?.RunId.ToString("D"), active?.Status, pity);
    }

    /// <summary>
    /// The player's pity counters for a pack type (spec 3.4a). A rarity with no row starts at its first-open value only when
    /// the player has never opened this pack type; otherwise at 0. (Review fix: "no pity rows" used to count as a first open,
    /// so when a pack type gained pity later, players who had opened it many times got the first-open head start.)
    /// </summary>
    private static async Task<Dictionary<string, int>> MissedAsync(NpgsqlConnection connection, NpgsqlTransaction? transaction,
        Guid playerId, PackType pack, bool forUpdate, CancellationToken ct)
    {
        var rows = new Dictionary<string, int>();
        await using (var select = new NpgsqlCommand(
            "SELECT rarity, missed FROM pack_pity WHERE player_id = $1 AND pack_id = $2" + (forUpdate ? " FOR UPDATE" : ""),
            connection, transaction))
        {
            select.Parameters.Add(new NpgsqlParameter { Value = playerId });
            select.Parameters.Add(new NpgsqlParameter { Value = pack.PackId });
            await using var reader = await select.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                rows[reader.GetString(0)] = reader.GetInt32(1);
            }
        }

        bool openedBefore;
        await using (var opened = new NpgsqlCommand(
            "SELECT EXISTS (SELECT 1 FROM pack_openings WHERE player_id = $1 AND pack_id = $2)", connection, transaction))
        {
            opened.Parameters.Add(new NpgsqlParameter { Value = playerId });
            opened.Parameters.Add(new NpgsqlParameter { Value = pack.PackId });
            openedBefore = await opened.ExecuteScalarAsync(ct) is true;
        }

        var initial = PackDrawer.InitialMissed(pack.Pity, pack.FirstGuarantees);
        var missed = new Dictionary<string, int>();
        foreach (var rarity in pack.Pity.Where(p => p.Value > 0).Select(p => p.Key))
        {
            missed[rarity] = rows.TryGetValue(rarity, out var value) ? value : openedBefore ? 0 : initial[rarity];
        }

        return missed;
    }

    // ---- request log (idempotency) ---------------------------------------------------------------------------------

    /// <summary>The stored answer of an earlier identical request, a 1407 for the same key with another action, or null.</summary>
    private static async Task<CardResult<T>?> ReplayAsync<T>(NpgsqlConnection connection, NpgsqlTransaction transaction,
        Guid playerId, Guid key, string kind, string hash, CancellationToken ct) where T : class
    {
        await using var select = Cmd(connection, transaction,
            "SELECT kind, request_hash, response::text FROM account_requests WHERE player_id = $1 AND request_key = $2", playerId, key);
        await using var reader = await select.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
        {
            return null;
        }

        return reader.GetString(0) == kind && reader.GetString(1) == hash
            ? CardResult<T>.Ok(Deserialize<T>(reader.GetString(2)), replayed: true)
            : CardResult<T>.Fail(CardFailure.RequestKeyReused, "This request key was used for a different action.");
    }

    private static Task RecordRequestAsync<T>(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid playerId, Guid key,
        string kind, string hash, T response, DateTimeOffset now, CancellationToken ct) =>
        ExecAsync(connection, transaction,
            "INSERT INTO account_requests (player_id, request_key, kind, request_hash, response, created_at) VALUES ($1, $2, $3, $4, $5, $6)",
            ct, playerId, key, kind, hash, Json(Serialize(response)), now.ToUniversalTime());

    private static Task WalletRowAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid playerId, CancellationToken ct) =>
        ExecAsync(connection, transaction, "INSERT INTO wallets (player_id) VALUES ($1) ON CONFLICT DO NOTHING", ct, playerId);

    private static async Task<(int Gems, int Dust)> LockWalletAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        Guid playerId, CancellationToken ct)
    {
        await WalletRowAsync(connection, transaction, playerId, ct);
        await using var select = Cmd(connection, transaction, "SELECT gems, dust FROM wallets WHERE player_id = $1 FOR UPDATE", playerId);
        await using var reader = await select.ExecuteReaderAsync(ct);
        await reader.ReadAsync(ct);
        return (reader.GetInt32(0), reader.GetInt32(1));
    }

    /// <summary>Adds to the wallet (negative = spend); the CHECK constraints are the last guard. Returns the new balances.</summary>
    private static async Task<(int Gems, int Dust)> MoveWalletAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        Guid playerId, int gems, int dust, DateTimeOffset now, CancellationToken ct)
    {
        await using var update = Cmd(connection, transaction,
            "UPDATE wallets SET gems = gems + $2, dust = dust + $3, version = version + 1, updated_at = $4 WHERE player_id = $1 RETURNING gems, dust",
            playerId, gems, dust, now.ToUniversalTime());
        await using var reader = await update.ExecuteReaderAsync(ct);
        await reader.ReadAsync(ct);
        return (reader.GetInt32(0), reader.GetInt32(1));
    }

    private static Task LedgerAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid playerId, string currency,
        int delta, string reason, string key, string ruleRef, DateTimeOffset now, CancellationToken ct) =>
        ExecAsync(connection, transaction,
            """
            INSERT INTO wallet_ledger (player_id, currency, delta, reason, idempotency_key, created_at, rule_ref, status, released_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, 'released', $6)
            """, ct, playerId, currency, delta, reason, key, now.ToUniversalTime(), ruleRef);

    private static Task CardLedgerAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid playerId, string cardId,
        int delta, string reason, string refId, string key, DateTimeOffset now, CancellationToken ct) =>
        ExecAsync(connection, transaction,
            "INSERT INTO card_ledger (player_id, card_id, delta, reason, ref_id, idempotency_key, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7)",
            ct, playerId, cardId, delta, reason, refId, key, now.ToUniversalTime());

    private static Task EventAsync<TPayload>(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid playerId, string type,
        DateTimeOffset now, TPayload payload, CancellationToken ct) =>
        EconomyEvents.WriteAsync(connection, transaction, playerId, null, "economy", type, EventTopics.Economy,
            playerId.ToString("D"), now, payload, ct);
}
