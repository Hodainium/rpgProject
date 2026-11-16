using System.Security.Cryptography;
using System.Text;
using Npgsql;
using Rpg.Contracts.Events;
using static Rpg.Economy.Cards.CardSql;

namespace Rpg.Economy.Cards;

/// <summary>One player's unopened packs of a type paid back (spec pack-shop 2.5).</summary>
public sealed record PackRefund(Guid PlayerId, string PackId, int PackVersion, int Count, int Gems);

/// <summary>A pack type the player could not be paid back for this time (tried again at the next login or collection read).</summary>
public sealed record PackRefundFailure(Guid PlayerId, string PackId, string Error);

/// <summary>
/// Packs left in the player's inventory with the refund held for a support check: no buy row prices them (a data problem), so
/// they are neither refunded for nothing nor taken away. Logins skip a held row until operations clears the hold.
/// </summary>
public sealed record PackRefundHeld(Guid PlayerId, string PackId, int Count);

/// <summary>One player's refund check: what was paid, what was held for a support check, and what failed.</summary>
public sealed record PackRefundPass(IReadOnlyList<PackRefund> Paid, IReadOnlyList<PackRefundHeld> Held,
    IReadOnlyList<PackRefundFailure> Failed);

public sealed partial class CardStore
{
    /// <summary>
    /// Spec pack-shop 2.5: pays this player back for every unopened pack of a type whose latest version is retired with a
    /// refund. Called at login and at the collection read, never on a timer: pack types change only during maintenance, so a
    /// player's next login after it settles their packs. One transaction per pack type under the account lock; the unique
    /// ledger keys stop a second payment, and one pack type that fails (it rolls back alone) never stops the others.
    /// </summary>
    public async Task<PackRefundPass> RefundPlayerPacksAsync(Guid playerId, DateTimeOffset now, CancellationToken ct)
    {
        var packs = new List<string>();
        await using (var connection = await dataSource.OpenConnectionAsync(ct))
        await using (var select = Cmd(connection, null,
            """
            SELECT i.pack_id FROM pack_inventory i
            CROSS JOIN LATERAL (SELECT retired, refund_unopened FROM pack_types t
                                WHERE t.pack_id = i.pack_id AND t.effective_from <= clock_timestamp()
                                ORDER BY t.version DESC LIMIT 1) latest
            WHERE i.player_id = $1 AND i.count > 0 AND NOT i.refund_held AND latest.retired AND latest.refund_unopened
            ORDER BY i.pack_id COLLATE "C"
            """, playerId))
        {
            await using var reader = await select.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                packs.Add(reader.GetString(0));
            }
        }

        var paid = new List<PackRefund>();
        var held = new List<PackRefundHeld>();
        var failed = new List<PackRefundFailure>();
        foreach (var pack in packs)
        {
            try
            {
                var (refund, unpriced) = await RefundOneAsync(playerId, pack, now, ct);
                if (refund is not null)
                {
                    paid.Add(refund);
                }

                if (unpriced > 0)
                {
                    held.Add(new PackRefundHeld(playerId, pack, unpriced));
                }
            }
            catch (Exception ex) when (ex is PostgresException or InvalidOperationException)
            {
                failed.Add(new PackRefundFailure(playerId, pack, ex.Message));
            }
        }

        return new PackRefundPass(paid, held, failed);
    }

    /// <summary>Pays back the packs a buy row prices; returns that payment (null when none) and the packs held for a support check.</summary>
    private async Task<(PackRefund? Paid, int Held)> RefundOneAsync(Guid playerId, string packId, DateTimeOffset now, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        await LockAccountAsync(connection, transaction, playerId, ct);
        // Pack types change only during maintenance; the shared lock on the type (the admin save holds it exclusively) makes
        // sure of it even if an admin saves a version while the server is up.
        await LockNamedSharedAsync(connection, transaction, $"pack_type|{packId}", ct);

        // Re-read under the locks: the packs may already be paid back (a second login at the same moment).
        var pack = await LatestPackAsync(connection, transaction, packId, ct);
        var count = await LockOwnedPacksAsync(connection, transaction, playerId, packId, ct);
        if (pack is not { Refunding: true } || count <= 0 || await RefundHeldAsync(connection, transaction, playerId, packId, ct))
        {
            return (null, 0);
        }

        // Units an earlier refund of this type already paid back (a refund that held some packs, then cleared; or a type
        // refunded, un-retired and refunded again). Refunds pay the newest buys first, so those units are skipped below.
        int alreadyRefunded;
        await using (var before = Cmd(connection, transaction,
            "SELECT COALESCE(-sum(delta), 0)::int FROM pack_ledger WHERE player_id = $1 AND pack_id = $2 AND reason = 'refund'",
            playerId, packId))
        {
            alreadyRefunded = (int)(await before.ExecuteScalarAsync(ct))!;
        }

        // What the player paid for the packs left. Opens spend the oldest packs first, so the `count` left are the newest
        // bought: walk the buys newest first, skip what was refunded before, each unit at the price of the version it was bought at.
        long amount = 0;
        var left = count;
        var skip = alreadyRefunded;
        await using (var buys = Cmd(connection, transaction,
            """
            SELECT l.delta, t.price_gems FROM pack_ledger l
            JOIN pack_types t ON t.pack_id = l.pack_id AND t.version = l.pack_version
            WHERE l.player_id = $1 AND l.pack_id = $2 AND l.reason = 'buy' ORDER BY l.id DESC
            """, playerId, packId))
        await using (var reader = await buys.ExecuteReaderAsync(ct))
        {
            while (left > 0 && await reader.ReadAsync(ct))
            {
                var row = reader.GetInt32(0);
                var skipped = Math.Min(skip, row);
                skip -= skipped;
                var units = Math.Min(left, row - skipped);
                amount += (long)units * reader.GetInt32(1);
                left -= units;
            }
        }

        if (amount > int.MaxValue)
        {
            throw new InvalidOperationException($"The refund of {count} '{packId}' packs for {playerId:D} is {amount} gems: too large for one ledger row.");
        }

        // Only a buy adds packs, so units no buy row prices are a data problem. Pay what is provable and hold the rest in the
        // inventory for a support check: never refund them for nothing, never take them away.
        var refunded = count - left;
        if (left > 0)
        {
            await ExecAsync(connection, transaction,
                "UPDATE pack_inventory SET refund_held = true WHERE player_id = $1 AND pack_id = $2", ct, playerId, packId);
        }

        if (refunded == 0)
        {
            await transaction.CommitAsync(ct);
            return (null, left);
        }

        var key = RefundKey(playerId, packId, pack.Version, alreadyRefunded);
        await MovePacksAsync(connection, transaction, playerId, packId, -refunded, ct);
        await PackLedgerAsync(connection, transaction, playerId, packId, pack.Version, -refunded, "refund", key, null, ct);
        if (amount > 0)
        {
            await WalletRowAsync(connection, transaction, playerId, ct);
            await LedgerAsync(connection, transaction, playerId, "gems", (int)amount, "pack_refund",
                $"pack_refund:{playerId:D}:{packId}:{pack.Version}:{alreadyRefunded}", $"pack:{packId}:{pack.Version}", now, ct);
            await MoveWalletAsync(connection, transaction, playerId, (int)amount, 0, now, ct);
        }

        await EventAsync(connection, transaction, playerId, EventTypes.PackRefunded, now,
            new PackRefundedPayload(playerId.ToString("D"), packId, pack.Version, refunded, (int)amount), ct);
        await transaction.CommitAsync(ct);
        return (new PackRefund(playerId, packId, pack.Version, refunded, (int)amount), left);
    }

    /// <summary>Whether the player's packs of this type are held for a support check (spec pack-shop 2.5).</summary>
    internal static async Task<bool> RefundHeldAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid playerId,
        string packId, CancellationToken ct)
    {
        await using var select = Cmd(connection, transaction,
            "SELECT refund_held FROM pack_inventory WHERE player_id = $1 AND pack_id = $2", playerId, packId);
        return await select.ExecuteScalarAsync(ct) is true;
    }

    /// <summary>
    /// The refund's request key on <c>pack_ledger</c>: a UUID derived from (player, pack, retirement version, units refunded
    /// before), so the unique (player_id, reason, request_key) index makes the same refund twice impossible, while a later one
    /// (after a held refund is cleared) gets a key of its own.
    /// </summary>
    public static Guid RefundKey(Guid playerId, string packId, int version, int refundedBefore)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes($"pack_refund:{playerId:D}:{packId}:{version}:{refundedBefore}"))[..16];
        bytes[7] = (byte)((bytes[7] & 0x0F) | 0x50);   // version 5-style (name-based) in the .NET byte order
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);   // RFC 4122 variant
        return new Guid(bytes);
    }
}
