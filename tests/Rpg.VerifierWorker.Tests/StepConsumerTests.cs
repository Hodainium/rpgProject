using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Verification;
using Rpg.VerifierWorker.Tests.Infrastructure;
using static Rpg.VerifierWorker.Tests.Infrastructure.WorkerHarness;

namespace Rpg.VerifierWorker.Tests;

/// <summary>
/// Spec run-verify 3.4 and 4 (F2, F7, F8): the verify.segment side with a real broker. As for battles, the ack follows the
/// commit or the republish; a retry comes back through its tier; a dead letter stays in verify.segment.dlq.
/// </summary>
[Collection(StackCollection.Name)]
public class StepConsumerTests(Stack stack)
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task APublishedStepJob_IsVerified_AndTheQueueDrains()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await WorkerHarness.CreateAsync(stack);
        var run = await worker.SeedRunAsync();
        await worker.StartStepConsumerAsync(Ct);

        await queues.PublishStepAsync(StepJobOf(run, 0));

        await queues.WaitUntilAsync(async () => await worker.ScalarAsync<string>(
            "SELECT status FROM run_steps WHERE run_id = $1 AND step_no = 0", run.RunId) == "Verified", "the genesis verdict");
        await queues.WaitUntilAsync(async () => await queues.DepthAsync(VerifyTopology.SegmentQueue) == 0, "the queue to drain");
        Assert.Equal(0u, await queues.DepthAsync(VerifyTopology.SegmentDeadLetterQueue));
        Assert.Equal(FakeStepRunner.GenesisHash, await worker.ScalarAsync<string>("SELECT genesis_hash FROM runs WHERE run_id = $1", run.RunId));
    }

    [Fact]
    public async Task ARunnerError_ComesBackThroughTheShortestRetryQueue()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await WorkerHarness.CreateAsync(stack);
        var run = await worker.SeedRunAsync();
        var calls = 0;
        worker.StepRunner.Handler = (request, _) => Task.FromResult(
            Interlocked.Increment(ref calls) == 1 ? FakeStepRunner.Error() : worker.StepRunner.Honest(request));
        await worker.StartStepConsumerAsync(Ct);
        var started = DateTime.UtcNow;

        await queues.PublishStepAsync(StepJobOf(run, 0));
        await queues.WaitUntilAsync(async () => await worker.ScalarAsync<string>(
            "SELECT status FROM run_steps WHERE run_id = $1 AND step_no = 0", run.RunId) == "Verified", "the retried verdict");

        Assert.Equal(2, worker.StepRunner.Calls);
        Assert.True(DateTime.UtcNow - started >= TimeSpan.FromSeconds(4.5), "the retry waited for the 5 s tier");   // F8
    }

    [Fact]
    public async Task APermanentlyFailingStep_EndsInTheSegmentDeadLetterQueue_WithItsReason()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await WorkerHarness.CreateAsync(stack, new() { ["Verifier:MaxAttempts"] = "1" });
        worker.StepRunner.Handler = (_, _) => Task.FromResult(FakeStepRunner.Error());
        var run = await worker.SeedRunAsync();
        await worker.StartStepConsumerAsync(Ct);

        await queues.PublishStepAsync(StepJobOf(run, 0));

        var dead = await queues.PeekAsync(VerifyTopology.SegmentDeadLetterQueue, TimeSpan.FromSeconds(30));
        Assert.NotNull(dead);
        Assert.Equal("attempts", System.Text.Encoding.UTF8.GetString((byte[])dead.Value.Headers[VerifyTopology.ReasonHeader]!));
        await queues.WaitUntilAsync(async () => await queues.DepthAsync(VerifyTopology.SegmentQueue) == 0, "the queue to be empty");
        Assert.Equal("Pending", await worker.ScalarAsync<string>("SELECT status FROM run_steps WHERE run_id = $1 AND step_no = 0", run.RunId));
    }

    [Fact]
    public async Task APoisonMessage_GoesStraightToTheSegmentDeadLetterQueue_AndIsAcked()
    {
        await using var queues = await RabbitTools.OpenAsync(stack);
        await using var worker = await WorkerHarness.CreateAsync(stack);
        await worker.StartStepConsumerAsync(Ct);

        await queues.PublishRawSegmentAsync("not json"u8.ToArray());

        var dead = await queues.PeekAsync(VerifyTopology.SegmentDeadLetterQueue, TimeSpan.FromSeconds(30));
        Assert.NotNull(dead);
        Assert.StartsWith("poison", System.Text.Encoding.UTF8.GetString((byte[])dead.Value.Headers[VerifyTopology.ReasonHeader]!));
        await queues.WaitUntilAsync(async () => await queues.DepthAsync(VerifyTopology.SegmentQueue) == 0, "the queue to be empty");
        Assert.Equal(0, worker.StepRunner.Calls);
    }
}
