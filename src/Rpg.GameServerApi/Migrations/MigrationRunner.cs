using System.Reflection;
using Npgsql;

namespace Rpg.GameServerApi.Migrations;

/// <summary>
/// Applies the embedded <c>Migrations/NNNN_name.sql</c> files in order (spec server-authority 3.4). Everything runs
/// in one transaction under <c>pg_advisory_xact_lock</c>, so two instances starting together never migrate twice:
/// the second waits, then finds nothing left to do. Applied files are recorded in <c>schema_migrations</c>.
/// </summary>
public sealed class MigrationRunner(NpgsqlDataSource dataSource, ILogger<MigrationRunner> logger)
{
    /// <summary>Any constant shared by every instance; "rpg-migr" in ASCII.</summary>
    private const long LockKey = 0x7270672D6D696772;

    private readonly SemaphoreSlim _gate = new(1, 1);
    private volatile bool _done;

    /// <summary>The embedded migration scripts as (name, sql), sorted by name.</summary>
    public static IReadOnlyList<(string Name, string Sql)> Scripts { get; } = LoadScripts();

    /// <summary>Migrates once per process; later calls return at once. Throws NpgsqlException when Postgres is down.</summary>
    public async Task EnsureMigratedAsync(CancellationToken ct)
    {
        if (_done)
        {
            return;
        }

        await _gate.WaitAsync(ct);
        try
        {
            if (!_done)
            {
                await MigrateAsync(ct);
                _done = true;
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task MigrateAsync(CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        await Execute(connection, transaction, $"SELECT pg_advisory_xact_lock({LockKey})", ct);
        await Execute(connection, transaction,
            "CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL)", ct);

        var applied = new HashSet<string>();
        await using (var select = new NpgsqlCommand("SELECT name FROM schema_migrations", connection, transaction))
        await using (var reader = await select.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                applied.Add(reader.GetString(0));
            }
        }

        foreach (var (name, sql) in Scripts.Where(script => !applied.Contains(script.Name)))
        {
            await Execute(connection, transaction, sql, ct);
            await using var record = new NpgsqlCommand(
                "INSERT INTO schema_migrations (name, applied_at) VALUES ($1, now())", connection, transaction);
            record.Parameters.Add(new NpgsqlParameter { Value = name });
            await record.ExecuteNonQueryAsync(ct);
            logger.LogInformation("Applied migration {Migration}", name);
        }

        await transaction.CommitAsync(ct);
    }

    private static async Task Execute(NpgsqlConnection connection, NpgsqlTransaction transaction, string sql,
        CancellationToken ct)
    {
        await using var command = new NpgsqlCommand(sql, connection, transaction);
        await command.ExecuteNonQueryAsync(ct);
    }

    private static List<(string Name, string Sql)> LoadScripts()
    {
        var assembly = Assembly.GetExecutingAssembly();
        const string prefix = "Rpg.GameServerApi.Migrations.";
        return assembly.GetManifestResourceNames()
            .Where(name => name.StartsWith(prefix, StringComparison.Ordinal) && name.EndsWith(".sql", StringComparison.Ordinal))
            .Order(StringComparer.Ordinal)
            .Select(name =>
            {
                using var stream = assembly.GetManifestResourceStream(name)!;
                using var reader = new StreamReader(stream);
                return (name[prefix.Length..], reader.ReadToEnd());
            })
            .ToList();
    }
}

/// <summary>
/// Migrates at startup without blocking it (the server must start while Postgres is down): retries in the
/// background until it succeeds. Requests also call <see cref="MigrationRunner.EnsureMigratedAsync"/> first, so the
/// first request after Postgres comes back migrates if this loop hasn't yet.
/// </summary>
public sealed class StartupMigration(MigrationRunner runner, ILogger<StartupMigration> logger) : BackgroundService
{
    private static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(5);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await runner.EnsureMigratedAsync(stoppingToken);
                return;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning("Migrations not applied ({Message}); retrying in {Interval}", ex.Message, RetryInterval);
                await Task.Delay(RetryInterval, stoppingToken);
            }
        }
    }
}
