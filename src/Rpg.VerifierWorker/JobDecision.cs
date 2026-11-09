using System.Diagnostics;
using Rpg.Contracts.Battle;

namespace Rpg.VerifierWorker;

public enum JobAction
{
    /// <summary>Done (a verdict was written, or one already existed): ack.</summary>
    Ack,

    /// <summary>Publish to <see cref="JobDecision.Tier"/>, then ack.</summary>
    Retry,

    /// <summary>Publish to the dead-letter queue with <see cref="JobDecision.Reason"/>, then ack.</summary>
    DeadLetter,
}

/// <param name="Result">The <c>rpg_step_jobs</c> label.</param>
/// <param name="Attempt">The attempt count to put in the retry message's header.</param>
public sealed record JobDecision(JobAction Action, string Result, RetryTier? Tier = null, string? Reason = null,
    int Attempt = 0);

/// <summary>The worker's trace source (added to the tracer in Program).</summary>
public static class WorkerTrace
{
    public static readonly ActivitySource Source = new("Rpg.VerifierWorker");
}
