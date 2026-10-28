using System.Net;
using System.Net.Http.Json;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;

namespace Rpg.Client;

/// <summary>
/// Typed client for Rpg.GameServerApi. The caller owns the <see cref="HttpClient"/> and sets its
/// <see cref="HttpClient.BaseAddress"/> (with a trailing slash); routes here are relative.
/// <paramref name="devPlayer"/>: Part A's development identity, sent as <see cref="ApiHeaders.DevPlayer"/> on every
/// request (spec server-authority 3.2); Part B replaces it with a bearer token.
/// </summary>
public sealed class GameServerClient(HttpClient http, string? devPlayer = null)
{
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

    private async Task<T> RequiredAsync<T>(HttpMethod method, string route, HttpContent? content, CancellationToken ct)
        where T : class =>
        (await SendAsync<T>(method, route, content, ct).ConfigureAwait(false))!;  // null only with allowNoContent

    private async Task<T?> SendAsync<T>(HttpMethod method, string route, HttpContent? content, CancellationToken ct,
        bool allowNoContent = false) where T : class
    {
        using var request = new HttpRequestMessage(method, route) { Content = content };
        if (devPlayer is not null)
        {
            request.Headers.Add(ApiHeaders.DevPlayer, devPlayer);
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
