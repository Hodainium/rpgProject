using System.Net;

namespace Rpg.Client;

/// <summary>Thrown for any non-2xx response from Rpg.GameServerApi.</summary>
public sealed class GameServerApiException(HttpStatusCode statusCode, ApiProblem? problem, string message)
    : Exception(message)
{
    public HttpStatusCode StatusCode { get; } = statusCode;

    /// <summary>The RFC 9457 problem details body, when the server sent one.</summary>
    public ApiProblem? Problem { get; } = problem;
}

/// <summary>
/// Client-side view of an RFC 9457 problem details body (ASP.NET Core's ProblemDetails).
/// Kept here rather than in Rpg.Contracts because the server uses the framework type, not a DTO.
/// </summary>
public sealed record ApiProblem(string? Type, string? Title, int? Status, string? Detail, string? Instance);
