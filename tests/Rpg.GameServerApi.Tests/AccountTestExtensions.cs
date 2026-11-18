using System.Runtime.CompilerServices;
using Rpg.Client;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Cards;
using Rpg.Contracts.Runs;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Spec account-session: every account-changing call now carries the account session and (for decisions) the version the screen
/// showed. The tests written before that slice test other things (the draw, pity, refunds, the run lock...), so these helpers
/// keep their old signatures: each call sends the client's session (started on first use) and the account's current version,
/// read just before. A 1412 or 1413 the helper caused itself (another client of the same player started a session, a reward
/// landed between the read and the call) is answered as a real client would: a new session or a fresh read, and the same key
/// again (a refusal stores nothing under it). The fence itself is tested with explicit requests in AccountSessionTests.
/// </summary>
public static class AccountTestExtensions
{
    private sealed class SessionBox
    {
        public readonly SemaphoreSlim Gate = new(1, 1);
        public long Session;
    }

    private static readonly ConditionalWeakTable<GameServerClient, SessionBox> Sessions = new();

    /// <summary>
    /// The client's account session, started on first use, or again when <paramref name="replaced"/> is the session a 1412
    /// refused (calls running at once start one session between them).
    /// </summary>
    public static async Task<long> SessionAsync(this GameServerClient client, CancellationToken ct, long replaced = 0)
    {
        var box = Sessions.GetValue(client, _ => new SessionBox());
        await box.Gate.WaitAsync(ct);
        try
        {
            if (box.Session == 0 || box.Session == replaced)
            {
                box.Session = (await client.StartAccountSessionAsync(ct)).Session;
            }

            return box.Session;
        }
        finally
        {
            box.Gate.Release();
        }
    }

    public static Task<PackOpenResponse> OpenPackAsync(this GameServerClient client, string packId, Guid key, CancellationToken ct) =>
        FencedAsync(client, ct, (session, version) => client.OpenPackAsync(packId, new AccountActionRequest(key, session, version), ct));

    public static Task<PackBuyResponse> BuyPackAsync(this GameServerClient client, string packId, Guid key, int count, CancellationToken ct) =>
        FencedAsync(client, ct, (session, version) => client.BuyPackAsync(packId, new PackBuyRequest(key, count, session, version), ct));

    public static Task<DustResponse> DustCardAsync(this GameServerClient client, string cardId, Guid key, CancellationToken ct) =>
        FencedAsync(client, ct, (session, version) => client.DustCardAsync(cardId, new AccountActionRequest(key, session, version), ct));

    public static Task<CraftResponse> CraftCardAsync(this GameServerClient client, string cardId, Guid key, CancellationToken ct) =>
        FencedAsync(client, ct, (session, version) => client.CraftCardAsync(cardId, new AccountActionRequest(key, session, version), ct));

    public static Task<PackRefundsResponse> RefundPacksAsync(this GameServerClient client, CancellationToken ct) =>
        FencedAsync(client, ct, (session, _) => client.RefundPacksAsync(new PackRefundsRequest(session), ct), versioned: false);

    /// <summary>POST /runs with the client's session (spec account-session: the run start is fenced, it abandons the active run).</summary>
    public static Task<RunStartResponse> StartFencedRunAsync(this GameServerClient client, RunStartRequest request, CancellationToken ct) =>
        FencedAsync(client, ct, (session, _) => client.StartRunAsync(request with { Session = session }, ct), versioned: false);

    public static Task AbandonRunAsync(this GameServerClient client, string runId, CancellationToken ct) =>
        FencedAsync<object?>(client, ct, async (session, _) =>
        {
            await client.AbandonRunAsync(runId, new RunAbandonRequest(session), ct);
            return null;
        }, versioned: false);

    private static async Task<T> FencedAsync<T>(GameServerClient client, CancellationToken ct, Func<long, long, Task<T>> call,
        bool versioned = true)
    {
        long replaced = 0;
        for (var attempt = 0; ; attempt++)
        {
            var session = await client.SessionAsync(ct, replaced);
            var version = versioned ? (await client.GetCollectionAsync(ct)).AccountVersion : 0;
            try
            {
                return await call(session, version);
            }
            catch (GameServerApiException ex) when (attempt < 50
                && ex.ErrorCode is ApiErrors.AccountSessionReplaced or ApiErrors.AccountVersionStale)
            {
                // The helper's own staleness (calls running at once move the version under each other; another client of the
                // player logged in): read again and send the same request again, as a client does after refetching.
                replaced = ex.ErrorCode == ApiErrors.AccountSessionReplaced ? session : 0;
            }
        }
    }
}
