using Npgsql;

namespace Rpg.GameServerApi.Runs;

/// <summary>Spec battle-verify 5: the gauge query on <c>battle_sessions</c>. (The sweeper left with the outbox, spec settlement-outbox 2.1.)</summary>
public sealed partial class RunStore
{
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
