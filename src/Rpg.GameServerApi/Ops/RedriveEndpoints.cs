using Npgsql;
using Rpg.Contracts.Api.V1;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.Runs;

namespace Rpg.GameServerApi.Ops;

/// <summary>What to re-drive: one destination's outbox rows (null = both), one run's steps (null = every run).</summary>
public sealed record RedriveRequest(string? Destination = null, Guid? RunId = null);

/// <summary>How many rows went back to work.</summary>
public sealed record RedriveResponse(int Rows);

/// <summary>
/// The operator's way back from a dead letter (review fix 2026-11-09; specs settlement-outbox 9.5 and run-verify F8, F24).
/// Both need the <c>ops-admin</c> role (only Development dev tokens carry it).
/// <list type="bullet">
/// <item><c>POST /api/v1/admin/outbox/redrive</c>: every dead-lettered, unpublished outbox row (of one destination) is
/// leasable again with its attempts at zero, e.g. after a Redpanda outage longer than <c>Outbox:MaxAttempts</c> allows.
/// Order still holds: the relay never leases a row while an earlier row of its key is unpublished.</item>
/// <item><c>POST /api/v1/admin/steps/redrive</c>: every dead-lettered step that is still Pending in its run's current
/// epoch (of one run) loses its dead letter, its attempts go to zero and a fresh job is written to the outbox, in one
/// transaction under the run row lock. A step of a voided epoch or an ended run is never re-driven.</item>
/// </list>
/// </summary>
public static class RedriveEndpoints
{
    public static void MapRedriveEndpoints(this WebApplication app)
    {
        app.MapPost("/api/v1/admin/outbox/redrive", async (HttpContext context, RedriveRequest? request,
            NpgsqlDataSource data, MigrationRunner migrations, RpgMetrics metrics, CancellationToken ct) =>
        {
            if (!context.User.IsOpsAdmin())
            {
                return Forbidden();
            }

            if (request?.Destination is { } destination && destination is not ("rabbit" or "redpanda"))
            {
                return Results.Problem(statusCode: StatusCodes.Status400BadRequest, title: "Unknown destination",
                    detail: "destination is rabbit, redpanda or absent (both).");
            }

            await migrations.EnsureMigratedAsync(ct);
            await using var command = data.CreateCommand(
                """
                UPDATE outbox SET dead_lettered_at = NULL, dead_letter_reason = NULL, attempts = 0, leased_until = NULL,
                  lease_token = NULL
                WHERE published_at IS NULL AND dead_lettered_at IS NOT NULL AND ($1::text IS NULL OR destination = $1)
                """);
            command.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlTypes.NpgsqlDbType.Text, Value = (object?)request?.Destination ?? DBNull.Value });
            var rows = await command.ExecuteNonQueryAsync(ct);
            metrics.Redriven("outbox", rows);
            return Results.Ok(new RedriveResponse(rows));
        }).RequireAuthorization();

        app.MapPost("/api/v1/admin/steps/redrive", async (HttpContext context, RedriveRequest? request,
            NpgsqlDataSource data, MigrationRunner migrations, RpgMetrics metrics, TimeProvider clock, CancellationToken ct) =>
        {
            if (!context.User.IsOpsAdmin())
            {
                return Forbidden();
            }

            await migrations.EnsureMigratedAsync(ct);
            await using var connection = await data.OpenConnectionAsync(ct);
            await using var transaction = await connection.BeginTransactionAsync(ct);
            var steps = new List<(Guid RunId, int Epoch, int StepNo, string Ruleset)>();
            await using (var select = new NpgsqlCommand(
                """
                SELECT s.run_id, s.epoch, s.step_no, r.ruleset_version
                FROM run_steps s JOIN runs r ON r.run_id = s.run_id
                WHERE s.status = 'Pending' AND s.dead_lettered_at IS NOT NULL AND s.epoch = r.epoch
                  AND r.status IN ('Active', 'Verifying') AND ($1::uuid IS NULL OR s.run_id = $1)
                ORDER BY s.run_id, s.step_no
                FOR UPDATE OF r, s
                """, connection, transaction))
            {
                select.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlTypes.NpgsqlDbType.Uuid, Value = (object?)request?.RunId ?? DBNull.Value });
                await using var reader = await select.ExecuteReaderAsync(ct);
                while (await reader.ReadAsync(ct))
                {
                    steps.Add((reader.GetGuid(0), reader.GetInt32(1), reader.GetInt32(2), reader.GetString(3)));
                }
            }

            var now = clock.GetUtcNow();
            foreach (var step in steps)
            {
                await using (var update = new NpgsqlCommand(
                    """
                    UPDATE run_steps SET dead_lettered_at = NULL, dead_letter_reason = NULL, attempts = 0
                    WHERE run_id = $1 AND epoch = $2 AND step_no = $3
                    """, connection, transaction))
                {
                    update.Parameters.Add(new NpgsqlParameter { Value = step.RunId });
                    update.Parameters.Add(new NpgsqlParameter { Value = step.Epoch });
                    update.Parameters.Add(new NpgsqlParameter { Value = step.StepNo });
                    await update.ExecuteNonQueryAsync(ct);
                }

                await RunStore.InsertStepJobAsync(connection, transaction, step.RunId, step.Epoch, step.StepNo, step.Ruleset, now, ct);
            }

            await transaction.CommitAsync(ct);
            metrics.Redriven("steps", steps.Count);
            return Results.Ok(new RedriveResponse(steps.Count));
        }).RequireAuthorization();
    }

    private static IResult Forbidden() =>
        Results.Problem(statusCode: StatusCodes.Status403Forbidden, title: "Ops admin required",
            detail: "This endpoint needs the ops-admin role.",
            extensions: new Dictionary<string, object?> { ["errorCode"] = ApiErrors.AdminRequired });
}
