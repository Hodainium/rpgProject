using System.Security.Cryptography;
using System.Text;
using Npgsql;
using Rpg.Contracts.Events;
using static Rpg.Economy.Cards.CardSql;

namespace Rpg.Economy.Cards;

/// <summary>One player's unopened packs of a type paid back (spec pack-shop 2.5).</summary>
public sealed record PackRefund(Guid PlayerId, string PackId, int PackVersion, int Count, int Gems);

/// <summary>A pack type the player could not be paid back for this time (tried again on the next Open packs visit).</summary>
public sealed record PackRefundFailure(Guid PlayerId, string PackId, string Error);

/// <summary>
/// Packs left in the player's inventory with the refund held for a support check: no buy row prices them (a data problem), so
/// they are neither refunded for nothing nor taken away. Later refund calls skip a held row until operations clears the hold.
/// </summary>
public sealed record PackRefundHeld(Guid PlayerId, string PackId, int Count);

/// <summary>
/// One player's refund check: what was paid, what was held for a support check, and what failed. Spec account-session: Problem is
/// set when the call's session is not the current one and nothing was paid yet (once a refund has committed, a newer login only
/// stops the rest: the pass says what was paid).
/// </summary>
public sealed record PackRefundPass(IReadOnlyList<PackRefund> Paid, IReadOnlyList<PackRefundHeld> Held,
    IReadOnlyList<PackRefundFailure> Failed, CardProblem? Problem = null);

public sealed partial class CardStore
{
    /// <summary>
    /// Spec pack-shop 2.5: pays this player back for every unopened pack of a type whose latest version is retired with a
    /// refund. Called when the player opens the Open packs page, never on a timer: pack types change only during maintenance. One transaction per pack type under the account lock; the unique
    /// ledger keys stop a second payment, and one pack type that fails (it rolls back alone) never stops the others.
    /// </summary>
    public async Task<PackRefundPass> RefundPlayerPacksAsync(Guid playerId, long session, DateTimeOffset now, CancellationToken ct)
    {
        // Spec account-session 2.2: fenced (session only, a refund is not the player's decision). A plain read up front refuses
        // an old session with nothing due too, without queueing on the account lock; each pack type's own transaction fences
        // again under the lock, so a newer login between them stops the rest.
        var fence = new AccountFence(session, null);
        var packs = new List<string>();
        await using (var connection = await dataSource.OpenConnectionAsync(ct))
        await using (var transaction = await connection.BeginTransactionAsync(ct))
        {
            if (await FenceAsync(connection, transaction, playerId, fence, ct) is { } fenced)
            {
                return new PackRefundPass([], [], [], fenced);
            }

            await using (var select = Cmd(connection, transaction,
                """
                SELECT i.pack_id FROM pack_inventory i
                CROSS JOIN LATERAL (SELECT version, retired, refund_unopened FROM pack_types t
                                    WHERE t.pack_id = i.pack_id AND t.effective_from <= clock_timestamp()
                                    ORDER BY t.version DESC LIMIT 1) latest
                WHERE i.player_id = $1 AND i.count > 0 AND i.refund_held_version IS DISTINCT FROM latest.version
                  AND latest.retired AND latest.refund_unopened
                ORDER BY i.pack_id COLLATE "C"
                """, playerId))
            {
                await using var reader = await select.ExecuteReaderAsync(ct);
                while (await reader.ReadAsync(ct))
                {
                    packs.Add(reader.GetString(0));
                }
            }

            await transaction.CommitAsync(ct);
        }

        var paid = new List<PackRefund>();
        var held = new List<PackRefundHeld>();
        var failed = new List<PackRefundFailure>();
        foreach (var pack in packs)
        {
            try
            {
                var (refund, unpriced, problem) = await RefundOneAsync(playerId, pack, fence, now, ct);
                if (problem is not null)
                {
                    // A newer login stops the rest. What already committed is still told (review fix): refunds are idempotent,
                    // so a later call would find nothing due and the player would never hear where those packs went.
                    return paid.Count > 0 ? new PackRefundPass(paid, held, failed) : new PackRefundPass(paid, held, failed, problem);
                }

                if (refund is not null)
                {
                    paid.Add(refund);
                }

                if (unpriced > 0)
                {
                    held.Add(new PackRefundHeld(playerId, pack, unpriced));
                }
            }
            catch (Exception ex) when (ex is NpgsqlException or InvalidOperationException)
            {
                failed.Add(new PackRefundFailure(playerId, pack, ex.Message));
            }
        }

        return new PackRefundPass(paid, held, failed);
    }

    /// <summary>
    /// Pays back the packs a buy row prices; returns that payment (null when none), the packs held for a support check, and the
    /// fence's refusal.
    /// </summary>
    private async Task<(PackRefund? Paid, int Held, CardProblem? Problem)> RefundOneAsync(Guid playerId, string packId,
        AccountFence fence, DateTimeOffset now, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        await LockAccountAsync(connection, transaction, playerId, ct);
        if (await FenceAsync(connection, transaction, playerId, fence, ct) is { } fenced)
        {
            return (null, 0, fenced);
        }

        // Pack types change only during maintenance; the shared lock on the type (the admin save holds it exclusively) makes
        // sure of it even if an admin saves a version while the server is up.
        await LockNamedSharedAsync(connection, transaction, $"pack_type|{packId}", ct);

        // Re-read under the locks: the packs may already be paid back (a second visit of the Open packs page at the same moment).
        var pack = await LatestPackAsync(connection, transaction, packId, ct);
        var count = await LockOwnedPacksAsync(connection, transaction, playerId, packId, ct);
        if (pack is not { Refunding: true } || count <= 0 || await RefundHeldAsync(connection, transaction, playerId, packId, pack.Version, ct))
        {
            return (null, 0, null);
        }

        // What the player paid for the packs left, by replaying the pack ledger in order (review fix: a type refunded,
        // un-retired, bought again and refunded again must price the packs bought after the first refund). Buys join the back
        // of a queue at the price of the version bought, an open takes the oldest pack, a refund takes the packs it paid for
        // (the newest); what is left is what the player owns, each with its price.
        var queue = new LinkedList<(int Price, int Units)>();   // front = oldest; Price -1 = no pack type row prices it
        var refundedBefore = 0;
        await using (var rows = Cmd(connection, transaction,
            """
            SELECT l.reason, l.delta, t.price_gems FROM pack_ledger l
            LEFT JOIN pack_types t ON t.pack_id = l.pack_id AND t.version = l.pack_version
            WHERE l.player_id = $1 AND l.pack_id = $2 ORDER BY l.id
            """, playerId, packId))
        await using (var reader = await rows.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                var delta = reader.GetInt32(1);
                switch (reader.GetString(0))
                {
                    case "buy":
                        queue.AddLast((reader.IsDBNull(2) ? -1 : reader.GetInt32(2), delta));
                        break;
                    case "open":
                        Take(queue, -delta, fromFront: true);
                        break;
                    case "refund":
                        refundedBefore -= delta;
                        Take(queue, -delta, fromFront: false);
                        break;
                }
            }
        }

        // The `count` owned are the newest in the queue. Units with no price (more packs owned than the buys prove, or a buy of
        // a version with no row) are a data problem: they are held, never refunded for nothing, never taken away.
        long amount = 0;
        var refunded = 0;
        var left = count;
        for (var node = queue.Last; node is not null && left > 0; node = node.Previous)
        {
            var units = Math.Min(left, node.Value.Units);
            left -= units;
            if (node.Value.Price >= 0)
            {
                amount += (long)units * node.Value.Price;
                refunded += units;
            }
        }

        var held = count - refunded;
        if (amount > int.MaxValue)
        {
            throw new InvalidOperationException($"The refund of {count} '{packId}' packs for {playerId:D} is {amount} gems: too large for one ledger row.");
        }

        // Pay what is provable and hold the rest for a support check of this retirement (a later retirement checks again).
        if (held > 0)
        {
            await ExecAsync(connection, transaction,
                "UPDATE pack_inventory SET refund_held_version = $3 WHERE player_id = $1 AND pack_id = $2", ct, playerId, packId, pack.Version);
        }

        if (refunded == 0)
        {
            // Spec account-session 2.4: a hold changes the owned packs the collection shows, so it raises the account version
            // (once per transaction: a payout below raises it for both).
            await RaiseVersionAsync(connection, transaction, playerId, now, ct);
            await transaction.CommitAsync(ct);
            return (null, held, null);
        }

        var key = RefundKey(playerId, packId, pack.Version, refundedBefore);
        await MovePacksAsync(connection, transaction, playerId, packId, -refunded, ct);
        await PackLedgerAsync(connection, transaction, playerId, packId, pack.Version, -refunded, "refund", key, null, ct);
        if (amount > 0)
        {
            await WalletRowAsync(connection, transaction, playerId, ct);
            await LedgerAsync(connection, transaction, playerId, "gems", (int)amount, "pack_refund",
                $"pack_refund:{playerId:D}:{packId}:{pack.Version}:{refundedBefore}", $"pack:{packId}:{pack.Version}", now, ct);
            await MoveWalletAsync(connection, transaction, playerId, (int)amount, 0, now, ct);
        }
        else
        {
            await RaiseVersionAsync(connection, transaction, playerId, now, ct);   // free packs taken back still change the account
        }

        await EventAsync(connection, transaction, playerId, EventTypes.PackRefunded, now,
            new PackRefundedPayload(playerId.ToString("D"), packId, pack.Version, refunded, (int)amount), ct);
        await transaction.CommitAsync(ct);
        return (new PackRefund(playerId, packId, pack.Version, refunded, (int)amount), held, null);
    }

    /// <summary>Takes `units` from the queue's front (an open) or back (a refund); a damaged ledger may ask for more than is there.</summary>
    private static void Take(LinkedList<(int Price, int Units)> queue, int units, bool fromFront)
    {
        while (units > 0 && (fromFront ? queue.First : queue.Last) is { } node)
        {
            var taken = Math.Min(units, node.Value.Units);
            units -= taken;
            if (taken == node.Value.Units)
            {
                queue.Remove(node);
            }
            else
            {
                node.Value = (node.Value.Price, node.Value.Units - taken);
            }
        }
    }

    /// <summary>
    /// Whether the player's packs of this type are held for a support check of this retirement version (spec pack-shop 2.5).
    /// The hold belongs to one retirement: an un-retired type, or a later retirement, is not held.
    /// </summary>
    internal static async Task<bool> RefundHeldAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid playerId,
        string packId, int version, CancellationToken ct)
    {
        await using var select = Cmd(connection, transaction,
            "SELECT refund_held_version FROM pack_inventory WHERE player_id = $1 AND pack_id = $2", playerId, packId);
        return await select.ExecuteScalarAsync(ct) is int held && held == version;
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
