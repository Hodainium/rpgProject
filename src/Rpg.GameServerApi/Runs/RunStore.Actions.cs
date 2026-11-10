using System.Data;
using System.Text.Json;
using Npgsql;
using NpgsqlTypes;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;
using Rpg.Economy;
using Rpg.Verification;

namespace Rpg.GameServerApi.Runs;

public enum AppendOutcome { Stored, NotFound, NotActive, Gap, Conflict, RolledBack, StepTooLong }

/// <param name="LastSeq">The run's last stored seq afterwards (unchanged when nothing was stored).</param>
/// <param name="ExpectedSeq"><see cref="AppendOutcome.Gap"/>: the seq the server needs next.</param>
/// <param name="Counted">(type, result) per action looked at, for <c>rpg_run_actions_total</c>.</param>
/// <param name="Battles">Battle sessions written (spec run-verify 2.1: the step that contains a battle verifies it, so no
/// separate verify job is written).</param>
/// <param name="Ended">An <c>end</c> action was stored: the run is Lost.</param>
/// <param name="Epoch">The run's epoch and verified prefix after the call; with the reason on <see cref="AppendOutcome.RolledBack"/>.</param>
/// <param name="Aggregate">Set when the call ran the aggregator (the client's seq 1 arrived).</param>
public sealed record AppendResult(AppendOutcome Outcome, int LastSeq, IReadOnlyList<(string Type, string Result)> Counted,
    int ExpectedSeq = 0, int Battles = 0, bool Ended = false, int Epoch = 0, int VerifiedSeq = 0, string? Reason = null,
    IReadOnlyList<string>? StepKinds = null, AggregateResult? Aggregate = null);

public enum EndOutcome { Ended, Repeated, NotFound, NotActive, UploadIncomplete, Conflict, RolledBack, NoCheckpoint, StepTooLong }

public sealed record EndResult(EndOutcome Outcome, RunStatus Status = RunStatus.Active, int LastSeq = 0, int Epoch = 0,
    int VerifiedSeq = 0, string? Reason = null);

public enum ResumeOutcome { Found, NotFound, NotActive }

public sealed record ResumeResult(ResumeOutcome Outcome, RunResumeResponse? Response = null);

/// <summary>
/// Part B: the run's action log (spec server-authority 2.2–2.4, 3.4). Every write locks the run row first, so two
/// devices uploading at once are serialized and the first wins each seq; idempotency is the (run_id, seq) primary key
/// plus a body comparison. Redis is never consulted here.
/// </summary>
public sealed partial class RunStore
{
    private const string BattleStatus = nameof(BattleSessionStatus.Submitted);

    /// <summary>
    /// Stores a batch (consecutive seqs, already validated) all-or-nothing: seqs already stored with the same body are
    /// skipped; a different body is <see cref="AppendOutcome.Conflict"/>; a seq past the next one is a
    /// <see cref="AppendOutcome.Gap"/>; new actions on a run that isn't Active are <see cref="AppendOutcome.NotActive"/>.
    /// </summary>
    public async Task<AppendResult> AppendAsync(Guid playerId, Guid runId, IReadOnlyList<RunActionRequest> actions, int epoch,
        DateTimeOffset now, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        if (await LockRunAsync(connection, transaction, playerId, runId, ct) is not { } run)
        {
            return new AppendResult(AppendOutcome.NotFound, 0, []);
        }

        if (epoch != run.Epoch)
        {
            return new AppendResult(AppendOutcome.RolledBack, run.LastSeq, [], Epoch: run.Epoch, VerifiedSeq: run.VerifiedSeq,
                Reason: run.RollbackReason);
        }

        var stored = actions[0].Seq <= run.LastSeq
            ? await StoredActionsAsync(connection, transaction, runId, actions[0].Seq, run.LastSeq, ct)
            : [];
        var counted = new List<(string Type, string Result)>();
        var lastSeq = run.LastSeq;
        var status = run.Status;
        var battles = 0;
        var stepKinds = new List<string>();
        var anchorStored = false;
        var lastCheckpoint = run.Legacy ? 0 : await LastCheckpointAsync(connection, transaction, runId, ct);
        foreach (var action in actions)
        {
            var type = action.Action.Type;
            if (action.Seq <= lastSeq)
            {
                if (stored.TryGetValue(action.Seq, out var row) && row.Matches(action))
                {
                    counted.Add((type, "duplicate"));
                    continue;
                }

                return new AppendResult(AppendOutcome.Conflict, run.LastSeq, [.. counted, (type, "conflict")]);
            }

            if (status != nameof(RunStatus.Active))
            {
                return new AppendResult(AppendOutcome.NotActive, run.LastSeq, [.. counted, (type, "inactive")]);
            }

            if (action.Seq != lastSeq + 1)
            {
                return new AppendResult(AppendOutcome.Gap, run.LastSeq, [.. counted, (type, "gap")],
                    ExpectedSeq: lastSeq + 1);
            }

            await InsertActionAsync(connection, transaction, runId, action.Seq, action.Action with { Battle = null },
                action.StateHash, action.Snapshot, action.PlayedAt, now, ct);
            if (action.Action.Battle is { } battle)
            {
                try
                {
                    await Execute(connection, transaction,
                        """
                        INSERT INTO battle_sessions (battle_id, run_id, run_seq, seed, ruleset_version, conditions,
                          action_log, status, submitted_at)
                        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                        """,
                        ct, battle.BattleId, runId, action.Seq, long.Parse(battle.Conditions.Seed), run.Ruleset,
                        Jsonb(battle.Conditions), Jsonb(battle.ActionLog), BattleStatus, now);
                }
                catch (PostgresException ex) when (ex.SqlState == PostgresErrorCodes.UniqueViolation)
                {
                    // The battle id is already stored under another seq: a different body for the same battle.
                    return new AppendResult(AppendOutcome.Conflict, run.LastSeq, [.. counted, (type, "conflict")]);
                }

                // Spec run-verify 2.1: no per-battle job. The step that contains this battle replays it and commits its verdict.
                // (A legacy run, started before slice 4a, is never verified: its battles stay Submitted.)
                battles++;
            }

            if (!run.Legacy)
            {
                if (type == RunActionTypes.NextFloor)
                {
                    await Execute(connection, transaction,
                        // The floor the run stands on, as the server knows it, not the action's own label (an unverified claim
                        // that would steer the stairs gate).
                        "UPDATE run_floors SET end_seq = $3 WHERE run_id = $1 AND floor = $2", ct, runId, run.CurrentFloor, action.Seq);
                }

                // A step is at most MaxStepActions actions, its closing checkpoint included (review fix 2026-11-09: the limit
                // used to be checked only when a snapshot arrived, so a client could store any number of actions without one
                // and make an unbounded step at the next checkpoint or at the end). An action without a snapshot is refused
                // once only the checkpoint's own place is left; the end, which carries a snapshot, is checked in EndAsync.
                if (lastCheckpoint > 0 && action.Seq - lastCheckpoint >= verify.Value.MaxStepActions
                    + (action.Snapshot is not null ? 1 : 0))
                {
                    return new AppendResult(AppendOutcome.StepTooLong, run.LastSeq, [.. counted, (type, "too_long")]);
                }

                if (action.Snapshot is not null)
                {
                    if (lastCheckpoint == 0)
                    {
                        anchorStored = true;   // seq 1: the genesis step (made at run start) waits for this claim
                    }
                    else
                    {
                        // A queued end is a death (Lost): its step replays the run like any other and has nothing to prove "won".
                        stepKinds.Add(await InsertStepAsync(connection, transaction, runId, run, lastCheckpoint, action.Seq,
                            type == RunActionTypes.Battle ? "battle" : "segment", now, ct));
                    }

                    lastCheckpoint = action.Seq;
                }
            }

            counted.Add((type, "accepted"));
            lastSeq = action.Seq;
            if (type == RunActionTypes.End)
            {
                status = nameof(RunStatus.Lost);
            }
        }

        var ended = status != run.Status;
        AggregateResult? aggregate = null;
        if (lastSeq != run.LastSeq)
        {
            await Execute(connection, transaction,
                "UPDATE runs SET last_seq = $2, status = $3, ended_at = CASE WHEN $4 THEN $5 ELSE ended_at END WHERE run_id = $1",
                ct, runId, lastSeq, status, ended, now);
            if (anchorStored)
            {
                // The anchor rule (spec run-verify 2.3): compares seq 1 with the server's own start when it is there.
                aggregate = await RunAggregator.RunAsync(connection, transaction, runId, verify.Value, now, ct);
            }

            await transaction.CommitAsync(ct);
        }

        if (aggregate is { Result: "rejected" })
        {
            // The start disagreed with the server's own (or the run ended some other way): nothing of this upload stands.
            return new AppendResult(AppendOutcome.NotActive, 0, counted, Aggregate: aggregate);
        }

        var (nowEpoch, nowVerified) = aggregate is null ? (run.Epoch, run.VerifiedSeq) : await ProgressAsync(runId, ct);
        return new AppendResult(AppendOutcome.Stored, lastSeq, counted, Battles: battles, Ended: ended, Epoch: nowEpoch,
            VerifiedSeq: nowVerified, StepKinds: stepKinds, Aggregate: aggregate);
    }

    private static async Task<int> LastCheckpointAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        CancellationToken ct)
    {
        await using var select = Command(connection, transaction,
            "SELECT COALESCE(max(seq), 0) FROM run_actions WHERE run_id = $1 AND snapshot IS NOT NULL", runId);
        return Convert.ToInt32(await select.ExecuteScalarAsync(ct));
    }

    /// <summary>One step per snapshot-bearing action after seq 1 (spec run-verify 2.1), with its job in the same transaction.</summary>
    private static async Task<string> InsertStepAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        LockedRun run, int fromSeq, int toSeq, string kind, DateTimeOffset now, CancellationToken ct)
    {
        int stepNo;
        await using (var next = Command(connection, transaction,
                         "SELECT COALESCE(max(step_no), -1) + 1 FROM run_steps WHERE run_id = $1", runId))
        {
            stepNo = Convert.ToInt32(await next.ExecuteScalarAsync(ct));
        }

        await Execute(connection, transaction,
            """
            INSERT INTO run_steps (run_id, epoch, step_no, from_seq, to_seq, kind, status, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, 'Pending', $7)
            """, ct, runId, run.Epoch, stepNo, fromSeq, toSeq, kind, now);
        await InsertStepJobAsync(connection, transaction, runId, run.Epoch, stepNo, run.Ruleset, now, ct);
        return kind;
    }

    /// <summary>The run's epoch and verified prefix right now (after an aggregation).</summary>
    private async Task<(int Epoch, int VerifiedSeq)> ProgressAsync(Guid runId, CancellationToken ct)
    {
        await using var command = dataSource.CreateCommand("SELECT epoch, verified_seq FROM runs WHERE run_id = $1");
        command.Parameters.Add(new NpgsqlParameter { Value = runId });
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? (reader.GetInt32(0), reader.GetInt32(1)) : (0, 0);
    }

    /// <summary>
    /// Ends a run (2.3) at <c>last_seq + 1</c>: Lost at once; Won becomes Verifying (or Won with
    /// <paramref name="autoApproveWins"/>). The end is stored as an <c>end</c> action carrying the claimed run hash and
    /// snapshot, so a retried end with the same body answers the run's status again.
    /// </summary>
    public async Task<EndResult> EndAsync(Guid playerId, Guid runId, RunEndRequest request, DateTimeOffset now,
        CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        if (await LockRunAsync(connection, transaction, playerId, runId, ct) is not { } run)
        {
            return new EndResult(EndOutcome.NotFound);
        }

        if (request.Epoch != run.Epoch)
        {
            return new EndResult(EndOutcome.RolledBack, Enum.Parse<RunStatus>(run.Status), run.LastSeq, run.Epoch,
                run.VerifiedSeq, run.RollbackReason);
        }

        var status = Enum.Parse<RunStatus>(run.Status);
        if (request.Seq <= run.LastSeq)
        {
            var stored = await StoredActionsAsync(connection, transaction, runId, request.Seq, request.Seq, ct);
            if (stored.TryGetValue(request.Seq, out var row) && row.Type == RunActionTypes.End
                && row.StateHash == request.RunHash && SameJson(row.Snapshot, request.Snapshot)
                && (request.Status == RunEndStatus.Lost) == (status == RunStatus.Lost))
            {
                return new EndResult(EndOutcome.Repeated, status, run.LastSeq);
            }

            return new EndResult(status == RunStatus.Active ? EndOutcome.Conflict : EndOutcome.NotActive, status,
                run.LastSeq);
        }

        if (status != RunStatus.Active)
        {
            return new EndResult(EndOutcome.NotActive, status, run.LastSeq);
        }

        if (request.Seq != run.LastSeq + 1)
        {
            return new EndResult(EndOutcome.UploadIncomplete, status, run.LastSeq);
        }

        // Spec run-verify 2.6: a win waits for the verifier (Run:AutoApproveWins is gone). A legacy run was never verified.
        var ended = request.Status == RunEndStatus.Lost ? RunStatus.Lost
            : run.Legacy ? RunStatus.Won
            : RunStatus.Verifying;
        var previousCheckpoint = run.Legacy ? 0 : await LastCheckpointAsync(connection, transaction, runId, ct);
        if (!run.Legacy && previousCheckpoint > 0 && request.Seq - previousCheckpoint > verify.Value.MaxStepActions)
        {
            // The end step is a step like the others (MaxStepActions). Uploads keep room for it, so only a log stored before
            // that rule can reach this.
            return new EndResult(EndOutcome.StepTooLong, status, run.LastSeq, run.Epoch, run.VerifiedSeq);
        }

        if (!run.Legacy && request.Status == RunEndStatus.Won && previousCheckpoint == 0)
        {
            // Without a checkpoint there is no end step to verify the win with: the start must be uploaded first. (Otherwise a
            // client could "win" with the start state's own hash and never play.)
            return new EndResult(EndOutcome.NoCheckpoint, status, run.LastSeq, run.Epoch, run.VerifiedSeq);
        }

        await InsertActionAsync(connection, transaction, runId, request.Seq,
            new RunAction(RunActionTypes.End, run.CurrentFloor), request.RunHash, request.Snapshot, now, now, ct);
        await Execute(connection, transaction,
            """
            UPDATE runs SET last_seq = $2, status = $3, claimed_run_hash = $4,
              ended_at = CASE WHEN $5 THEN $6 ELSE NULL END, end_seq = $2
            WHERE run_id = $1
            """,
            ct, runId, request.Seq, ended.ToString(), request.RunHash, ended != RunStatus.Verifying, now);
        if (!run.Legacy)
        {
            // The end is a step like any checkpoint: its snapshot is what the verifier checks the win against.
            if (previousCheckpoint > 0 && previousCheckpoint < request.Seq)
            {
                // Only a win has an end step (kind end: "the run is actually won"); a death is replayed as an ordinary segment.
                await InsertStepAsync(connection, transaction, runId, run, previousCheckpoint, request.Seq,
                    request.Status == RunEndStatus.Won ? "end" : "segment", now, ct);
            }
        }

        await transaction.CommitAsync(ct);
        return new EndResult(EndOutcome.Ended, ended, request.Seq, run.Epoch, run.VerifiedSeq);
    }

    /// <summary>
    /// Resume without a save (2.4): every issued floor seed, the latest checkpoint snapshot and the actions after it,
    /// read in one repeatable-read snapshot of the database. Only an Active run can be resumed.
    /// </summary>
    public async Task<ResumeResult> ResumeAsync(Guid playerId, Guid runId, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(IsolationLevel.RepeatableRead, ct);

        RunStatus status;
        int epoch, verifiedSeq;
        bool legacy;
        JsonElement? genesis = null;
        IReadOnlyList<string>? cardPool = null, unlockedCharacters = null;
        await using (var select = Command(connection, transaction,
                         "SELECT status, epoch, verified_seq, legacy, genesis_snapshot::text, card_pool::text, unlocked_characters::text FROM runs WHERE run_id = $1 AND player_id = $2",
                         runId, playerId))
        await using (var reader = await select.ExecuteReaderAsync(ct))
        {
            if (!await reader.ReadAsync(ct))
            {
                return new ResumeResult(ResumeOutcome.NotFound);
            }

            status = Enum.Parse<RunStatus>(reader.GetString(0));
            epoch = reader.GetInt32(1);
            verifiedSeq = reader.GetInt32(2);
            legacy = reader.GetBoolean(3);
            genesis = reader.IsDBNull(4) ? null : Parse(reader.GetString(4));
            cardPool = reader.IsDBNull(5) ? null : JsonSerializer.Deserialize<List<string>>(reader.GetString(5), RpgJson.Options);
            unlockedCharacters = reader.IsDBNull(6) ? null : JsonSerializer.Deserialize<List<string>>(reader.GetString(6), RpgJson.Options);
        }

        if (status != RunStatus.Active)
        {
            return new ResumeResult(ResumeOutcome.NotActive);
        }

        var floors = new List<FloorSeedResponse>();
        await using (var select = Command(connection, transaction,
                         "SELECT floor, floor_seed FROM run_floors WHERE run_id = $1 ORDER BY floor", runId))
        await using (var reader = await select.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                floors.Add(new FloorSeedResponse(runId.ToString("D"), reader.GetInt32(0), reader.GetInt64(1).ToString()));
            }
        }

        // Spec run-verify 2.6: the latest *verified* checkpoint (a legacy run: the latest claimed one, as before). Seq 1 is
        // served from the server's own genesis snapshot; a run with no uploads yet gets that snapshot at seq 0.
        var checkpointSeq = 0;
        var snapshot = JsonDocument.Parse("null").RootElement;
        await using (var select = Command(connection, transaction,
                         """
                         SELECT seq, snapshot FROM run_actions
                         WHERE run_id = $1 AND snapshot IS NOT NULL AND ($2 OR seq <= GREATEST($3, 1))
                         ORDER BY seq DESC LIMIT 1
                         """, runId, legacy, verifiedSeq))
        await using (var reader = await select.ExecuteReaderAsync(ct))
        {
            if (await reader.ReadAsync(ct))
            {
                checkpointSeq = reader.GetInt32(0);
                snapshot = Parse(reader.GetString(1));
            }
        }

        if (!legacy && checkpointSeq <= 1)
        {
            // Never the client's own seq 1 claim (review fix 2026-11-09): until the genesis job has written the server's start,
            // there is no snapshot to serve, and the client waits and asks again (ServerLink retries a null snapshot).
            snapshot = genesis ?? JsonDocument.Parse("null").RootElement;
        }

        var tail = new List<RunActionRequest>();
        await using (var select = Command(connection, transaction,
                         """
                         SELECT a.seq, a.action, a.state_hash, a.played_at, a.snapshot, b.battle_id, b.conditions, b.action_log
                         FROM run_actions a LEFT JOIN battle_sessions b ON b.run_id = a.run_id AND b.run_seq = a.seq
                         WHERE a.run_id = $1 AND a.seq > $2 ORDER BY a.seq
                         """, runId, checkpointSeq))
        await using (var reader = await select.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                var action = JsonSerializer.Deserialize<RunAction>(reader.GetString(1), RpgJson.Options)!;
                if (!reader.IsDBNull(5))
                {
                    action = action with
                    {
                        Battle = new BattleSubmission(reader.GetString(5),
                            JsonSerializer.Deserialize<BattleSnapshot>(reader.GetString(6), RpgJson.Options)!,
                            JsonSerializer.Deserialize<ActionLog>(reader.GetString(7), RpgJson.Options)!),
                    };
                }

                tail.Add(new RunActionRequest(reader.GetInt32(0), action, reader.GetString(2),
                    reader.GetFieldValue<DateTimeOffset>(3), reader.IsDBNull(4) ? null : Parse(reader.GetString(4))));
            }
        }

        return new ResumeResult(ResumeOutcome.Found,
            new RunResumeResponse(runId.ToString("D"), status, floors, checkpointSeq, snapshot, tail, epoch, verifiedSeq,
                unlockedCharacters, cardPool));
    }

    /// <summary>The battle stored with the run's action <paramref name="seq"/>, and the run's owner.</summary>
    public async Task<StoredBattle?> GetBattleAsync(Guid runId, int seq, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand(
            """
            SELECT r.player_id, b.battle_id, b.conditions, b.action_log, b.ruleset_version, b.status, b.submitted_at,
              b.verdict
            FROM battle_sessions b JOIN runs r ON r.run_id = b.run_id
            WHERE b.run_id = $1 AND b.run_seq = $2
            """);
        command.Parameters.Add(new NpgsqlParameter { Value = runId });
        command.Parameters.Add(new NpgsqlParameter { Value = seq });
        await using var reader = await command.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
        {
            return null;
        }

        return new StoredBattle(reader.GetGuid(0), new BattleSessionResponse(
            reader.GetString(1), runId.ToString("D"), seq,
            JsonSerializer.Deserialize<BattleSnapshot>(reader.GetString(2), RpgJson.Options)!,
            JsonSerializer.Deserialize<ActionLog>(reader.GetString(3), RpgJson.Options)!,
            reader.GetString(4), Enum.Parse<BattleSessionStatus>(reader.GetString(5)),
            reader.GetFieldValue<DateTimeOffset>(6),
            reader.IsDBNull(7) ? null : JsonSerializer.Deserialize<BattleVerdict>(reader.GetString(7), RpgJson.Options)));
    }

    private sealed record LockedRun(string Status, int LastSeq, int CurrentFloor, string Ruleset, int Epoch, int VerifiedSeq,
        string? RollbackReason, bool Legacy);

    private static async Task<LockedRun?> LockRunAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        Guid playerId, Guid runId, CancellationToken ct)
    {
        await using var select = Command(connection, transaction,
            "SELECT status, last_seq, current_floor, ruleset_version, epoch, verified_seq, rollback_reason, legacy FROM runs WHERE run_id = $1 AND player_id = $2 FOR UPDATE",
            runId, playerId);
        await using var reader = await select.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct)
            ? new LockedRun(reader.GetString(0), reader.GetInt32(1), reader.GetInt32(2), reader.GetString(3), reader.GetInt32(4),
                reader.GetInt32(5), reader.IsDBNull(6) ? null : reader.GetString(6), reader.GetBoolean(7))
            : null;
    }

    /// <summary>A stored action as the retry comparison needs it.</summary>
    private sealed record StoredAction(string Type, JsonElement Action, string StateHash, JsonElement? Snapshot,
        string? BattleId, JsonElement? Conditions, JsonElement? ActionLog)
    {
        /// <summary>The same body: action (battle aside), state hash, snapshot and battle, compared as JSON values.</summary>
        public bool Matches(RunActionRequest request)
        {
            var battle = request.Action.Battle;
            return StateHash == request.StateHash
                   && JsonElement.DeepEquals(Action,
                       JsonSerializer.SerializeToElement(request.Action with { Battle = null }, RpgJson.Options))
                   && SameJson(Snapshot, request.Snapshot)
                   && (battle is null
                       ? BattleId is null
                       : BattleId == battle.BattleId
                         && SameJson(Conditions, JsonSerializer.SerializeToElement(battle.Conditions, RpgJson.Options))
                         && SameJson(ActionLog, JsonSerializer.SerializeToElement(battle.ActionLog, RpgJson.Options)));
        }
    }

    private static async Task<Dictionary<int, StoredAction>> StoredActionsAsync(NpgsqlConnection connection,
        NpgsqlTransaction transaction, Guid runId, int fromSeq, int toSeq, CancellationToken ct)
    {
        var rows = new Dictionary<int, StoredAction>();
        await using var select = Command(connection, transaction,
            """
            SELECT a.seq, a.type, a.action, a.state_hash, a.snapshot, b.battle_id, b.conditions, b.action_log
            FROM run_actions a LEFT JOIN battle_sessions b ON b.run_id = a.run_id AND b.run_seq = a.seq
            WHERE a.run_id = $1 AND a.seq BETWEEN $2 AND $3
            """, runId, fromSeq, toSeq);
        await using var reader = await select.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            rows[reader.GetInt32(0)] = new StoredAction(reader.GetString(1), Parse(reader.GetString(2)),
                reader.GetString(3), reader.IsDBNull(4) ? null : Parse(reader.GetString(4)),
                reader.IsDBNull(5) ? null : reader.GetString(5), reader.IsDBNull(6) ? null : Parse(reader.GetString(6)),
                reader.IsDBNull(7) ? null : Parse(reader.GetString(7)));
        }

        return rows;
    }

    private static Task InsertActionAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        int seq, RunAction action, string stateHash, JsonElement? snapshot, DateTimeOffset playedAt,
        DateTimeOffset receivedAt, CancellationToken ct) =>
        Execute(connection, transaction,
            """
            INSERT INTO run_actions (run_id, seq, floor, type, action, state_hash, snapshot, played_at, received_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            """,
            ct, runId, seq, action.Floor, action.Type, Jsonb(action), stateHash,
            new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Jsonb, Value = (object?)snapshot?.GetRawText() ?? DBNull.Value },
            playedAt.ToUniversalTime(), receivedAt.ToUniversalTime());

    private static NpgsqlParameter Jsonb<T>(T value) =>
        new() { NpgsqlDbType = NpgsqlDbType.Jsonb, Value = JsonSerializer.Serialize(value, RpgJson.Options) };

    private static JsonElement Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }

    private static bool SameJson(JsonElement? a, JsonElement? b) =>
        a is null ? b is null : b is not null && JsonElement.DeepEquals(a.Value, b.Value);
}
