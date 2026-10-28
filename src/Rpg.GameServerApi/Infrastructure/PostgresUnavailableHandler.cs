using Microsoft.AspNetCore.Diagnostics;
using Npgsql;

namespace Rpg.GameServerApi.Infrastructure;

/// <summary>
/// Postgres unreachable (a connect or I/O failure, not a server-side SQL error) answers 503 ProblemDetails
/// (spec server-authority 4) instead of 500. Readiness already reports it unhealthy.
/// </summary>
public sealed class PostgresUnavailableHandler(IProblemDetailsService problemDetails,
    ILogger<PostgresUnavailableHandler> logger) : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(HttpContext context, Exception exception, CancellationToken ct)
    {
        if (exception is not NpgsqlException || exception is PostgresException)
        {
            return false;
        }

        logger.LogWarning("Postgres unavailable for {Path}: {Message}", context.Request.Path, exception.Message);
        context.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
        return await problemDetails.TryWriteAsync(new ProblemDetailsContext
        {
            HttpContext = context,
            Exception = exception,
            ProblemDetails = { Status = StatusCodes.Status503ServiceUnavailable, Title = "Database unavailable" },
        });
    }
}
