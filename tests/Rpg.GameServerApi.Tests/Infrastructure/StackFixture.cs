using System.Net;
using System.Net.Sockets;
using Npgsql;
using Testcontainers.PostgreSql;
using Testcontainers.RabbitMq;
using Testcontainers.Redis;

namespace Rpg.GameServerApi.Tests.Infrastructure;

/// <summary>
/// Real Postgres, Redis and RabbitMQ in Docker, using the same images as infra/docker-compose.yml.
/// Docker is required: these tests fail (not skip) without it (spec project-skeleton, Decisions 2).
/// </summary>
public sealed class StackFixture : IAsyncLifetime
{
    public const string PostgresImage = "postgres:16-alpine";
    public const string RedisImage = "redis:7-alpine";
    public const string RabbitMqImage = "rabbitmq:4.1-management-alpine";

    public PostgreSqlContainer Postgres { get; } = new PostgreSqlBuilder(PostgresImage).Build();
    public RedisContainer Redis { get; } = new RedisBuilder(RedisImage).Build();
    public RabbitMqContainer RabbitMq { get; } = new RabbitMqBuilder(RabbitMqImage).Build();

    public string PostgresConnectionString => Postgres.GetConnectionString();
    public string RedisConnectionString => Redis.GetConnectionString() + ",abortConnect=false";
    public string RabbitMqUri => RabbitMq.GetConnectionString();

    public async ValueTask InitializeAsync() =>
        await Task.WhenAll(Postgres.StartAsync(), Redis.StartAsync(), RabbitMq.StartAsync());

    public async ValueTask DisposeAsync()
    {
        await Postgres.DisposeAsync();
        await Redis.DisposeAsync();
        await RabbitMq.DisposeAsync();
    }

    /// <summary>
    /// A new empty database in the shared Postgres container, so every run test migrates and writes on its own
    /// schema. Returns its connection string.
    /// </summary>
    public async Task<string> NewDatabaseAsync()
    {
        var name = "t_" + Guid.NewGuid().ToString("N");
        await using (var admin = new NpgsqlConnection(PostgresConnectionString))
        {
            await admin.OpenAsync();
            await using var create = new NpgsqlCommand($"CREATE DATABASE {name}", admin);
            await create.ExecuteNonQueryAsync();
        }

        return new NpgsqlConnectionStringBuilder(PostgresConnectionString) { Database = name }.ConnectionString;
    }

    /// <summary>Addresses where nothing listens, for "dependency unreachable" tests.</summary>
    public static class Unreachable
    {
        public static string Postgres => $"Host=127.0.0.1;Port={ClosedPort()};Username=postgres;Password=x;Timeout=2";
        public static string Redis => $"127.0.0.1:{ClosedPort()},abortConnect=false";
        public static string RabbitMq => $"amqp://guest:guest@127.0.0.1:{ClosedPort()}/";
    }

    /// <summary>A port that was free a moment ago: bind to port 0, read the port, release it.</summary>
    public static int ClosedPort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }
}

[CollectionDefinition(Name)]
public sealed class StackCollection : ICollectionFixture<StackFixture>
{
    public const string Name = "stack";
}
