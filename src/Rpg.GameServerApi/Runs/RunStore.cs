using Npgsql;
using Rpg.Contracts.Runs;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Migrations;

namespace Rpg.GameServerApi.Runs;

/// <summary>A run as stored, with its owner (the summary DTO has no owner, so ownership checks need this).</summary>
public sealed record StoredRun(Guid PlayerId, RunSummaryResponse Summary);

public enum StartOutcome { Created, AbandonedPrevious, PreviousVerifying }

public sealed record StartResult(StartOutcome Outcome, Guid RunId, long FloorSeed, DateTimeOffset StartedAt,
    Guid? AbandonedRunId);

public enum FloorOutcome { Issued, Repeated, NotFound, NotActive, NotReachable, UploadIncomplete }

/// <param name="LastSeq">For <see cref="FloorOutcome.UploadIncomplete"/>: the last stored seq.</param>
public sealed record FloorResult(FloorOutcome Outcome, long FloorSeed = 0, int LastSeq = 0);

/// <summary>
/// Postgres access for runs (spec server-authority 2.1, 3.4). Every write is one transaction that locks what it
/// changes (the player row for a run start, the run row for the stairs), so ordering never depends on Redis.
/// </summary>
public sealed partial class RunStore(NpgsqlDataSource dataSource, MigrationRunner migrations, FloorSeeds seeds)
{
    private const string SummaryColumns =
        "run_id, player_id, status, current_floor, last_seq, ruleset_version, started_at, ended_at";

    /// <summary>
    /// Starts a run: abandons the player's Active run (a Verifying one can't be: <see cref="StartOutcome.PreviousVerifying"/>,
    /// nothing written), inserts the run and its floor 0 seed.
    /// </summary>
    public async Task<StartResult> StartAsync(Player player, RunStartRequest request, DateTimeOffset now,
        CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);

        await Execute(connection, transaction,
            "INSERT INTO players (player_id, display_name, created_at) VALUES ($1, $2, $3) ON CONFLICT (player_id) DO NOTHING",
            ct, player.Id, player.Name, now);
        // Serializes concurrent starts of one player, so the one_active_run index is never what decides.
        await Execute(connection, transaction, "SELECT 1 FROM players WHERE player_id = $1 FOR UPDATE", ct, player.Id);

        Guid? abandoned = null;
        await using (var active = Command(connection, transaction,
                         "SELECT run_id, status FROM runs WHERE player_id = $1 AND status IN ('Active', 'Verifying')",
                         player.Id))
        await using (var reader = await active.ExecuteReaderAsync(ct))
        {
            if (await reader.ReadAsync(ct))
            {
                if (reader.GetString(1) == nameof(RunStatus.Verifying))
                {
                    return new StartResult(StartOutcome.PreviousVerifying, reader.GetGuid(0), 0, now, null);
                }

                abandoned = reader.GetGuid(0);
            }
        }

        if (abandoned is { } previous)
        {
            await Execute(connection, transaction,
                "UPDATE runs SET status = $2, ended_at = $3 WHERE run_id = $1", ct,
                previous, nameof(RunStatus.Abandoned), now);
        }

        var runId = Guid.CreateVersion7(now);
        var floorSeed = seeds.Derive(runId, 0);
        await Execute(connection, transaction,
            """
            INSERT INTO runs (run_id, player_id, ruleset_version, run_structure_id, character_ids, status, started_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            """,
            ct, runId, player.Id, request.RulesetVersion, request.RunStructureId, request.CharacterIds.ToArray(),
            nameof(RunStatus.Active), now);
        await Execute(connection, transaction,
            "INSERT INTO run_floors (run_id, floor, floor_seed, issued_at) VALUES ($1, 0, $2, $3)",
            ct, runId, floorSeed, now);
        await transaction.CommitAsync(ct);

        return new StartResult(abandoned is null ? StartOutcome.Created : StartOutcome.AbandonedPrevious, runId,
            floorSeed, now, abandoned);
    }

    /// <summary>
    /// The stairs (2.1): the current floor again returns its stored seed; the next floor is issued and becomes current
    /// once the floor's log is in (Part B: <paramref name="afterSeq"/> must be the last stored seq, else
    /// <see cref="FloorOutcome.UploadIncomplete"/>); anything else is not reachable. Another player's run is
    /// <see cref="FloorOutcome.NotFound"/>.
    /// </summary>
    public async Task<FloorResult> IssueFloorAsync(Guid playerId, Guid runId, int floor, int? afterSeq,
        DateTimeOffset now, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);

        string status;
        int currentFloor;
        int lastSeq;
        await using (var select = Command(connection, transaction,
                         "SELECT status, current_floor, last_seq FROM runs WHERE run_id = $1 AND player_id = $2 FOR UPDATE",
                         runId, playerId))
        await using (var reader = await select.ExecuteReaderAsync(ct))
        {
            if (!await reader.ReadAsync(ct))
            {
                return new FloorResult(FloorOutcome.NotFound);
            }

            status = reader.GetString(0);
            currentFloor = reader.GetInt32(1);
            lastSeq = reader.GetInt32(2);
        }

        if (status != nameof(RunStatus.Active))
        {
            return new FloorResult(FloorOutcome.NotActive);
        }

        if (floor == currentFloor)
        {
            await using var stored = Command(connection, transaction,
                "SELECT floor_seed FROM run_floors WHERE run_id = $1 AND floor = $2", runId, floor);
            return new FloorResult(FloorOutcome.Repeated, (long)(await stored.ExecuteScalarAsync(ct))!);
        }

        if (floor != currentFloor + 1)
        {
            return new FloorResult(FloorOutcome.NotReachable);
        }

        if (afterSeq != lastSeq)
        {
            return new FloorResult(FloorOutcome.UploadIncomplete, LastSeq: lastSeq);
        }

        var floorSeed = seeds.Derive(runId, floor);
        await Execute(connection, transaction,
            "INSERT INTO run_floors (run_id, floor, floor_seed, issued_at) VALUES ($1, $2, $3, $4)",
            ct, runId, floor, floorSeed, now);
        await Execute(connection, transaction, "UPDATE runs SET current_floor = $2 WHERE run_id = $1", ct, runId, floor);
        await transaction.CommitAsync(ct);
        return new FloorResult(FloorOutcome.Issued, floorSeed);
    }

    public async Task<StoredRun?> GetAsync(Guid runId, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand($"SELECT {SummaryColumns} FROM runs WHERE run_id = $1");
        command.Parameters.Add(new NpgsqlParameter { Value = runId });
        return await ReadOneAsync(command, ct);
    }

    /// <summary>The player's Active or Verifying run, if any.</summary>
    public async Task<StoredRun?> GetCurrentAsync(Guid playerId, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand(
            $"SELECT {SummaryColumns} FROM runs WHERE player_id = $1 AND status IN ('Active', 'Verifying')");
        command.Parameters.Add(new NpgsqlParameter { Value = playerId });
        return await ReadOneAsync(command, ct);
    }

    /// <summary>Runs with status Active, for the rpg_runs_in_progress gauge.</summary>
    public async Task<long> CountActiveAsync(CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand("SELECT count(*) FROM runs WHERE status = 'Active'");
        return (long)(await command.ExecuteScalarAsync(ct))!;
    }

    private static async Task<StoredRun?> ReadOneAsync(NpgsqlCommand command, CancellationToken ct)
    {
        await using var reader = await command.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
        {
            return null;
        }

        return new StoredRun(reader.GetGuid(1), new RunSummaryResponse(
            reader.GetGuid(0).ToString("D"),
            Enum.Parse<RunStatus>(reader.GetString(2)),
            reader.GetInt32(3),
            reader.GetInt32(4),
            reader.GetString(5),
            reader.GetFieldValue<DateTimeOffset>(6),
            reader.IsDBNull(7) ? null : reader.GetFieldValue<DateTimeOffset>(7)));
    }

    private static NpgsqlCommand Command(NpgsqlConnection connection, NpgsqlTransaction transaction, string sql,
        params object[] values)
    {
        var command = new NpgsqlCommand(sql, connection, transaction);
        foreach (var value in values)
        {
            command.Parameters.Add(value as NpgsqlParameter ?? new NpgsqlParameter { Value = value });
        }

        return command;
    }

    private static async Task Execute(NpgsqlConnection connection, NpgsqlTransaction transaction, string sql,
        CancellationToken ct, params object[] values)
    {
        await using var command = Command(connection, transaction, sql, values);
        await command.ExecuteNonQueryAsync(ct);
    }
}
