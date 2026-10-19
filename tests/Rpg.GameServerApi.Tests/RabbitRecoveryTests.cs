using System.Net;
using Rpg.GameServerApi.Tests.Infrastructure;
using Testcontainers.PostgreSql;
using Testcontainers.RabbitMq;
using Testcontainers.Redis;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Has its own containers because it stops and restarts the broker. RabbitMQ is bound to a fixed host port so the
/// address survives the restart (Testcontainers otherwise picks a new random port on start).
/// </summary>
public class RabbitRecoveryTests : IAsyncLifetime
{
    private readonly PostgreSqlContainer _postgres = new PostgreSqlBuilder(StackFixture.PostgresImage).Build();
    private readonly RedisContainer _redis = new RedisBuilder(StackFixture.RedisImage).Build();
    private readonly RabbitMqContainer _rabbit =
        new RabbitMqBuilder(StackFixture.RabbitMqImage).WithPortBinding(StackFixture.ClosedPort(), 5672).Build();

    public async ValueTask InitializeAsync() =>
        await Task.WhenAll(_postgres.StartAsync(), _redis.StartAsync(), _rabbit.StartAsync());

    public async ValueTask DisposeAsync()
    {
        await _postgres.DisposeAsync();
        await _redis.DisposeAsync();
        await _rabbit.DisposeAsync();
    }

    [Fact]
    public async Task Ready_RecoversAfterRabbitRestart()
    {
        await using var factory = new ApiFactory(
            _postgres.GetConnectionString(), _redis.GetConnectionString() + ",abortConnect=false",
            _rabbit.GetConnectionString());
        var client = factory.CreateClient();
        var ct = TestContext.Current.CancellationToken;

        await ReadyProbe.WaitUntilAsync(client, r => r.Status == "Healthy");

        await _rabbit.StopAsync(ct);
        var (downCode, _) = await ReadyProbe.WaitUntilAsync(client, r => r.StatusOf("rabbitmq") == "Unhealthy");
        Assert.Equal(HttpStatusCode.ServiceUnavailable, downCode);

        await _rabbit.StartAsync(ct);
        var (upCode, _) = await ReadyProbe.WaitUntilAsync(client, r => r.Status == "Healthy", TimeSpan.FromSeconds(60));
        Assert.Equal(HttpStatusCode.OK, upCode);
    }
}
