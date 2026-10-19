using System.Diagnostics;
using System.Net;
using Rpg.GameServerApi.Tests.Infrastructure;

namespace Rpg.GameServerApi.Tests;

/// <summary>Readiness policy from spec project-skeleton, section 4.</summary>
[Collection(StackCollection.Name)]
public class HealthTests(StackFixture stack)
{
    [Fact]
    public async Task Ready_Returns200Healthy_WhenAllUp()
    {
        await using var factory = ApiFactory.AllUp(stack);
        var client = factory.CreateClient();

        var (code, report) = await ReadyProbe.WaitUntilAsync(client, r => r.Status == "Healthy");

        Assert.Equal(HttpStatusCode.OK, code);
        Assert.All(report.Checks, c => Assert.Equal("Healthy", c.Status));
    }

    [Fact]
    public async Task Ready_Returns503_WhenPostgresUnreachable()
    {
        await using var factory = new ApiFactory(
            StackFixture.Unreachable.Postgres, stack.RedisConnectionString, stack.RabbitMqUri);
        var client = factory.CreateClient();

        // Wait for the other dependencies to connect, so the 503 is Postgres's alone.
        var (code, report) = await ReadyProbe.WaitUntilAsync(client,
            r => r.StatusOf("rabbitmq") == "Healthy" && r.StatusOf("redis") == "Healthy");

        Assert.Equal(HttpStatusCode.ServiceUnavailable, code);
        Assert.Equal("Unhealthy", report.StatusOf("postgres"));
    }

    [Fact]
    public async Task Ready_ReportsDegraded_WhenRedisUnreachable()
    {
        await using var factory = new ApiFactory(
            stack.PostgresConnectionString, StackFixture.Unreachable.Redis, stack.RabbitMqUri);
        var client = factory.CreateClient();

        var (code, report) = await ReadyProbe.WaitUntilAsync(client, r => r.StatusOf("rabbitmq") == "Healthy");

        Assert.Equal(HttpStatusCode.OK, code);
        Assert.Equal("Degraded", report.Status);
        Assert.Equal("Degraded", report.StatusOf("redis"));
        Assert.Equal("Healthy", report.StatusOf("postgres"));
    }

    [Fact]
    public async Task Ready_Returns503_WhenRabbitUnreachable()
    {
        await using var factory = new ApiFactory(
            stack.PostgresConnectionString, stack.RedisConnectionString, StackFixture.Unreachable.RabbitMq);
        var client = factory.CreateClient();

        var (code, report) = await ReadyProbe.WaitUntilAsync(client, r => r.StatusOf("redis") == "Healthy");

        Assert.Equal(HttpStatusCode.ServiceUnavailable, code);
        Assert.Equal("Unhealthy", report.StatusOf("rabbitmq"));
        Assert.Equal("Healthy", report.StatusOf("postgres"));
    }

    [Fact]
    public async Task Server_Starts_WithNoDependencies()
    {
        await using var factory = new ApiFactory(
            StackFixture.Unreachable.Postgres, StackFixture.Unreachable.Redis, StackFixture.Unreachable.RabbitMq);
        var client = factory.CreateClient();

        var live = await client.GetAsync("/health/live", TestContext.Current.CancellationToken);
        var timer = Stopwatch.StartNew();
        var (readyCode, report) = await ReadyProbe.GetAsync(client);
        timer.Stop();

        Assert.Equal(HttpStatusCode.OK, live.StatusCode);
        Assert.Equal(HttpStatusCode.ServiceUnavailable, readyCode);
        Assert.Equal("Unhealthy", report.Status);
        // Per-check timeouts (2 s Postgres, 1 s Redis/RabbitMQ) keep the probe fast even when nothing answers.
        Assert.True(timer.Elapsed < TimeSpan.FromSeconds(5), $"Readiness took {timer.Elapsed}.");
    }

    [Fact]
    public async Task Live_Returns200_Always()
    {
        await using var factory = ApiFactory.AllUp(stack);
        var client = factory.CreateClient();

        var response = await client.GetAsync("/health/live", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }
}
