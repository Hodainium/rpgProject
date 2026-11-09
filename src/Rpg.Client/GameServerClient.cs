using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Auth;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Cards;
using Rpg.Contracts.Economy;
using Rpg.Contracts.Presence;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;

namespace Rpg.Client;

/// <summary>
/// Typed client for Rpg.GameServerApi. The caller owns the <see cref="HttpClient"/> and sets its
/// <see cref="HttpClient.BaseAddress"/> (with a trailing slash); routes here are relative.
/// <paramref name="accessToken"/>: the bearer token sent on every request (spec server-authority 3.2), also settable
/// later through <see cref="AccessToken"/> (e.g. after <see cref="GetDevTokenAsync"/>).
/// </summary>
public sealed class GameServerClient(HttpClient http, string? accessToken = null)
{
    /// <summary>Sent as <c>Authorization: Bearer …</c> when set.</summary>
    public string? AccessToken { get; set; } = accessToken;

    /// <summary>POST /api/v1/auth/dev-token (Development only): a token for a player name. Does not set
    /// <see cref="AccessToken"/>.</summary>
    public Task<DevTokenResponse> GetDevTokenAsync(DevTokenRequest request, CancellationToken ct = default) =>
        RequiredAsync<DevTokenResponse>(HttpMethod.Post, "api/v1/auth/dev-token",
            JsonContent.Create(request, options: RpgJson.Options), ct);

    public Task<ServerInfoResponse> GetInfoAsync(CancellationToken ct = default) =>
        RequiredAsync<ServerInfoResponse>(HttpMethod.Get, "api/v1/info", null, ct);

    /// <summary>POST /api/v1/runs: starts a run (abandoning the active one) and returns floor 0's seed.</summary>
    public Task<RunStartResponse> StartRunAsync(RunStartRequest request, CancellationToken ct = default) =>
        RequiredAsync<RunStartResponse>(HttpMethod.Post, "api/v1/runs", JsonContent.Create(request, options: RpgJson.Options), ct);

    /// <summary>POST /api/v1/runs/{runId}/floors/{floor}: the stairs. Retrying the same floor returns the same seed.</summary>
    public Task<FloorSeedResponse> GetFloorSeedAsync(string runId, int floor, FloorSeedRequest? request = null,
        CancellationToken ct = default) =>
        RequiredAsync<FloorSeedResponse>(HttpMethod.Post, $"api/v1/runs/{Uri.EscapeDataString(runId)}/floors/{floor}",
            JsonContent.Create(request ?? new FloorSeedRequest(), options: RpgJson.Options), ct);

    /// <summary>GET /api/v1/runs/{runId}.</summary>
    public Task<RunSummaryResponse> GetRunAsync(string runId, CancellationToken ct = default) =>
        RequiredAsync<RunSummaryResponse>(HttpMethod.Get, $"api/v1/runs/{Uri.EscapeDataString(runId)}", null, ct);

    /// <summary>GET /api/v1/runs/current: the player's Active or Verifying run, or null (204) when there is none.</summary>
    public Task<RunSummaryResponse?> GetCurrentRunAsync(CancellationToken ct = default) =>
        SendAsync<RunSummaryResponse>(HttpMethod.Get, "api/v1/runs/current", null, ct, allowNoContent: true);

    /// <summary>POST /api/v1/runs/{runId}/actions: uploads 1–50 consecutive actions; a retried batch is a no-op.</summary>
    public Task<RunActionAck> SendActionsAsync(string runId, RunActionBatch batch, CancellationToken ct = default) =>
        RequiredAsync<RunActionAck>(HttpMethod.Post, $"api/v1/runs/{Uri.EscapeDataString(runId)}/actions",
            JsonContent.Create(batch, options: RpgJson.Options), ct);

    /// <summary>POST /api/v1/runs/{runId}/end: 202 Verifying for a win, 200 once the status is final.</summary>
    public Task<RunEndResponse> EndRunAsync(string runId, RunEndRequest request, CancellationToken ct = default) =>
        RequiredAsync<RunEndResponse>(HttpMethod.Post, $"api/v1/runs/{Uri.EscapeDataString(runId)}/end",
            JsonContent.Create(request, options: RpgJson.Options), ct);

    /// <summary>GET /api/v1/runs/{runId}/resume: floor seeds, the latest checkpoint and the actions after it.</summary>
    public Task<RunResumeResponse> ResumeAsync(string runId, CancellationToken ct = default) =>
        RequiredAsync<RunResumeResponse>(HttpMethod.Get, $"api/v1/runs/{Uri.EscapeDataString(runId)}/resume", null, ct);

    /// <summary>GET /api/v1/runs/{runId}/battles/{seq}: the battle uploaded with that action.</summary>
    public Task<BattleSessionResponse> GetBattleAsync(string runId, int seq, CancellationToken ct = default) =>
        RequiredAsync<BattleSessionResponse>(HttpMethod.Get,
            $"api/v1/runs/{Uri.EscapeDataString(runId)}/battles/{seq}", null, ct);

    /// <summary>GET /api/v1/runs/{runId}/steps (Development only, spec run-verify 3.7): the run's verification steps.</summary>
    public Task<List<RunStepDto>> GetStepsAsync(string runId, CancellationToken ct = default) =>
        RequiredAsync<List<RunStepDto>>(HttpMethod.Get, $"api/v1/runs/{Uri.EscapeDataString(runId)}/steps", null, ct);

    /// <summary>GET /api/v1/runs/{runId}/floors/{floor} (spec run-verify 2.7): the verified read model of a floor.</summary>
    public Task<FloorDigestResponse> GetFloorDigestAsync(string runId, int floor, CancellationToken ct = default) =>
        RequiredAsync<FloorDigestResponse>(HttpMethod.Get,
            $"api/v1/runs/{Uri.EscapeDataString(runId)}/floors/{floor}", null, ct);

    /// <summary>GET /api/v1/wallet (spec settlement-outbox 2.4): the player's gems and recent ledger rows.</summary>
    public Task<WalletResponse> GetWalletAsync(CancellationToken ct = default) =>
        RequiredAsync<WalletResponse>(HttpMethod.Get, "api/v1/wallet", null, ct);

    /// <summary>PUT /api/v1/admin/reward-rules (economy-admin, spec economy-rewards 3.6): a new version of one rule.</summary>
    public Task<RewardRuleResponse> PutRewardRuleAsync(RewardRuleRequest request, CancellationToken ct = default) =>
        RequiredAsync<RewardRuleResponse>(HttpMethod.Put, "api/v1/admin/reward-rules",
            JsonContent.Create(request, options: RpgJson.Options), ct);

    /// <summary>GET /api/v1/admin/reward-rules (economy-admin): the latest version per source.</summary>
    public Task<RewardRuleListResponse> ListRewardRulesAsync(CancellationToken ct = default) =>
        RequiredAsync<RewardRuleListResponse>(HttpMethod.Get, "api/v1/admin/reward-rules", null, ct);

    /// <summary>POST /api/v1/admin/reward-cycles/reset (economy-admin, spec economy-challenges 3.6): the next clear pays the ladder again.</summary>
    public Task<RewardCycleResetResponse> ResetRewardCycleAsync(RewardCycleResetRequest request, CancellationToken ct = default) =>
        RequiredAsync<RewardCycleResetResponse>(HttpMethod.Post, "api/v1/admin/reward-cycles/reset",
            JsonContent.Create(request, options: RpgJson.Options), ct);

    // ---- Cards (spec card-collection) ----------------------------------------------------------------------------

    /// <summary>GET /api/v1/cards/catalog: every card with the rates in force.</summary>
    public Task<CatalogResponse> GetCardCatalogAsync(CancellationToken ct = default) =>
        RequiredAsync<CatalogResponse>(HttpMethod.Get, "api/v1/cards/catalog", null, ct);

    /// <summary>GET /api/v1/packs: the packs on sale with their odds, pity rules and card lists.</summary>
    public Task<PackListResponse> GetPacksAsync(CancellationToken ct = default) =>
        RequiredAsync<PackListResponse>(HttpMethod.Get, "api/v1/packs", null, ct);

    /// <summary>GET /api/v1/cards/collection: the account's cards (core cards implied), gems, dust and pity counters.</summary>
    public Task<CollectionResponse> GetCollectionAsync(CancellationToken ct = default) =>
        RequiredAsync<CollectionResponse>(HttpMethod.Get, "api/v1/cards/collection", null, ct);

    /// <summary>POST /api/v1/packs/{packId}/open: spends gems. Retrying with the same key returns the same cards.</summary>
    public Task<PackOpenResponse> OpenPackAsync(string packId, Guid requestKey, CancellationToken ct = default) =>
        RequiredAsync<PackOpenResponse>(HttpMethod.Post, $"api/v1/packs/{Uri.EscapeDataString(packId)}/open",
            JsonContent.Create(new AccountActionRequest(requestKey), options: RpgJson.Options), ct);

    /// <summary>POST /api/v1/cards/{cardId}/dust: removes the card for dust (409 1403 while the active run holds it).</summary>
    public Task<DustResponse> DustCardAsync(string cardId, Guid requestKey, CancellationToken ct = default) =>
        RequiredAsync<DustResponse>(HttpMethod.Post, $"api/v1/cards/{Uri.EscapeDataString(cardId)}/dust",
            JsonContent.Create(new AccountActionRequest(requestKey), options: RpgJson.Options), ct);

    /// <summary>POST /api/v1/cards/{cardId}/craft: spends dust on a card the account does not own.</summary>
    public Task<CraftResponse> CraftCardAsync(string cardId, Guid requestKey, CancellationToken ct = default) =>
        RequiredAsync<CraftResponse>(HttpMethod.Post, $"api/v1/cards/{Uri.EscapeDataString(cardId)}/craft",
            JsonContent.Create(new AccountActionRequest(requestKey), options: RpgJson.Options), ct);

    /// <summary>POST /api/v1/runs/{runId}/abandon: cancels the Active run (204); 409 1410 while it is being verified.</summary>
    public Task AbandonRunAsync(string runId, CancellationToken ct = default) =>
        SendAsync<object>(HttpMethod.Post, $"api/v1/runs/{Uri.EscapeDataString(runId)}/abandon", null, ct, allowNoContent: true);

    /// <summary>PUT /api/v1/admin/pack-types (economy-admin): a new version of one pack type.</summary>
    public Task<PackTypeResponse> PutPackTypeAsync(PackTypeRequest request, CancellationToken ct = default) =>
        RequiredAsync<PackTypeResponse>(HttpMethod.Put, "api/v1/admin/pack-types",
            JsonContent.Create(request, options: RpgJson.Options), ct);

    /// <summary>GET /api/v1/admin/pack-types (economy-admin): the latest version of every pack type.</summary>
    public Task<PackTypeListResponse> ListPackTypesAsync(CancellationToken ct = default) =>
        RequiredAsync<PackTypeListResponse>(HttpMethod.Get, "api/v1/admin/pack-types", null, ct);

    /// <summary>PUT /api/v1/admin/card-rates (economy-admin): a new version of one rarity's dust value and craft cost.</summary>
    public Task<CardRateResponse> PutCardRateAsync(CardRateRequest request, CancellationToken ct = default) =>
        RequiredAsync<CardRateResponse>(HttpMethod.Put, "api/v1/admin/card-rates",
            JsonContent.Create(request, options: RpgJson.Options), ct);

    /// <summary>GET /api/v1/admin/card-rates (economy-admin): the latest version of every rarity's rates.</summary>
    public Task<CardRateListResponse> ListCardRatesAsync(CancellationToken ct = default) =>
        RequiredAsync<CardRateListResponse>(HttpMethod.Get, "api/v1/admin/card-rates", null, ct);

    /// <summary>POST /api/v1/presence: the heartbeat (204).</summary>
    public Task HeartbeatAsync(PresenceRequest request, CancellationToken ct = default) =>
        SendAsync<object>(HttpMethod.Post, "api/v1/presence", JsonContent.Create(request, options: RpgJson.Options), ct,
            allowNoContent: true);

    private async Task<T> RequiredAsync<T>(HttpMethod method, string route, HttpContent? content, CancellationToken ct)
        where T : class =>
        (await SendAsync<T>(method, route, content, ct).ConfigureAwait(false))!;  // null only with allowNoContent

    private async Task<T?> SendAsync<T>(HttpMethod method, string route, HttpContent? content, CancellationToken ct,
        bool allowNoContent = false) where T : class
    {
        using var request = new HttpRequestMessage(method, route) { Content = content };
        if (AccessToken is { Length: > 0 } token)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }

        using var response = await http.SendAsync(request, ct).ConfigureAwait(false);
        await EnsureSuccessAsync(response, ct).ConfigureAwait(false);
        if (allowNoContent && response.StatusCode == HttpStatusCode.NoContent)
        {
            return null;
        }

        return await response.Content.ReadFromJsonAsync<T>(RpgJson.Options, ct).ConfigureAwait(false)
               ?? throw new GameServerApiException(response.StatusCode, null, $"{route} returned an empty body.");
    }

    private static async Task EnsureSuccessAsync(HttpResponseMessage response, CancellationToken ct)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        ApiProblem? problem = null;
        if (response.Content.Headers.ContentType?.MediaType == "application/problem+json")
        {
            problem = await response.Content.ReadFromJsonAsync<ApiProblem>(RpgJson.Options, ct).ConfigureAwait(false);
        }

        var retryAfter = response.Headers.RetryAfter switch
        {
            { Delta: { } delta } => delta,
            { Date: { } date } => date - DateTimeOffset.UtcNow,
            _ => (TimeSpan?)null,
        };
        throw new GameServerApiException(response.StatusCode, problem,
            $"{(int)response.StatusCode} {problem?.Title ?? response.ReasonPhrase} for {response.RequestMessage?.RequestUri}",
            retryAfter);
    }
}
