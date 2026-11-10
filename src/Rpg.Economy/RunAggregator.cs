using System.Text.Json;
using Npgsql;
using Rpg.Contracts.Events;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;
using Rpg.Verification;

namespace Rpg.Economy;

/// <summary>Spec run-verify 3.4 (<c>Verify:*</c>), read by the aggregator.</summary>
public sealed class RunVerifyOptions
{
    public const string Section = "Verify";

    /// <summary>Rollbacks a run may have; the next rejection ends it (<c>Rejected</c>).</summary>
    public int MaxRollbacks { get; set; } = 3;

    /// <summary>The <c>Retry-After</c> of a <c>1107</c> (the floor just played is not verified yet).</summary>
    public TimeSpan GateRetryAfter { get; set; } = TimeSpan.FromSeconds(5);

    /// <summary>Longest step the upload accepts (actions between two snapshot-bearing actions).</summary>
    public int MaxStepActions { get; set; } = 500;
}

/// <summary>What one aggregation changed, for the caller's cache invalidation and metrics.</summary>
/// <param name="Result">advanced | waiting | rolled_back | rejected | won | noop (the <c>rpg_fanin_total</c> label).</param>
/// <param name="VoidedBattleSeqs">On a rollback: the run seqs of the battle sessions it moved to <c>battle_sessions_voided</c>.
/// Their cached session and verdict (<c>battle:session</c>, <c>battle:verdict</c>) must go, or a voided battle keeps
/// reading as Verified and hides the new epoch's battle at the same seq.</param>
public sealed record AggregateResult(string Result, int VerifiedSeq, int FloorsVerified, int GemsReleased, int GemsVoided,
    bool StatusChanged, StepMismatchReason? Reason = null, int RejectedStepNo = -1, int MarksClaimed = 0, int AlreadyPaid = 0,
    IReadOnlyList<int>? VoidedBattleSeqs = null)
{
    public static AggregateResult NoOp(int verifiedSeq = 0) => new("noop", verifiedSeq, 0, 0, 0, false);

    /// <summary>The run's cached summary, wallet or floors may be stale.</summary>
    public bool Changed => Result != "noop" && Result != "waiting" || FloorsVerified > 0 || GemsReleased > 0;
}

/// <summary>
/// The fan-in aggregator (spec run-verify 2.3): a pure function of table state, called inside the transaction of
/// whatever just changed it (a step verdict, or the upload that stores the client's seq 1). It advances the run's verified
/// prefix over contiguous verified steps whose ends meet the next start, releases pending gems, verifies floors, ends a
/// won run, and rolls a run back (2.4) when a step is rejected or a link is broken. Running it twice changes nothing: the
/// prefix only moves forward and every write is guarded. No game rule runs here: it compares strings and numbers.
/// </summary>
public static class RunAggregator
{
    private sealed record RunRow(Guid PlayerId, string Status, int Epoch, int VerifiedSeq, int? EndSeq, string? GenesisHash,
        string Ruleset, int Rollbacks, bool Legacy, int LastSeq);

    private sealed record StepRow(int Epoch, int StepNo, int FromSeq, int ToSeq, string Kind, string Status, string? StartHash,
        string? EndHash, string? VerdictJson);

    public static async Task<AggregateResult> RunAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        RunVerifyOptions options, DateTimeOffset now, CancellationToken ct)
    {
        if (await LockAsync(connection, transaction, runId, ct) is not { } run || run.Legacy)
        {
            return AggregateResult.NoOp();
        }

        var verified = run.VerifiedSeq;
        var floorsVerified = 0;
        var released = new PendingGems.ReleaseResult(0, 0, 0);
        var statusChanged = false;

        // The anchor rule: the client's seq 1 against the server's own rebuilt start.
        if (verified == 0)
        {
            if (run.GenesisHash is null && await GenesisRejectedAsync(connection, transaction, runId, ct) is { } refused)
            {
                // The server could not even rebuild the start (an unknown structure or character, a malformed request): no player
                // can play that run, and there is nothing verified to return to. End it instead of leaving it stuck.
                return await EndRunAsync(connection, transaction, runId, run, refused, -1, 0, "Genesis", now, ct);
            }

            if (run.GenesisHash is null || await ClaimedHashAsync(connection, transaction, runId, 1, ct) is not { } claimed)
            {
                return AggregateResult.NoOp();
            }

            if (!string.Equals(claimed, run.GenesisHash, StringComparison.Ordinal))
            {
                return await EndRunAsync(connection, transaction, runId, run, StepMismatchReason.GenesisMismatch, -1, 1,
                    "Genesis", now, ct);
            }

            verified = 1;
            await ExecuteAsync(connection, transaction, "UPDATE runs SET verified_seq = 1 WHERE run_id = $1 AND verified_seq < 1", ct, runId);
            // Floor 0 was entered by the genesis step, so its digest is the genesis verdict's.
            await using var genesisVerdict = new NpgsqlCommand(
                "SELECT verdict::text FROM run_steps WHERE run_id = $1 AND kind = 'genesis' AND status = 'Verified' LIMIT 1",
                connection, transaction);
            genesisVerdict.Parameters.Add(new NpgsqlParameter { Value = runId });
            if (await genesisVerdict.ExecuteScalarAsync(ct) is string genesisJson && FloorDigestOf(genesisJson) is { } genesisDigest)
            {
                await ExecuteAsync(connection, transaction,
                    "UPDATE run_floors SET digest = $3::jsonb WHERE run_id = $1 AND floor = $2", ct, runId, genesisDigest.Floor,
                    genesisDigest.Json);
            }
        }

        var advanced = verified != run.VerifiedSeq;
        while (true)
        {
            var next = await NextStepAsync(connection, transaction, runId, verified, ct);
            if (next is null || next.Status is "Pending" or "Voided")
            {
                break;
            }

            if (next.Status == "Rejected")
            {
                var (reason, mismatchSeq) = ReasonOf(next.VerdictJson);
                // What this pass verified before the bad step counts: floors and gems are settled before the rollback.
                (int Floors, PendingGems.ReleaseResult Release) settled = advanced
                    ? await SettleAsync(connection, transaction, runId, run, verified, now, ct)
                    : (0, new PendingGems.ReleaseResult(0, 0, 0));
                var rolled = await RollBackAsync(connection, transaction, runId, run, verified, reason, next.StepNo, mismatchSeq,
                    options, now, ct);
                return rolled with { FloorsVerified = settled.Floors, GemsReleased = settled.Release.Gems, MarksClaimed = settled.Release.Claimed,
                    AlreadyPaid = settled.Release.AlreadyPaid };
            }

            var previousEnd = await EndHashAsync(connection, transaction, runId, verified, run.GenesisHash, ct);
            if (!string.Equals(previousEnd, next.StartHash, StringComparison.Ordinal))
            {
                (int Floors, PendingGems.ReleaseResult Release) settled = advanced
                    ? await SettleAsync(connection, transaction, runId, run, verified, now, ct)
                    : (0, new PendingGems.ReleaseResult(0, 0, 0));
                var rolled = await RollBackAsync(connection, transaction, runId, run, verified, StepMismatchReason.LinkBroken,
                    next.StepNo, next.ToSeq, options, now, ct);
                return rolled with { FloorsVerified = settled.Floors, GemsReleased = settled.Release.Gems, MarksClaimed = settled.Release.Claimed,
                    AlreadyPaid = settled.Release.AlreadyPaid };
            }

            verified = next.ToSeq;
            advanced = true;
            await ExecuteAsync(connection, transaction,
                "UPDATE runs SET verified_seq = $2 WHERE run_id = $1 AND verified_seq < $2", ct, runId, verified);
            if (FloorDigestOf(next.VerdictJson) is { } digest)
            {
                await ExecuteAsync(connection, transaction,
                    "UPDATE run_floors SET digest = $3::jsonb WHERE run_id = $1 AND floor = $2", ct, runId, digest.Floor, digest.Json);
            }
        }

        if (advanced)
        {
            (floorsVerified, released) = await SettleAsync(connection, transaction, runId, run, verified, now, ct);
        }

        var result = advanced ? "advanced" : "waiting";
        // A win needs its end step verified (the replay checked the run is actually won), not just a verified prefix: without
        // an end step there is nothing that proved the victory.
        if (run.Status == "Verifying" && run.EndSeq is { } endSeq && verified >= endSeq
            && await EndStepVerifiedAsync(connection, transaction, runId, endSeq, ct))
        {
            await ExecuteAsync(connection, transaction,
                "UPDATE runs SET status = 'Won', ended_at = $2 WHERE run_id = $1 AND status = 'Verifying'", ct, runId,
                now.ToUniversalTime());
            // The last floor is never left by a next_floor: the verified win is what verifies it.
            await ExecuteAsync(connection, transaction,
                "UPDATE run_floors SET end_seq = $2 WHERE run_id = $1 AND end_seq IS NULL AND verified_at IS NULL", ct, runId, endSeq);
            floorsVerified += await VerifyFloorsAsync(connection, transaction, runId, run, verified, now, ct);
            var (steps, floors) = await CountsAsync(connection, transaction, runId, ct);
            await WriteAsync(connection, transaction, run, runId, EventTypes.RunVerified, EventTopics.Run, now,
                new RunVerifiedPayload(runId.ToString("D"), RunStatus.Won, steps, floors), ct);
            statusChanged = true;
            result = "won";
        }

        return new AggregateResult(result, verified, floorsVerified, released.Gems, 0, statusChanged, MarksClaimed: released.Claimed,
            AlreadyPaid: released.AlreadyPaid);
    }

    /// <summary>The floors whose log is now inside the verified prefix, and the gems of the battles inside it.</summary>
    private static async Task<(int Floors, PendingGems.ReleaseResult Release)> SettleAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        Guid runId, RunRow run, int verified, DateTimeOffset now, CancellationToken ct) =>
        (await VerifyFloorsAsync(connection, transaction, runId, run, verified, now, ct),
            await PendingGems.ReleaseAsync(connection, transaction, runId, verified, now, ct));

    // ---- rollback and rejection (2.4) -----------------------------------------------------------------------------

    private static Task<AggregateResult> RollBackAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        RunRow run, int rollbackTo, StepMismatchReason reason, int stepNo, int seq, RunVerifyOptions options,
        DateTimeOffset now, CancellationToken ct)
    {
        // A run that is not in play cannot be resumed from a rollback; it just ends (a Lost run with a cheated step pays nothing).
        var terminal = run.Rollbacks + 1 > options.MaxRollbacks || run.Status is not ("Active" or "Verifying");
        return RollBackCoreAsync(connection, transaction, runId, run, rollbackTo, reason, stepNo, seq, terminal, "Step", now, ct);
    }

    /// <summary>A start that disagrees with the anchor: no rollback target exists, the run ends.</summary>
    private static Task<AggregateResult> EndRunAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        RunRow run, StepMismatchReason reason, int stepNo, int seq, string kind, DateTimeOffset now, CancellationToken ct) =>
        RollBackCoreAsync(connection, transaction, runId, run, 0, reason, stepNo, seq, true, kind, now, ct);

    private static async Task<AggregateResult> RollBackCoreAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        Guid runId, RunRow run, int rollbackTo, StepMismatchReason reason, int stepNo, int seq, bool terminal, string kind,
        DateTimeOffset now, CancellationToken ct)
    {
        // Gems first: it reads the battle sessions the next statements delete.
        var voidedGems = await PendingGems.VoidAsync(connection, transaction, runId, rollbackTo, reason.ToString(), now, ct);

        var voidedSeqs = new List<int>();
        await using (var select = new NpgsqlCommand(
            "SELECT run_seq FROM battle_sessions WHERE run_id = $1 AND run_seq > $2 ORDER BY run_seq", connection, transaction))
        {
            select.Parameters.Add(new NpgsqlParameter { Value = runId });
            select.Parameters.Add(new NpgsqlParameter { Value = rollbackTo });
            await using var reader = await select.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                voidedSeqs.Add(reader.GetInt32(0));
            }
        }

        var voidedBattles = await ExecuteCountAsync(connection, transaction,
            """
            INSERT INTO battle_sessions_voided (battle_id, run_id, run_seq, seed, ruleset_version, conditions, action_log, status,
              submitted_at, verdict, verified_at, verifier_version, attempts, dead_lettered_at, dead_letter_reason, epoch, voided_at)
            SELECT battle_id, run_id, run_seq, seed, ruleset_version, conditions, action_log, status, submitted_at, verdict,
              verified_at, verifier_version, attempts, dead_lettered_at, dead_letter_reason, $3, $4
            FROM battle_sessions WHERE run_id = $1 AND run_seq > $2
            """,
            ct, runId, rollbackTo, run.Epoch, now.ToUniversalTime());
        await ExecuteAsync(connection, transaction, "DELETE FROM battle_sessions WHERE run_id = $1 AND run_seq > $2", ct, runId, rollbackTo);
        var voidedActions = await ExecuteCountAsync(connection, transaction,
            """
            INSERT INTO run_actions_voided (run_id, seq, floor, type, action, state_hash, snapshot, played_at, received_at, epoch, voided_at)
            SELECT run_id, seq, floor, type, action, state_hash, snapshot, played_at, received_at, $3, $4
            FROM run_actions WHERE run_id = $1 AND seq > $2
            """, ct, runId, rollbackTo, run.Epoch, now.ToUniversalTime());
        await ExecuteAsync(connection, transaction, "DELETE FROM run_actions WHERE run_id = $1 AND seq > $2", ct, runId, rollbackTo);

        // The genesis step is the anchor, not part of the dropped log.
        await ExecuteAsync(connection, transaction,
            "UPDATE run_steps SET status = 'Voided' WHERE run_id = $1 AND to_seq > $2 AND kind <> 'genesis' AND status <> 'Voided'",
            ct, runId, rollbackTo);
        await ExecuteAsync(connection, transaction,
            // The digests stay: only steps inside the verified prefix write one, and the prefix is exactly what is kept.
            "UPDATE run_floors SET end_seq = NULL, verified_at = NULL WHERE run_id = $1 AND end_seq > $2", ct, runId, rollbackTo);

        var epoch = run.Epoch + 1;
        if (terminal)
        {
            await ExecuteAsync(connection, transaction,
                """
                UPDATE runs SET status = 'Rejected', epoch = $2, last_seq = LEAST(last_seq, $3), rollbacks = rollbacks + 1,
                  end_seq = NULL, ended_at = COALESCE(ended_at, $4), rollback_reason = $5 WHERE run_id = $1
                """, ct, runId, epoch, rollbackTo, now.ToUniversalTime(), CategoryOf(reason));
        }
        else
        {
            // The floor the player is on at the checkpoint: one per next_floor stored up to it.
            await ExecuteAsync(connection, transaction,
                """
                UPDATE runs SET status = 'Active', epoch = $2, last_seq = $3, rollbacks = rollbacks + 1, end_seq = NULL,
                  claimed_run_hash = NULL, ended_at = NULL, rollback_reason = $4,
                  current_floor = (SELECT count(*) FROM run_actions WHERE run_id = $1 AND type = 'next_floor' AND seq <= $3)
                WHERE run_id = $1
                """, ct, runId, epoch, rollbackTo, CategoryOf(reason));
        }

        await WriteAsync(connection, transaction, run, runId, EventTypes.RunRolledBack, EventTopics.Run, now,
            new RunRolledBackPayload(runId.ToString("D"), epoch, rollbackTo, stepNo, reason, voidedActions, voidedBattles, terminal), ct);
        await WriteAsync(connection, transaction, run, runId, EventTypes.AntiCheatAlert, EventTopics.Security, now,
            new AntiCheatAlertPayload(runId.ToString("D"), CategoryOf(reason), reason.ToString(), seq), ct);
        return new AggregateResult(terminal ? "rejected" : "rolled_back", rollbackTo, 0, 0, voidedGems, true, reason, stepNo,
            VoidedBattleSeqs: voidedSeqs);
    }

    /// <summary>The coarse reason a client is told (1108's <c>reason</c>) and the anti-cheat <c>kind</c>: a small fixed set.</summary>
    public static string CategoryOf(StepMismatchReason reason) => reason switch
    {
        StepMismatchReason.StateHashMismatch or StepMismatchReason.SnapshotHashMismatch or StepMismatchReason.GenesisMismatch
            or StepMismatchReason.NotWon => "StateMismatch",
        StepMismatchReason.ActionRefused or StepMismatchReason.ConditionsMismatch or StepMismatchReason.BattleMismatch
            or StepMismatchReason.WrongSetup => "Illegal",
        StepMismatchReason.ForeignSeed => "Seed",
        StepMismatchReason.LinkBroken => "Link",
        _ => "Malformed",
    };

    // ---- reads and small writes -----------------------------------------------------------------------------------

    private static async Task<RunRow?> LockAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        CancellationToken ct)
    {
        await using var select = new NpgsqlCommand(
            """
            SELECT player_id, status, epoch, verified_seq, end_seq, genesis_hash, ruleset_version, rollbacks, legacy, last_seq
            FROM runs WHERE run_id = $1 FOR UPDATE
            """, connection, transaction);
        select.Parameters.Add(new NpgsqlParameter { Value = runId });
        await using var reader = await select.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct)
            ? new RunRow(reader.GetGuid(0), reader.GetString(1), reader.GetInt32(2), reader.GetInt32(3),
                reader.IsDBNull(4) ? null : reader.GetInt32(4), reader.IsDBNull(5) ? null : reader.GetString(5),
                reader.GetString(6), reader.GetInt32(7), reader.GetBoolean(8), reader.GetInt32(9))
            : null;
    }

    private static async Task<string?> ClaimedHashAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        int seq, CancellationToken ct)
    {
        await using var select = new NpgsqlCommand("SELECT state_hash FROM run_actions WHERE run_id = $1 AND seq = $2",
            connection, transaction);
        select.Parameters.Add(new NpgsqlParameter { Value = runId });
        select.Parameters.Add(new NpgsqlParameter { Value = seq });
        return await select.ExecuteScalarAsync(ct) as string;
    }

    /// <summary>The step that starts at <paramref name="fromSeq"/>, the latest epoch's if several exist.</summary>
    private static async Task<StepRow?> NextStepAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        int fromSeq, CancellationToken ct)
    {
        await using var select = new NpgsqlCommand(
            """
            SELECT epoch, step_no, from_seq, to_seq, kind, status, start_hash, end_hash, verdict::text
            FROM run_steps WHERE run_id = $1 AND from_seq = $2 AND kind <> 'genesis' AND status <> 'Voided'
            ORDER BY epoch DESC, step_no DESC LIMIT 1
            """, connection, transaction);
        select.Parameters.Add(new NpgsqlParameter { Value = runId });
        select.Parameters.Add(new NpgsqlParameter { Value = fromSeq });
        await using var reader = await select.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct)
            ? new StepRow(reader.GetInt32(0), reader.GetInt32(1), reader.GetInt32(2), reader.GetInt32(3), reader.GetString(4),
                reader.GetString(5), reader.IsDBNull(6) ? null : reader.GetString(6),
                reader.IsDBNull(7) ? null : reader.GetString(7), reader.IsDBNull(8) ? null : reader.GetString(8))
            : null;
    }

    private static async Task<bool> EndStepVerifiedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        int endSeq, CancellationToken ct)
    {
        await using var select = new NpgsqlCommand(
            "SELECT 1 FROM run_steps WHERE run_id = $1 AND to_seq = $2 AND kind = 'end' AND status = 'Verified' LIMIT 1",
            connection, transaction);
        select.Parameters.Add(new NpgsqlParameter { Value = runId });
        select.Parameters.Add(new NpgsqlParameter { Value = endSeq });
        return await select.ExecuteScalarAsync(ct) is not null;
    }

    /// <summary>The reason a Rejected genesis step gives (the server's own rebuild failed), or null when it is not rejected.</summary>
    private static async Task<StepMismatchReason?> GenesisRejectedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        Guid runId, CancellationToken ct)
    {
        await using var select = new NpgsqlCommand(
            "SELECT verdict::text FROM run_steps WHERE run_id = $1 AND kind = 'genesis' AND status = 'Rejected' LIMIT 1",
            connection, transaction);
        select.Parameters.Add(new NpgsqlParameter { Value = runId });
        return await select.ExecuteScalarAsync(ct) is string verdict ? ReasonOf(verdict).Reason : null;
    }

    /// <summary>The verified end of the step that ended at <paramref name="seq"/> (the anchor for seq 1).</summary>
    private static async Task<string?> EndHashAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        int seq, string? genesisHash, CancellationToken ct)
    {
        if (seq == 1)
        {
            return genesisHash;
        }

        await using var select = new NpgsqlCommand(
            "SELECT end_hash FROM run_steps WHERE run_id = $1 AND to_seq = $2 AND status = 'Verified' ORDER BY epoch DESC LIMIT 1",
            connection, transaction);
        select.Parameters.Add(new NpgsqlParameter { Value = runId });
        select.Parameters.Add(new NpgsqlParameter { Value = seq });
        return await select.ExecuteScalarAsync(ct) as string;
    }

    private static async Task<int> VerifyFloorsAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid runId,
        RunRow run, int verified, DateTimeOffset now, CancellationToken ct)
    {
        var floors = new List<(int Floor, int EndSeq)>();
        await using (var update = new NpgsqlCommand(
            """
            UPDATE run_floors SET verified_at = $3
            WHERE run_id = $1 AND end_seq IS NOT NULL AND end_seq <= $2 AND verified_at IS NULL
            RETURNING floor, end_seq
            """, connection, transaction))
        {
            update.Parameters.Add(new NpgsqlParameter { Value = runId });
            update.Parameters.Add(new NpgsqlParameter { Value = verified });
            update.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            await using var reader = await update.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                floors.Add((reader.GetInt32(0), reader.GetInt32(1)));
            }
        }

        foreach (var (floor, endSeq) in floors.OrderBy(f => f.Floor))
        {
            await WriteAsync(connection, transaction, run, runId, EventTypes.FloorVerified, EventTopics.Run, now,
                new FloorVerifiedPayload(runId.ToString("D"), floor, endSeq, run.Epoch), ct);
        }

        return floors.Count;
    }

    private static async Task<(int Steps, int Floors)> CountsAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        Guid runId, CancellationToken ct)
    {
        await using var select = new NpgsqlCommand(
            """
            SELECT (SELECT count(*) FROM run_steps WHERE run_id = $1 AND status = 'Verified'),
                   (SELECT count(*) FROM run_floors WHERE run_id = $1 AND verified_at IS NOT NULL)
            """, connection, transaction);
        select.Parameters.Add(new NpgsqlParameter { Value = runId });
        await using var reader = await select.ExecuteReaderAsync(ct);
        await reader.ReadAsync(ct);
        return ((int)reader.GetInt64(0), (int)reader.GetInt64(1));
    }

    private static (StepMismatchReason Reason, int Seq) ReasonOf(string? verdictJson)
    {
        if (verdictJson is null)
        {
            return (StepMismatchReason.MalformedRequest, 0);
        }

        try
        {
            var verdict = JsonSerializer.Deserialize<StepVerdict>(verdictJson, RpgJson.Options);
            return verdict?.Mismatch is { } mismatch ? (mismatch.Reason, mismatch.Seq) : (StepMismatchReason.MalformedRequest, 0);
        }
        catch (JsonException)
        {
            return (StepMismatchReason.MalformedRequest, 0);
        }
    }

    /// <summary>The floor digest of a verified step, when it entered a floor (<c>floor</c> is read, the rest is opaque).</summary>
    private static (int Floor, string Json)? FloorDigestOf(string? verdictJson)
    {
        if (verdictJson is null)
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(verdictJson);
            return document.RootElement.TryGetProperty("floorDigest", out var digest)
                   && digest.ValueKind == JsonValueKind.Object
                   && digest.TryGetProperty("floor", out var floor) && floor.TryGetInt32(out var number)
                ? (number, digest.GetRawText())
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static Task WriteAsync<TPayload>(NpgsqlConnection connection, NpgsqlTransaction transaction, RunRow run, Guid runId,
        string type, string topic, DateTimeOffset now, TPayload payload, CancellationToken ct) =>
        EconomyEvents.WriteAsync(connection, transaction, run.PlayerId, runId, run.Ruleset, type, topic,
            run.PlayerId.ToString("D"), now, payload, ct);

    private static async Task ExecuteAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, string sql,
        CancellationToken ct, params object[] values) => await ExecuteCountAsync(connection, transaction, sql, ct, values);

    private static async Task<int> ExecuteCountAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, string sql,
        CancellationToken ct, params object[] values)
    {
        await using var command = new NpgsqlCommand(sql, connection, transaction);
        foreach (var value in values)
        {
            command.Parameters.Add(new NpgsqlParameter { Value = value });
        }

        return await command.ExecuteNonQueryAsync(ct);
    }
}
