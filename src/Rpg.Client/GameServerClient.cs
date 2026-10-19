using System.Net.Http.Json;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Serialization;

namespace Rpg.Client;

/// <summary>
/// Typed client for Rpg.GameServerApi. The caller owns the <see cref="HttpClient"/> and sets its
/// <see cref="HttpClient.BaseAddress"/> (with a trailing slash); routes here are relative.
/// </summary>
public sealed class GameServerClient(HttpClient http)
{
    public Task<ServerInfoResponse> GetInfoAsync(CancellationToken ct = default) =>
        GetAsync<ServerInfoResponse>("api/v1/info", ct);

    private async Task<T> GetAsync<T>(string route, CancellationToken ct)
    {
        using var response = await http.GetAsync(route, ct).ConfigureAwait(false);
        await EnsureSuccessAsync(response, ct).ConfigureAwait(false);
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

        throw new GameServerApiException(response.StatusCode, problem,
            $"{(int)response.StatusCode} {problem?.Title ?? response.ReasonPhrase} for {response.RequestMessage?.RequestUri}");
    }
}
