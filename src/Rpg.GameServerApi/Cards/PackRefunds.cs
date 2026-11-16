using Rpg.Economy.Cards;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.Runs;
using Rpg.Verification;

namespace Rpg.GameServerApi.Cards;

/// <summary>
/// Spec pack-shop 2.5: pays a player back for unopened packs of a type retired with a refund, when the player opens the Open
/// packs page (POST /packs/refunds), the one place they look for their packs, so the page can say where they went. There is no
/// timer: pack types change only while the server is down for maintenance. Idempotent: the store pays under the account lock
/// with unique ledger keys, so two calls at once pay once.
/// </summary>
public sealed class PackRefunds(CardStore store, MigrationRunner migrations, RunSummaryCache cache, RpgMetrics metrics,
    TimeProvider clock, ILogger<PackRefunds> logger)
{
    /// <summary>Refunds what is due and returns what was paid back.</summary>
    public async Task<IReadOnlyList<PackRefund>> RefundAsync(Guid playerId, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        var pass = await store.RefundPlayerPacksAsync(playerId, clock.GetUtcNow(), ct);
        foreach (var failure in pass.Failed)
        {
            metrics.PackRefundFailed(failure.PackId, "error");
            logger.LogWarning("Refund of '{Pack}' packs to {Player} failed, tried again on the next Open packs visit: {Error}", failure.PackId,
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

        return pass.Paid;
    }
}
