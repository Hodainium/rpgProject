using RabbitMQ.Client;
using Rpg.Contracts.Battle;
using Rpg.Verification;
using Rpg.VerifierWorker.Tests.Infrastructure;
using static Rpg.VerifierWorker.Tests.Infrastructure.WorkerHarness;

namespace Rpg.VerifierWorker.Tests;

/// <summary>
/// Spec battle-verify 2.1, 2.3, 3.3 and 4: the RabbitMQ side with a real broker. The ack always follows the commit or
/// the republish; retries come back through the retry queues; dead letters stay in the DLQ. Each test purges the
/// queues first and last (the collection runs one test at a time).
/// </summary>
[Collection(StackCollection.Name)]
public class VerifyConsumerTests(Stack stack)
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task APublishedJob_IsVerified_AndTheQueueDrains()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        await worker.StartConsumerAsync(Ct);

        await queues.PublishAsync(JobOf(battle));

        await queues.WaitUntilAsync(async () => await worker.ScalarAsync<string>(
            "SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId) == "Verified", "the verdict");
        await queues.WaitUntilAsync(async () => await queues.DepthAsync(VerifyTopology.Queue) == 0, "the queue to drain");
        Assert.Equal(0u, await queues.DepthAsync(VerifyTopology.DeadLetterQueue));
    }

    [Fact]
    public async Task ARunnerError_GoesToTheShortestRetryQueue_AndComesBackAfterItsDelay()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        var calls = 0;
        worker.Runner.Handler = (request, _) => Task.FromResult(
            Interlocked.Increment(ref calls) == 1 ? FakeReplayRunner.Error() : FakeReplayRunner.Verified(FakeReplayRunner.BattleIdOf(request)));
        await worker.StartConsumerAsync(Ct);
        var started = DateTime.UtcNow;

        await queues.PublishAsync(JobOf(battle));
        await queues.WaitUntilAsync(async () => await worker.ScalarAsync<int>(
            "SELECT attempts FROM battle_sessions WHERE battle_id = $1", battle.BattleId) == 1, "the first attempt");
        await queues.WaitUntilAsync(async () => await worker.ScalarAsync<string>(
            "SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId) == "Verified", "the retried verdict");

        Assert.Equal(2, worker.Runner.Calls);
        Assert.True(DateTime.UtcNow - started >= TimeSpan.FromSeconds(4.5), "the retry waited for the 5 s tier");  // F6
    }

    [Fact]
    public async Task APermanentlyFailingJob_EndsInTheDeadLetterQueueWithItsReason()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await CreateAsync(stack, new() { ["Verifier:MaxAttempts"] = "1" });
        worker.Runner.Handler = (_, _) => Task.FromResult(FakeReplayRunner.Error());
        var battle = await worker.SeedAsync();
        await worker.StartConsumerAsync(Ct);

        await queues.PublishAsync(JobOf(battle));

        var dead = await queues.PeekAsync(VerifyTopology.DeadLetterQueue, TimeSpan.FromSeconds(30));
        Assert.NotNull(dead);
        Assert.Equal("attempts", System.Text.Encoding.UTF8.GetString((byte[])dead.Value.Headers[VerifyTopology.ReasonHeader]!));
        Assert.Equal(1, worker.Runner.Calls);
        await queues.WaitUntilAsync(async () => await queues.DepthAsync(VerifyTopology.Queue) == 0, "the main queue to be empty");
        Assert.NotNull(await worker.ScalarAsync<DateTime?>(
            "SELECT dead_lettered_at FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
    }

    [Fact]
    public async Task AnUnexpectedFailure_DeadLettersTheJob_AndMarksTheSessionSoTheSweeperLeavesItAlone()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await CreateAsync(stack);
        worker.Runner.Handler = (_, _) => throw new OperationCanceledException("not a runner error");
        var battle = await worker.SeedAsync();
        await worker.StartConsumerAsync(Ct);

        await queues.PublishAsync(JobOf(battle));

        Assert.NotNull(await queues.PeekAsync(VerifyTopology.DeadLetterQueue, TimeSpan.FromSeconds(30)));
        Assert.Equal("error", await worker.ScalarAsync<string>(
            "SELECT dead_letter_reason FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
        Assert.NotNull(await worker.ScalarAsync<DateTime?>(
            "SELECT dead_lettered_at FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
    }

    [Fact]
    public async Task APoisonMessage_GoesToTheDeadLetterQueue_AndIsAcked()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await CreateAsync(stack);
        await worker.StartConsumerAsync(Ct);

        await queues.PublishRawAsync("this is not a job"u8.ToArray());

        var dead = await queues.PeekAsync(VerifyTopology.DeadLetterQueue, TimeSpan.FromSeconds(30));  // F8
        Assert.NotNull(dead);
        Assert.Equal("this is not a job", System.Text.Encoding.UTF8.GetString(dead.Value.Body));
        Assert.StartsWith("poison", System.Text.Encoding.UTF8.GetString((byte[])dead.Value.Headers[VerifyTopology.ReasonHeader]!));
        await queues.WaitUntilAsync(async () => await queues.DepthAsync(VerifyTopology.Queue) == 0, "the main queue to be empty");
        Assert.Equal(0, worker.Runner.Calls);
    }

    [Fact]
    public async Task AJobForAnotherRuleset_GoesToTheDeadLetterQueue()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync(ruleset: "4.7.2.stable.mono+ffffffffffffffff");
        await worker.StartConsumerAsync(Ct);

        await queues.PublishAsync(JobOf(battle));

        var dead = await queues.PeekAsync(VerifyTopology.DeadLetterQueue, TimeSpan.FromSeconds(30));  // F9
        Assert.NotNull(dead);
        Assert.Equal("ruleset", System.Text.Encoding.UTF8.GetString((byte[])dead.Value.Headers[VerifyTopology.ReasonHeader]!));
        Assert.Equal("Submitted", await worker.ScalarAsync<string>("SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId));
    }

    [Fact]
    public async Task ADeliveryTheFirstWorkerNeverAcked_IsRedeliveredAndFoundDone()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        await worker.Processor.ProcessAsync(JobOf(battle), Ct);  // the first worker committed ...
        Assert.Equal(1, worker.Runner.Calls);

        // ... and died before its ack: the broker still has the message unacked on a connection that goes away.
        await queues.PublishAsync(JobOf(battle));
        var connection = await new ConnectionFactory { Uri = new Uri(stack.RabbitMq.GetConnectionString()) }.CreateConnectionAsync(Ct);
        var channel = await connection.CreateChannelAsync(cancellationToken: Ct);
        var taken = await channel.BasicGetAsync(VerifyTopology.Queue, autoAck: false, Ct);
        Assert.NotNull(taken);
        await connection.CloseAsync(Ct);  // no ack: the message returns to the queue
        await connection.DisposeAsync();

        await worker.StartConsumerAsync(Ct);

        await queues.WaitUntilAsync(async () => await queues.DepthAsync(VerifyTopology.Queue) == 0, "the redelivery to be acked");  // F3
        Assert.Equal(1, worker.Runner.Calls);  // not replayed again
        Assert.Equal(1, worker.Metrics.Count("rpg.verify_jobs", "result=duplicate"));
        Assert.Equal(0u, await queues.DepthAsync(VerifyTopology.DeadLetterQueue));
    }

    [Fact]
    public async Task AFailedSettle_RequeuesTheDelivery_SoTheConsumerIsNotLeftStuck()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await CreateAsync(stack);
        worker.Runner.Handler = (_, _) => Task.FromResult(FakeReplayRunner.Error());  // the decision is a retry publish
        var battle = await worker.SeedAsync();
        await using var connection = await new ConnectionFactory { Uri = new Uri(stack.RabbitMq.GetConnectionString()) }.CreateConnectionAsync(Ct);
        await using var channel = await connection.CreateChannelAsync(cancellationToken: Ct);
        await using var broken = await connection.CreateChannelAsync(VerifyMessaging.ConfirmedChannel, Ct);
        await broken.CloseAsync(Ct);  // every publish on it fails, like a broker blip between the work and the settle
        await queues.PublishAsync(JobOf(battle));
        var got = await channel.BasicGetAsync(VerifyTopology.Queue, autoAck: false, Ct);
        Assert.NotNull(got);
        var delivery = new RabbitMQ.Client.Events.BasicDeliverEventArgs("test", got.DeliveryTag, got.Redelivered,
            got.Exchange, got.RoutingKey, got.BasicProperties, got.Body, Ct);

        await worker.Consumer.HandleAsync(channel, broken, delivery, Ct);

        Assert.True(channel.IsOpen);
        await queues.WaitUntilAsync(async () => await queues.DepthAsync(VerifyTopology.Queue) == 1, "the requeued delivery");
    }

    [Fact]
    public async Task Readiness_FollowsTheBrokerConnection_AndTheConsumersComeBack()
    {
        await using var worker = await CreateAsync(stack);
        var battle = await worker.SeedAsync();
        await worker.StartConsumerAsync(Ct);

        var closed = await stack.RabbitMq.ExecAsync(["rabbitmqctl", "close_all_connections", "test"], Ct);
        Assert.Equal(0, closed.ExitCode);

        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (worker.State.Ready)
        {
            Assert.True(DateTime.UtcNow < deadline, "readiness never dropped");
            await Task.Delay(20, Ct);
        }

        deadline = DateTime.UtcNow.AddSeconds(60);
        while (!worker.State.Ready)
        {
            Assert.True(DateTime.UtcNow < deadline, "readiness never came back");
            await Task.Delay(100, Ct);
        }

        await using var queues = await RabbitTools.OpenAsync(stack);
        await queues.PublishAsync(JobOf(battle));
        await queues.WaitUntilAsync(async () => await worker.ScalarAsync<string>(
            "SELECT status FROM battle_sessions WHERE battle_id = $1", battle.BattleId) == "Verified", "a verdict after recovery");
    }

    [Fact]
    public async Task TheTopology_IsDeclaredWithTheSpecsTtlsAndDeadLetterRouting()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await CreateAsync(stack);
        await worker.StartConsumerAsync(Ct);
        using var http = new HttpClient();
        var management = $"http://{stack.RabbitMq.Hostname}:{stack.RabbitMq.GetMappedPublicPort(15672)}/api/queues/%2F/";
        http.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Basic",
            Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(
                Uri.UnescapeDataString(new Uri(stack.RabbitMq.GetConnectionString()).UserInfo))));

        foreach (var tier in VerifyTopology.RetryTiers)
        {
            using var document = System.Text.Json.JsonDocument.Parse(await http.GetStringAsync(management + tier.Queue, Ct));
            var arguments = document.RootElement.GetProperty("arguments");
            Assert.Equal(tier.Delay.TotalMilliseconds, arguments.GetProperty("x-message-ttl").GetDouble());
            Assert.Equal(VerifyTopology.Exchange, arguments.GetProperty("x-dead-letter-exchange").GetString());
            Assert.Equal(VerifyTopology.RoutingKey, arguments.GetProperty("x-dead-letter-routing-key").GetString());
            Assert.True(document.RootElement.GetProperty("durable").GetBoolean());
        }

        using var main = System.Text.Json.JsonDocument.Parse(await http.GetStringAsync(management + VerifyTopology.Queue, Ct));
        Assert.Equal(VerifyTopology.DeadLetterExchange, main.RootElement.GetProperty("arguments").GetProperty("x-dead-letter-exchange").GetString());
        Assert.Equal(VerifyTopology.DeadRoutingKey, main.RootElement.GetProperty("arguments").GetProperty("x-dead-letter-routing-key").GetString());
    }

    private static Task<WorkerHarness> CreateAsync(Stack stack, Dictionary<string, string?>? settings = null) =>
        WorkerHarness.CreateAsync(stack, settings);
}
