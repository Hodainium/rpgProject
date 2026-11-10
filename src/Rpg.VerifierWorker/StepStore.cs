using System.Text.Json;
using Npgsql;
using NpgsqlTypes;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;
using Rpg.Economy;

namespace Rpg.VerifierWorker;

/// <summary>A step and the run it belongs to, as the worker needs them.</summary>
public sealed record StepRow(Guid RunId, int Epoch, int StepNo, int FromSeq, int ToSeq, string Kind, string Status, int Attempts,
    Guid PlayerId, string RunStatus, int RunEpoch, string Ruleset, string StructureId, string[] CharacterIds, int LastSeq,
    DateTimeOffset CreatedAt, string? CardPoolJson = null);   // CardPoolJson: runs.card_pool, fixed at run start (spec card-collection 2.5)

/// <summary>
/// What a step needs to run: the request JSON and the battle sessions it contains (for their verdicts). <see cref="StepStore.BuildAsync"/>
/// returns null while a step is not ready (step 1 starts from the server's own start snapshot, which the genesis job writes).
/// </summary>
public sealed record StepInput(string RequestJson, IReadOnlyDictionary<string, BattleRow> Battles);

/// <param name="Committed">False: the step was decided already (or voided); nothing changed.</param>
/// <param name="Aggregate">What the aggregator did in the same transaction.</param>
/// <param name="Settlements">One per battle the step committed.</param>
public sealed record StepCommit(bool Committed, AggregateResult? Aggregate, IReadOnlyList<CommitResult> Settlements,
    IReadOnlyList<BattleRow> Battles);

/// <summary>
/// The worker's Postgres access for steps (spec run-verify 2.2, 2.3). The step verdict is a guarded
/// <c>UPDATE … WHERE status = 'Pending'</c>: that conditional update, not a lock, is what makes redelivery a no-op. The
/// battle verdicts, their pending settlement, the aggregator and the events all share its transaction.
/// </summary>
public sealed class StepStore(NpgsqlDataSource dataSource)
{
    public async Task<StepRow?> LoadAsync(Guid runId, int epoch, int stepNo, CancellationToken ct)
    {
        await using var command = dataSource.CreateCommand(
            """
            SELECT s.run_id, s.epoch, s.step_no, s.from_seq, s.to_seq, s.kind, s.status, s.attempts, r.player_id, r.status,
                   r.epoch, r.ruleset_version, r.run_structure_id, r.character_ids, r.last_seq, s.created_at, r.card_pool::text
            FROM run_steps s JOIN runs r ON r.run_id = s.run_id
            WHERE s.run_id = $1 AND s.epoch = $2 AND s.step_no = $3
            """);
        command.Parameters.Add(new NpgsqlParameter { Value = runId });
        command.Parameters.Add(new NpgsqlParameter { Value = epoch });
        command.Parameters.Add(new NpgsqlParameter { Value = stepNo });
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct)
            ? new StepRow(reader.GetGuid(0), reader.GetInt32(1), reader.GetInt32(2), reader.GetInt32(3), reader.GetInt32(4),
                reader.GetString(5), reader.GetString(6), reader.GetInt32(7), reader.GetGuid(8), reader.GetString(9),
                reader.GetInt32(10), reader.GetString(11), reader.GetString(12), reader.GetFieldValue<string[]>(13),
                reader.GetInt32(14), reader.GetFieldValue<DateTimeOffset>(15), reader.IsDBNull(16) ? null : reader.GetString(16))
            : null;
    }

    /// <summary>
    /// Builds the <see cref="StepRequest"/> from Postgres alone (spec run-verify 3.3): the setup and the floor seeds are the
    /// server's, the snapshot, the actions and the hashes are the claims being verified.
    /// </summary>
    public async Task<StepInput?> BuildAsync(StepRow step, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        var seeds = new Dictionary<int, string>();
        await using (var select = new NpgsqlCommand("SELECT floor, floor_seed FROM run_floors WHERE run_id = $1 ORDER BY floor", connection))
        {
            select.Parameters.Add(new NpgsqlParameter { Value = step.RunId });
            await using var reader = await select.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                seeds[reader.GetInt32(0)] = reader.GetInt64(1).ToString();
            }
        }

        // Spec card-collection 2.5: the run's item pool was fixed at run start and comes from `runs` (with the step's own row, no
        // second query), never from the client.
        IReadOnlyList<string>? cardPool = step.CardPoolJson is { } pool ? JsonSerializer.Deserialize<List<string>>(pool, RpgJson.Options) : null;

        var kind = Enum.Parse<StepKind>(step.Kind, ignoreCase: true);
        JsonElement? startSnapshot = null;
        string? startHash = null;
        var actions = new List<RunActionRequest>();
        var battles = new Dictionary<string, BattleRow>();
        string? endRunHash = null;
        if (kind != StepKind.Genesis)
        {
            await using (var select = new NpgsqlCommand(
                "SELECT snapshot::text, state_hash FROM run_actions WHERE run_id = $1 AND seq = $2", connection))
            {
                select.Parameters.Add(new NpgsqlParameter { Value = step.RunId });
                select.Parameters.Add(new NpgsqlParameter { Value = step.FromSeq });
                await using var reader = await select.ExecuteReaderAsync(ct);
                if (await reader.ReadAsync(ct))
                {
                    startSnapshot = reader.IsDBNull(0) ? null : Parse(reader.GetString(0));
                    startHash = reader.GetString(1);
                }
            }

            if (step.FromSeq == 1)
            {
                // Step 1 starts from the server's own copy of the start, never the client's: the client's seq 1 snapshot may differ
                // from it on fields the run hash does not cover. (Until the genesis job has written it, the step is not ready.)
                await using var genesis = new NpgsqlCommand("SELECT genesis_snapshot::text FROM runs WHERE run_id = $1", connection);
                genesis.Parameters.Add(new NpgsqlParameter { Value = step.RunId });
                if (await genesis.ExecuteScalarAsync(ct) is not string own)
                {
                    return null;
                }

                startSnapshot = Parse(own);
            }



            await using (var select = new NpgsqlCommand(
                """
                SELECT a.seq, a.action::text, a.state_hash, a.played_at, b.battle_id, b.conditions::text, b.action_log::text,
                       b.status, b.run_seq, b.submitted_at, b.attempts, b.ruleset_version
                FROM run_actions a LEFT JOIN battle_sessions b ON b.run_id = a.run_id AND b.run_seq = a.seq
                WHERE a.run_id = $1 AND a.seq > $2 AND a.seq <= $3 ORDER BY a.seq
                """, connection))
            {
                select.Parameters.Add(new NpgsqlParameter { Value = step.RunId });
                select.Parameters.Add(new NpgsqlParameter { Value = step.FromSeq });
                select.Parameters.Add(new NpgsqlParameter { Value = step.ToSeq });
                await using var reader = await select.ExecuteReaderAsync(ct);
                while (await reader.ReadAsync(ct))
                {
                    var action = JsonSerializer.Deserialize<RunAction>(reader.GetString(1), RpgJson.Options)!;
                    if (!reader.IsDBNull(4))
                    {
                        var conditionsJson = reader.GetString(5);
                        var logJson = reader.GetString(6);
                        action = action with
                        {
                            Battle = new BattleSubmission(reader.GetString(4),
                                JsonSerializer.Deserialize<BattleSnapshot>(conditionsJson, RpgJson.Options)!,
                                JsonSerializer.Deserialize<ActionLog>(logJson, RpgJson.Options)!),
                        };
                        battles[reader.GetString(4)] = new BattleRow(reader.GetString(4), step.RunId, reader.GetInt32(8),
                            step.PlayerId, reader.GetString(7), reader.GetString(11), conditionsJson, logJson,
                            reader.GetFieldValue<DateTimeOffset>(9), reader.GetInt32(10));
                    }

                    actions.Add(new RunActionRequest(reader.GetInt32(0), action, reader.GetString(2),
                        reader.GetFieldValue<DateTimeOffset>(3)));
                    if (kind == StepKind.End && reader.GetInt32(0) == step.ToSeq)
                    {
                        endRunHash = reader.GetString(2);
                    }
                }
            }
        }

        var request = new StepRequest(1, step.RunId.ToString("D"), step.StructureId, step.CharacterIds, seeds, step.FromSeq,
            step.ToSeq, kind, startSnapshot, startHash, actions, endRunHash, cardPool);
        return new StepInput(JsonSerializer.Serialize(request, RpgJson.Options), battles);
    }

    /// <summary>
    /// The verdict, the battles' verdicts and pending settlements, the aggregator and its events, in ONE transaction.
    /// </summary>
    public async Task<StepCommit> CommitAsync(StepRow step, StepVerdict verdict, StepInput input, SettlementOptions settlement,
        RunVerifyOptions verify, DateTimeOffset now, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);

        // The run row first, as the API does (its uploads and rollbacks lock runs and then touch the steps): the same order on
        // both sides is what keeps the two from deadlocking.
        await using (var lockRun = new NpgsqlCommand("SELECT 1 FROM runs WHERE run_id = $1 FOR UPDATE", connection, transaction))
        {
            lockRun.Parameters.Add(new NpgsqlParameter { Value = step.RunId });
            await lockRun.ExecuteScalarAsync(ct);
        }

        var verified = verdict.Status == ReplayVerdict.Verified;
        await using (var update = new NpgsqlCommand(
            """
            UPDATE run_steps
            SET status = $4, verdict = $5, start_hash = $6, end_hash = $7, verified_at = $8, attempts = attempts + 1
            WHERE run_id = $1 AND epoch = $2 AND step_no = $3 AND status = 'Pending'
            """, connection, transaction))
        {
            update.Parameters.Add(new NpgsqlParameter { Value = step.RunId });
            update.Parameters.Add(new NpgsqlParameter { Value = step.Epoch });
            update.Parameters.Add(new NpgsqlParameter { Value = step.StepNo });
            update.Parameters.Add(new NpgsqlParameter { Value = verified ? "Verified" : "Rejected" });
            update.Parameters.Add(new NpgsqlParameter
            {
                NpgsqlDbType = NpgsqlDbType.Jsonb, Value = JsonSerializer.Serialize(verdict, RpgJson.Options),
            });
            update.Parameters.Add(new NpgsqlParameter { Value = (object?)NullIfEmpty(verdict.StartHash) ?? DBNull.Value });
            update.Parameters.Add(new NpgsqlParameter { Value = (object?)NullIfEmpty(verdict.EndHash) ?? DBNull.Value });
            update.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            if (await update.ExecuteNonQueryAsync(ct) != 1)
            {
                await transaction.RollbackAsync(CancellationToken.None);
                return new StepCommit(false, null, [], []);
            }
        }

        if (step.Kind == "genesis" && verified && verdict.EndSnapshot is { } snapshot)
        {
            await using var genesis = new NpgsqlCommand(
                "UPDATE runs SET genesis_hash = $2, genesis_snapshot = $3 WHERE run_id = $1 AND genesis_hash IS NULL",
                connection, transaction);
            genesis.Parameters.Add(new NpgsqlParameter { Value = step.RunId });
            genesis.Parameters.Add(new NpgsqlParameter { Value = verdict.EndHash });
            genesis.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Jsonb, Value = snapshot.GetRawText() });
            await genesis.ExecuteNonQueryAsync(ct);
        }

        var settlements = new List<CommitResult>();
        var decided = new List<BattleRow>();
        foreach (var result in verdict.Battles)
        {
            if (!input.Battles.TryGetValue(result.BattleId, out var row))
            {
                continue;
            }

            var battleVerdict = new BattleVerdict(result.Verdict, result.ErrorCode, result.Error, result.Mismatch, result.Outcome,
                result.Turns, result.FinalStateHash, verdict.VerifierRulesetVersion, result.EngineVersion, now, result.Facts);
            var commit = await VerdictStore.CommitInTransactionAsync(connection, transaction, row, battleVerdict, settlement, now,
                pending: true, ct);
            if (commit.Committed)
            {
                settlements.Add(commit);
                decided.Add(row);
            }
        }

        var aggregate = await RunAggregator.RunAsync(connection, transaction, step.RunId, verify, now, ct);
        await transaction.CommitAsync(ct);
        return new StepCommit(true, aggregate, settlements, decided);
    }

    /// <summary>Counts one runner error; returns the attempts so far.</summary>
    /// <summary>
    /// Whether step 1 should keep waiting for the start snapshot: the genesis step is Pending and not dead-lettered, or
    /// the snapshot has arrived since step 1 looked (genesis committed in between: retry at once). False when genesis is
    /// dead-lettered, or done (Verified, Rejected or Voided) without the snapshot being there.
    /// </summary>
    public async Task<bool> GenesisCanStillCompleteAsync(Guid runId, CancellationToken ct)
    {
        await using var command = dataSource.CreateCommand(
            """
            SELECT EXISTS (SELECT 1 FROM run_steps
                           WHERE run_id = $1 AND kind = 'genesis' AND status = 'Pending' AND dead_lettered_at IS NULL)
                OR EXISTS (SELECT 1 FROM runs WHERE run_id = $1 AND genesis_snapshot IS NOT NULL)
            """);
        command.Parameters.Add(new NpgsqlParameter { Value = runId });
        return await command.ExecuteScalarAsync(ct) is true;
    }

    public async Task<int> RecordAttemptAsync(Guid runId, int epoch, int stepNo, CancellationToken ct)
    {
        await using var command = dataSource.CreateCommand(
            "UPDATE run_steps SET attempts = attempts + 1 WHERE run_id = $1 AND epoch = $2 AND step_no = $3 RETURNING attempts");
        command.Parameters.Add(new NpgsqlParameter { Value = runId });
        command.Parameters.Add(new NpgsqlParameter { Value = epoch });
        command.Parameters.Add(new NpgsqlParameter { Value = stepNo });
        return await command.ExecuteScalarAsync(ct) is int attempts ? attempts : 0;
    }

    /// <summary>Marks the step dead-lettered: it stays Pending, the gate holds, a human requeues (spec run-verify 4 F8).</summary>
    public async Task DeadLetterAsync(Guid runId, int epoch, int stepNo, string reason, DateTimeOffset now, CancellationToken ct)
    {
        await using var command = dataSource.CreateCommand(
            """
            UPDATE run_steps SET dead_lettered_at = $4, dead_letter_reason = $5
            WHERE run_id = $1 AND epoch = $2 AND step_no = $3 AND status = 'Pending'
            """);
        command.Parameters.Add(new NpgsqlParameter { Value = runId });
        command.Parameters.Add(new NpgsqlParameter { Value = epoch });
        command.Parameters.Add(new NpgsqlParameter { Value = stepNo });
        command.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
        command.Parameters.Add(new NpgsqlParameter { Value = reason });
        await command.ExecuteNonQueryAsync(ct);
    }

    /// <summary>A step the run no longer needs (abandoned before it ran, or the run ended): no Godot run, no verdict.</summary>
    public async Task VoidAsync(Guid runId, int epoch, int stepNo, CancellationToken ct)
    {
        await using var command = dataSource.CreateCommand(
            "UPDATE run_steps SET status = 'Voided' WHERE run_id = $1 AND epoch = $2 AND step_no = $3 AND status = 'Pending'");
        command.Parameters.Add(new NpgsqlParameter { Value = runId });
        command.Parameters.Add(new NpgsqlParameter { Value = epoch });
        command.Parameters.Add(new NpgsqlParameter { Value = stepNo });
        await command.ExecuteNonQueryAsync(ct);
    }

    private static string? NullIfEmpty(string value) => value.Length == 0 ? null : value;

    private static JsonElement Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }
}
