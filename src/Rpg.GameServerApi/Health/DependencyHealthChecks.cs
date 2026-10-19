using Microsoft.Extensions.Diagnostics.HealthChecks;
using Npgsql;
using Rpg.GameServerApi.Infrastructure;

namespace Rpg.GameServerApi.Health;

/// <summary>Postgres is the source of truth: unreachable means Unhealthy.</summary>
public sealed class PostgresHealthCheck(NpgsqlDataSource dataSource) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken ct = default)
    {
        try
        {
            await using var command = dataSource.CreateCommand("SELECT 1");
            await command.ExecuteScalarAsync(ct);
            return HealthCheckResult.Healthy();
        }
        catch (Exception ex)
        {
            return new HealthCheckResult(context.Registration.FailureStatus, "Postgres unreachable.", ex);
        }
    }
}

/// <summary>Redis is never the source of correctness: registered with failureStatus Degraded.</summary>
public sealed class RedisHealthCheck(RedisConnection redis) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken ct = default)
    {
        if (redis.Multiplexer is not { IsConnected: true } multiplexer)
        {
            return new HealthCheckResult(context.Registration.FailureStatus, "Redis not connected.");
        }

        try
        {
            await multiplexer.GetDatabase().PingAsync().WaitAsync(ct);
            return HealthCheckResult.Healthy();
        }
        catch (Exception ex)
        {
            return new HealthCheckResult(context.Registration.FailureStatus, "Redis PING failed.", ex);
        }
    }
}

/// <summary>/verify (slice 3) can't accept work without the broker: a closed connection means Unhealthy.</summary>
public sealed class RabbitMqHealthCheck(RabbitMqConnection rabbit) : IHealthCheck
{
    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken ct = default) =>
        Task.FromResult(rabbit.IsOpen
            ? HealthCheckResult.Healthy()
            : new HealthCheckResult(context.Registration.FailureStatus, "RabbitMQ connection is not open."));
}
