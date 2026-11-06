using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Tests.Infrastructure;

namespace Rpg.GameServerApi.Tests;

/// <summary>Spec server-authority 3.4 and 6: the SQL migration runner.</summary>
[Collection(StackCollection.Name)]
public class MigrationTests(StackFixture stack)
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task Migrations_CreateSchema_ThenAreANoOp()
    {
        await using var dataSource = NpgsqlDataSource.Create(await stack.NewDatabaseAsync());

        await new MigrationRunner(dataSource, NullLogger<MigrationRunner>.Instance).EnsureMigratedAsync(Ct);
        await new MigrationRunner(dataSource, NullLogger<MigrationRunner>.Instance).EnsureMigratedAsync(Ct);

        Assert.Equal(MigrationRunner.Scripts.Select(s => s.Name), await AppliedAsync(dataSource));
        Assert.Equal(["battle_sessions", "completion_marks", "outbox", "players", "reward_cycle_resets", "reward_rules", "run_actions",
                "run_floors", "runs", "schema_migrations", "wallet_ledger", "wallets"],
            await TablesAsync(dataSource));
    }

    [Fact]
    public async Task Migration0006_MovesSlice4cData_ToChallengesTiersAndCycles_AndASecondApplyIsANoOp()
    {
        await using var dataSource = NpgsqlDataSource.Create(await stack.NewDatabaseAsync());
        var player = Guid.NewGuid();
        await using (var connection = await dataSource.OpenConnectionAsync(Ct))
        {
            // The schema as slice 4c left it: scripts 0001..0005, recorded as applied.
            await ExecuteAsync(connection, "CREATE TABLE schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL)");
            foreach (var (name, sql) in MigrationRunner.Scripts.Where(s => string.CompareOrdinal(s.Name, "0006") < 0))
            {
                await ExecuteAsync(connection, sql);
                await ExecuteAsync(connection, $"INSERT INTO schema_migrations (name, applied_at) VALUES ('{name}', now())");
            }

            // Slice 4c rows; the foreign keys are off for this session so the fixture needs no run or battle.
            await ExecuteAsync(connection, "SET session_replication_role = replica");
            await ExecuteAsync(connection, $"INSERT INTO players (player_id, display_name, created_at) VALUES ('{player}', 'p', now())");
            await ExecuteAsync(connection,
                """
                INSERT INTO reward_rules (source_kind, source_id, currency, amount, version, created_by) VALUES
                  ('boss', 'demo.enemy.lich', 'gems', 25, 1, 'seed'), ('boss', 'demo.enemy.lich', 'gems', 30, 2, 'designer'),
                  ('boss', 'demo.enemy.golem', 'gems', 0, 1, 'designer')
                """);
            await ExecuteAsync(connection,
                $"INSERT INTO completion_marks (player_id, character_id, boss_id, battle_id) VALUES ('{player}', 'warrior', 'demo.enemy.lich', 'b1')");
            await ExecuteAsync(connection,
                $"""
                INSERT INTO wallet_ledger (player_id, currency, delta, reason, ref_battle_id, idempotency_key, source_kind, source_id, rule_version) VALUES
                  ('{player}', 'gems', 30, 'completion_mark', 'b1', 'mark:b1:warrior:demo.enemy.lich', 'boss', 'demo.enemy.lich', 2),
                  ('{player}', 'gems', 10, 'completion_mark', 'b0', 'mark:b0:warrior:old', NULL, NULL, NULL)
                """);
            await ExecuteAsync(connection, "RESET session_replication_role");  // the connection goes back to the pool
        }

        await new MigrationRunner(dataSource, NullLogger<MigrationRunner>.Instance).EnsureMigratedAsync(Ct);
        await new MigrationRunner(dataSource, NullLogger<MigrationRunner>.Instance).EnsureMigratedAsync(Ct);

        Assert.Equal(["boss/demo.enemy.golem:1:1:0:once", "boss/demo.enemy.lich:1:1:25:once", "boss/demo.enemy.lich:2:1:30:once"],
            await ListAsync(dataSource,
                "SELECT challenge_id || ':' || version || ':' || tier || ':' || amount || ':' || cycle FROM reward_rules ORDER BY 1"));
        Assert.Equal(["boss/demo.enemy.lich:once:1"],
            await ListAsync(dataSource, "SELECT challenge_id || ':' || cycle_key || ':' || best_tier FROM completion_marks"));
        Assert.Equal(["-:-:-", "boss/demo.enemy.lich:2:-"],  // the older row has no challenge; tier and cycle stay null on both
            await ListAsync(dataSource,
                "SELECT COALESCE(challenge_id, '-') || ':' || COALESCE(rule_version::text, '-') || ':' || COALESCE(tier::text, '-') " +
                "FROM wallet_ledger ORDER BY 1"));
        Assert.Equal(["challenge_id", "character_id", "cycle_key", "player_id"],
            await ListAsync(dataSource,
                "SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey) " +
                "WHERE i.indrelid = 'completion_marks'::regclass AND i.indisprimary ORDER BY 1"));
        Assert.Equal(6, (await AppliedAsync(dataSource)).Count);
    }

    private static async Task ExecuteAsync(NpgsqlConnection connection, string sql)
    {
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync(Ct);
    }

    [Fact]
    public async Task Migrations_ConcurrentStart_RunOnce()
    {
        await using var dataSource = NpgsqlDataSource.Create(await stack.NewDatabaseAsync());

        // Separate runners stand for separate server instances: only the advisory lock keeps them apart.
        await Task.WhenAll(Enumerable.Range(0, 4).Select(_ =>
            new MigrationRunner(dataSource, NullLogger<MigrationRunner>.Instance).EnsureMigratedAsync(Ct)));

        Assert.Equal(MigrationRunner.Scripts.Select(s => s.Name), await AppliedAsync(dataSource));
    }

    [Fact]
    public void Scripts_AreEmbedded_InNameOrder()
    {
        Assert.Equal("0001_runs.sql", MigrationRunner.Scripts[0].Name);
        Assert.Equal(MigrationRunner.Scripts.Select(s => s.Name).Order(StringComparer.Ordinal),
            MigrationRunner.Scripts.Select(s => s.Name));
    }

    private static async Task<List<string>> AppliedAsync(NpgsqlDataSource dataSource) =>
        await ListAsync(dataSource, "SELECT name FROM schema_migrations ORDER BY name");

    private static async Task<List<string>> TablesAsync(NpgsqlDataSource dataSource) =>
        await ListAsync(dataSource,
            "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name");

    private static async Task<List<string>> ListAsync(NpgsqlDataSource dataSource, string sql)
    {
        await using var command = dataSource.CreateCommand(sql);
        await using var reader = await command.ExecuteReaderAsync(Ct);
        var names = new List<string>();
        while (await reader.ReadAsync(Ct))
        {
            names.Add(reader.GetString(0));
        }

        return names;
    }
}
