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
        Assert.Equal(["battle_sessions", "players", "run_actions", "run_floors", "runs", "schema_migrations"],
            await TablesAsync(dataSource));
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
