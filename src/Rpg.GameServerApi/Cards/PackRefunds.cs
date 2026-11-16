using Rpg.Economy.Cards;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.Runs;
using Rpg.Verification;

namespace Rpg.GameServerApi.Cards;

/// <summary>
/// Spec pack-shop 2.5: pays a player back for unopened packs of a type retired with a refund, at login and at the collection
/// read (both fail with 503 when Postgres is down: the game does not work without it). There is no timer: pack types change
/// only while the server is down for maintenance, so the next time a player signs in (or a client with a token that outlived the
/// restart reads its collection) settles their packs. Idempotent: the store pays
/// under the account lock with unique ledger keys, so two logins at once pay once.
/// </summary>
public sealed class PackRefunds(CardStore store, MigrationRunner migrations, RunSummaryCache cache, RpgMetrics metrics,
    TimeProvider clock, ILogger<PackRefunds> logger)
{
    /// <summary>Refunds what is due and returns how many pack types were paid back.</summary>
    public async Task<int> RefundAsync(Guid playerId, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        var pass = await store.RefundPlayerPacksAsync(playerId, clock.GetUtcNow(), ct);
        foreach (var failure in pass.Failed)
        {
            metrics.PackRefundFailed(failure.PackId, "error");
            logger.LogWarning("Refund of '{Pack}' packs to {Player} failed, tried again at the next login: {Error}", failure.PackId,
                failure.PlayerId, failure.Error);
        }

        foreach (var held in pass.Held)
        {
            metrics.PackRefundFailed(held.PackId, "held");
            logger.LogError("Refund of {Count} '{Pack}' pack(s) to {Player} held for a support check: no buy row prices them " +
                "(look at pack_ledger; clear pack_inventory.refund_held once settled)", held.Count, held.PackId, held.PlayerId);
        }

        foreach (var refund in pass.Paid)
        {
            metrics.PacksRefunded(refund.PackId, refund.Count, refund.Gems);
            logger.LogInformation("Refunded {Count} '{Pack}' pack(s) to {Player}: {Gems} gems", refund.Count, refund.PackId,
                refund.PlayerId, refund.Gems);
        }

        if (pass.Paid.Count > 0)
        {
            await cache.InvalidateAsync(VerifyPolicy.WalletKey(playerId));
        }

        return pass.Paid.Count;
    }
}
