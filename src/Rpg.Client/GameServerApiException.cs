using System.Net;

namespace Rpg.Client;

/// <summary>Thrown for any non-2xx response from Rpg.GameServerApi.</summary>
public sealed class GameServerApiException(HttpStatusCode statusCode, ApiProblem? problem, string message,
    TimeSpan? retryAfter = null) : Exception(message)
{
    public HttpStatusCode StatusCode { get; } = statusCode;

    /// <summary>The RFC 9457 problem details body, when the server sent one.</summary>
    public ApiProblem? Problem { get; } = problem;

    /// <summary>The <c>errorCode</c> extension (<c>Rpg.Contracts.Api.V1.ApiErrors</c>), when the server sent one.</summary>
    public int? ErrorCode => Problem?.ErrorCode;

    /// <summary>The <c>Retry-After</c> header as a delay (429, and 409 1107 from slice 4a).</summary>
    public TimeSpan? RetryAfter { get; } = retryAfter;
}

/// <summary>
/// Client-side view of an RFC 9457 problem details body (ASP.NET Core's ProblemDetails) plus the <c>errorCode</c>,
/// <c>expectedSeq</c> (1102), <c>lastSeq</c> (1103, 1106) and, for 1108 (spec run-verify 2.4), <c>epoch</c>,
/// <c>rollbackSeq</c> and <c>reason</c> extensions. Kept here rather than in Rpg.Contracts because the server uses the
/// framework type, not a DTO.
/// </summary>
public sealed record ApiProblem(string? Type, string? Title, int? Status, string? Detail, string? Instance,
    int? ErrorCode = null, int? ExpectedSeq = null, int? LastSeq = null, int? Epoch = null, int? RollbackSeq = null,
    string? Reason = null);
