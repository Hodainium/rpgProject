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
    /// <summary>
    /// Refunds what is due and returns the pass: what was paid back (no account version: spec account-session 2.3), or the
    /// refusal when <paramref name="session"/> is not the player's current account session.
    /// </summary>
    public async Task<PackRefundPass> RefundAsync(Guid playerId, long session, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        var pass = await store.RefundPlayerPacksAsync(playerId, session, clock.GetUtcNow(), ct);
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
                "(look at pack_ledger; set pack_inventory.refund_held_version back to NULL once settled)", held.Count, held.PackId, held.PlayerId);
        }

        foreach (var refund in pass.Paid)
        {
            metrics.PacksRefunded(refund.PackId, refund.Count, refund.Gems);
            logger.LogInformation("Refunded {Count} '{Pack}' pack(s) to {Player}: {Gems} gems", refund.Count, refund.PackId,
                refund.PlayerId, refund.Gems);
        }

        if (pass.Paid.Count > 0 || pass.Held.Count > 0)   // a hold raises the account version too (spec account-session 2.4)
        {
            await cache.InvalidateAsync(VerifyPolicy.WalletKey(playerId));
        }

        return pass;
    }
}
