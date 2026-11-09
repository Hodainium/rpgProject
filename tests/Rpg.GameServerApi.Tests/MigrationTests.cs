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
        Assert.Equal(["account_requests", "battle_sessions", "battle_sessions_voided", "card_holdings", "card_ledger", "card_rates",
                "cards", "catalog_versions", "completion_marks", "outbox", "pack_openings", "pack_pity", "pack_types", "players",
                "reward_cycle_resets", "reward_rules", "run_actions", "run_actions_voided", "run_floors", "run_steps", "runs",
                "schema_migrations", "wallet_ledger", "wallets"],
            await TablesAsync(dataSource));
    }

    [Fact]
    public async Task Migration0006_MovesSlice4cData_ToChallengesAndCycles_AndASecondApplyIsANoOp()
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

        Assert.Equal(["boss/demo.enemy.golem:1:0:once", "boss/demo.enemy.lich:1:25:once", "boss/demo.enemy.lich:2:30:once"],
            await ListAsync(dataSource,
                "SELECT challenge_id || ':' || version || ':' || amount || ':' || cycle FROM reward_rules ORDER BY 1"));
        Assert.Equal(["boss/demo.enemy.lich:once"],
            await ListAsync(dataSource, "SELECT challenge_id || ':' || cycle_key FROM completion_marks"));
        Assert.Equal(["-:-:-", "boss/demo.enemy.lich:2:-"],  // the older row has no challenge; the cycle key is null on both
            await ListAsync(dataSource,
                "SELECT COALESCE(challenge_id, '-') || ':' || COALESCE(rule_version::text, '-') || ':' || COALESCE(cycle_key, '-') " +
                "FROM wallet_ledger ORDER BY 1"));
        Assert.Equal(["challenge_id", "character_id", "cycle_key", "player_id"],
            await ListAsync(dataSource,
                "SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey) " +
                "WHERE i.indrelid = 'completion_marks'::regclass AND i.indisprimary ORDER BY 1"));
        Assert.Equal(MigrationRunner.Scripts.Count, (await AppliedAsync(dataSource)).Count);
    }

    [Fact]
    public async Task Migration0007_MarksTheRunsThatExist_Legacy_AndReleasesTheirLedgerRows()
    {
        await using var dataSource = NpgsqlDataSource.Create(await stack.NewDatabaseAsync());
        var player = Guid.NewGuid();
        var run = Guid.NewGuid();
        await using (var connection = await dataSource.OpenConnectionAsync(Ct))
        {
            // The schema as slice 4d left it: scripts 0001..0006, recorded as applied, with a run, an action and a paid mark.
            await ExecuteAsync(connection, "CREATE TABLE schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL)");
            foreach (var (name, sql) in MigrationRunner.Scripts.Where(s => string.CompareOrdinal(s.Name, "0007") < 0))
            {
                await ExecuteAsync(connection, sql);
                await ExecuteAsync(connection, $"INSERT INTO schema_migrations (name, applied_at) VALUES ('{name}', now())");
            }

            await ExecuteAsync(connection, $"INSERT INTO players (player_id, display_name, created_at) VALUES ('{player}', 'p', now())");
            await ExecuteAsync(connection,
                $"INSERT INTO runs (run_id, player_id, ruleset_version, run_structure_id, character_ids, status, started_at) " +
                $"VALUES ('{run}', '{player}', 'r', 's', '{{a}}', 'Active', now())");
            await ExecuteAsync(connection,
                $"INSERT INTO wallet_ledger (player_id, currency, delta, reason, ref_battle_id, idempotency_key) " +
                $"VALUES ('{player}', 'gems', 10, 'completion_mark', 'b1', 'mark:b1:a:boss/x')");
            await ExecuteAsync(connection, $"INSERT INTO wallets (player_id, gems, version) VALUES ('{player}', 10, 1)");
        }

        await new MigrationRunner(dataSource, NullLogger<MigrationRunner>.Instance).EnsureMigratedAsync(Ct);
        await new MigrationRunner(dataSource, NullLogger<MigrationRunner>.Instance).EnsureMigratedAsync(Ct);   // a no-op

        Assert.Equal(["true:0:0"], await ListAsync(dataSource, "SELECT legacy || ':' || epoch || ':' || verified_seq FROM runs"));
        Assert.Equal(["released:true"], await ListAsync(dataSource,
            "SELECT status || ':' || (released_at IS NOT NULL) FROM wallet_ledger"));   // slice 4 settled it
        await using (var connection = await dataSource.OpenConnectionAsync(Ct))
        {
            // A run started after the migration verifies, and the ledger invariant counts released rows only.
            await ExecuteAsync(connection,
                $"INSERT INTO runs (run_id, player_id, ruleset_version, run_structure_id, character_ids, status, started_at) " +
                $"VALUES ('{Guid.NewGuid()}', '{player}', 'r', 's', '{{a}}', 'Abandoned', now())");
            await ExecuteAsync(connection,
                $"INSERT INTO wallet_ledger (player_id, currency, delta, reason, idempotency_key, status) " +
                $"VALUES ('{player}', 'gems', 5, 'completion_mark', 'k2', 'pending')");
        }

        Assert.Equal(["false", "true"], await ListAsync(dataSource, "SELECT legacy::text FROM runs ORDER BY legacy"));
        Assert.Equal(["10"], await ListAsync(dataSource,
            $"SELECT COALESCE(sum(delta), 0)::text FROM wallet_ledger WHERE player_id = '{player}' AND status = 'released'"));
        var badStatus = await Assert.ThrowsAsync<PostgresException>(async () =>
        {
            await using var connection = await dataSource.OpenConnectionAsync(Ct);
            await ExecuteAsync(connection,
                $"INSERT INTO wallet_ledger (player_id, currency, delta, reason, idempotency_key, status) " +
                $"VALUES ('{player}', 'gems', 1, 'x', 'k3', 'maybe')");
        });
        Assert.Equal(PostgresErrorCodes.CheckViolation, badStatus.SqlState);
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
