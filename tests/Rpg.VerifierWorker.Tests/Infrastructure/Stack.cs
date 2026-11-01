using Npgsql;
using Testcontainers.PostgreSql;
using Testcontainers.RabbitMq;
using Testcontainers.Redis;

namespace Rpg.VerifierWorker.Tests.Infrastructure;

/// <summary>
/// Real Postgres, Redis and RabbitMQ in Docker, the same images as infra/docker-compose.yml. Docker is required: these
/// tests fail (not skip) without it, like the server's.
/// </summary>
public sealed class Stack : IAsyncLifetime
{
    public PostgreSqlContainer Postgres { get; } = new PostgreSqlBuilder("postgres:16-alpine").Build();
    public RedisContainer Redis { get; } = new RedisBuilder("redis:7-alpine").Build();
    public RabbitMqContainer RabbitMq { get; } = new RabbitMqBuilder("rabbitmq:4.1-management-alpine")
        .WithPortBinding(15672, true).Build();  // the management API: the topology test reads queue arguments

    public string RedisConnectionString => Redis.GetConnectionString() + ",abortConnect=false";

    public async ValueTask InitializeAsync() =>
        await Task.WhenAll(Postgres.StartAsync(), Redis.StartAsync(), RabbitMq.StartAsync());

    public async ValueTask DisposeAsync()
    {
        await Postgres.DisposeAsync();
        await Redis.DisposeAsync();
        await RabbitMq.DisposeAsync();
    }

    /// <summary>A new empty database in the shared Postgres container; returns its connection string.</summary>
    public async Task<string> NewDatabaseAsync()
    {
        var name = "t_" + Guid.NewGuid().ToString("N");
        await using (var admin = new NpgsqlConnection(Postgres.GetConnectionString()))
        {
            await admin.OpenAsync();
            await using var create = new NpgsqlCommand($"CREATE DATABASE {name}", admin);
            await create.ExecuteNonQueryAsync();
        }

        return new NpgsqlConnectionStringBuilder(Postgres.GetConnectionString()) { Database = name }.ConnectionString;
    }
}

[CollectionDefinition(Name)]
public sealed class StackCollection : ICollectionFixture<Stack>
{
    public const string Name = "stack";
}
