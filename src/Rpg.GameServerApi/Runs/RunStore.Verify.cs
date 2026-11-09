using System.Text.Json;
using Npgsql;
using Rpg.Contracts.Runs;

namespace Rpg.GameServerApi.Runs;

/// <summary>Spec battle-verify 5: the gauge query on <c>battle_sessions</c>. (The sweeper left with the outbox, spec settlement-outbox 2.1.)</summary>
public sealed partial class RunStore
{
    /// <summary>Submitted, not dead-lettered sessions: how many, and when the oldest was submitted.</summary>
    public async Task<(long Count, DateTimeOffset? Oldest)> UnverifiedAsync(CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand(
            """
            SELECT count(*), min(b.submitted_at) FROM battle_sessions b JOIN runs r ON r.run_id = b.run_id
            WHERE b.status = 'Submitted' AND b.dead_lettered_at IS NULL AND NOT r.legacy
            """);
        await using var reader = await command.ExecuteReaderAsync(ct);
        await reader.ReadAsync(ct);
        return (reader.GetInt64(0), reader.IsDBNull(1) ? null : reader.GetFieldValue<DateTimeOffset>(1));
    }

    /// <summary>Steps not yet decided and not dead-lettered: how many, and when the oldest was created (spec run-verify 5).</summary>
    public async Task<(long Count, DateTimeOffset? Oldest)> PendingStepsAsync(CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand(
            "SELECT count(*), min(created_at) FROM run_steps WHERE status = 'Pending' AND dead_lettered_at IS NULL");
        await using var reader = await command.ExecuteReaderAsync(ct);
        await reader.ReadAsync(ct);
        return (reader.GetInt64(0), reader.IsDBNull(1) ? null : reader.GetFieldValue<DateTimeOffset>(1));
    }

    /// <summary>Pending gems, for the <c>rpg_gems_pending</c> gauge.</summary>
    public async Task<long> PendingGemsAsync(CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand(
            "SELECT COALESCE(sum(delta), 0) FROM wallet_ledger WHERE status = 'pending'");
        return Convert.ToInt64(await command.ExecuteScalarAsync(ct));
    }

    /// <summary>The verified digest of a floor (spec run-verify 2.7) and the run's owner; null until the floor's digest is written.</summary>
    public async Task<(Guid PlayerId, FloorDigestResponse Digest)?> FloorDigestAsync(Guid runId, int floor, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand(
            """
            SELECT r.player_id, f.digest::text, f.verified_at
            FROM run_floors f JOIN runs r ON r.run_id = f.run_id
            WHERE f.run_id = $1 AND f.floor = $2 AND f.digest IS NOT NULL
            """);
        command.Parameters.Add(new NpgsqlParameter { Value = runId });
        command.Parameters.Add(new NpgsqlParameter { Value = floor });
        await using var reader = await command.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
        {
            return null;
        }

        return (reader.GetGuid(0), new FloorDigestResponse(runId.ToString("D"), floor,
            reader.IsDBNull(2) ? null : reader.GetFieldValue<DateTimeOffset>(2), Parse(reader.GetString(1))));
    }

    /// <summary>The run's steps, newest epoch first (Development endpoint, tests and e2e), and the run's owner.</summary>
    public async Task<(Guid PlayerId, IReadOnlyList<RunStepDto> Steps)?> StepsAsync(Guid runId, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var owner = dataSource.CreateCommand("SELECT player_id FROM runs WHERE run_id = $1");
        owner.Parameters.Add(new NpgsqlParameter { Value = runId });
        if (await owner.ExecuteScalarAsync(ct) is not Guid playerId)
        {
            return null;
        }

        await using var command = dataSource.CreateCommand(
            """
            SELECT epoch, step_no, from_seq, to_seq, kind, status, verdict #>> '{mismatch,reason}'
            FROM run_steps WHERE run_id = $1 ORDER BY epoch, step_no
            """);
        command.Parameters.Add(new NpgsqlParameter { Value = runId });
        await using var reader = await command.ExecuteReaderAsync(ct);
        var steps = new List<RunStepDto>();
        while (await reader.ReadAsync(ct))
        {
            steps.Add(new RunStepDto(reader.GetInt32(0), reader.GetInt32(1), reader.GetInt32(2), reader.GetInt32(3),
                Enum.Parse<StepKind>(reader.GetString(4), ignoreCase: true), Enum.Parse<StepStatus>(reader.GetString(5)),
                reader.IsDBNull(6) ? null : reader.GetString(6)));
        }

        return (playerId, steps);
    }
}
