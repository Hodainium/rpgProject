using Npgsql;
using Rpg.Contracts.Battle;

namespace Rpg.GameServerApi.Runs;

/// <summary>Publishes a job and reports whether the broker confirmed it.</summary>
public delegate Task<bool> PublishJob(VerifyBattleJob job, CancellationToken ct);

/// <summary>Spec battle-verify 2.4, 5: the job bookkeeping on <c>battle_sessions</c> (the sweeper and the gauges).</summary>
public sealed partial class RunStore
{
    /// <summary>Records a confirmed publish (a later sweep leaves the row alone for <c>RepublishAfter</c>).</summary>
    public async Task MarkEnqueuedAsync(string battleId, DateTimeOffset now, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand(
            "UPDATE battle_sessions SET enqueued_at = $2 WHERE battle_id = $1 AND status = 'Submitted'");
        command.Parameters.Add(new NpgsqlParameter { Value = battleId });
        command.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
        await command.ExecuteNonQueryAsync(ct);
    }

    /// <summary>
    /// The reconciler (2.4). It leases up to <paramref name="limit"/> sessions that are still Submitted, not
    /// dead-lettered, older than <paramref name="grace"/> (the upload's own fast path gets that long) and never enqueued
    /// or, only when <paramref name="republishStale"/>, last enqueued before <paramref name="republishAfter"/>: one short <c>UPDATE ... RETURNING</c> stamps
    /// <c>enqueued_at</c> (<c>FOR UPDATE SKIP LOCKED</c>, so two API instances never lease the same row), then the jobs
    /// are published with no lock or transaction held. A job that could not be published gets its lease cleared, so the
    /// next sweep takes it again.
    /// </summary>
    public async Task<(int Published, int Failed)> SweepUnenqueuedAsync(PublishJob publish, int limit,
        TimeSpan republishAfter, bool republishStale, TimeSpan grace, DateTimeOffset now, CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        var jobs = new List<VerifyBattleJob>();
        await using (var lease = dataSource.CreateCommand(
            """
            UPDATE battle_sessions SET enqueued_at = $1
            WHERE battle_id IN (
              SELECT battle_id FROM battle_sessions
              WHERE status = 'Submitted' AND dead_lettered_at IS NULL AND submitted_at < $2
                AND (enqueued_at IS NULL OR ($5 AND enqueued_at < $3))
              ORDER BY submitted_at
              LIMIT $4
              FOR UPDATE SKIP LOCKED)
            RETURNING battle_id, run_id, run_seq, ruleset_version, submitted_at
            """))
        {
            lease.Parameters.Add(new NpgsqlParameter { Value = now.ToUniversalTime() });
            lease.Parameters.Add(new NpgsqlParameter { Value = (now - grace).ToUniversalTime() });
            lease.Parameters.Add(new NpgsqlParameter { Value = (now - republishAfter).ToUniversalTime() });
            lease.Parameters.Add(new NpgsqlParameter { Value = limit });
            lease.Parameters.Add(new NpgsqlParameter { Value = republishStale });
            await using var reader = await lease.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                jobs.Add(new VerifyBattleJob(reader.GetString(0), reader.GetGuid(1), reader.GetInt32(2),
                    reader.GetString(3), reader.GetFieldValue<DateTimeOffset>(4)));
            }
        }

        jobs.Sort((x, y) => x.SubmittedAt.CompareTo(y.SubmittedAt));
        var published = 0;
        try
        {
            foreach (var job in jobs)
            {
                if (!await publish(job, ct))
                {
                    break;  // the broker is unreachable: this job and the rest wait for the next sweep
                }

                published++;
            }
        }
        finally
        {
            // A failed publish, a throw or a cancelled sweep (shutdown): give back the lease of everything not published,
            // so the next sweep takes it again instead of waiting out RepublishAfter.
            if (published < jobs.Count)
            {
                var unpublished = jobs.Skip(published).Select(j => j.BattleId).ToArray();
                await using var release = dataSource.CreateCommand(
                    "UPDATE battle_sessions SET enqueued_at = NULL WHERE battle_id = ANY($1) AND status = 'Submitted'");
                release.Parameters.Add(new NpgsqlParameter { Value = unpublished });
                await release.ExecuteNonQueryAsync(CancellationToken.None);
            }
        }

        return (published, jobs.Count - published);
    }

    /// <summary>Submitted, not dead-lettered sessions: how many, and when the oldest was submitted.</summary>
    public async Task<(long Count, DateTimeOffset? Oldest)> UnverifiedAsync(CancellationToken ct)
    {
        await migrations.EnsureMigratedAsync(ct);
        await using var command = dataSource.CreateCommand(
            "SELECT count(*), min(submitted_at) FROM battle_sessions WHERE status = 'Submitted' AND dead_lettered_at IS NULL");
        await using var reader = await command.ExecuteReaderAsync(ct);
        await reader.ReadAsync(ct);
        return (reader.GetInt64(0), reader.IsDBNull(1) ? null : reader.GetFieldValue<DateTimeOffset>(1));
    }
}
