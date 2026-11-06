namespace Rpg.VerifierWorker;

/// <summary>Configuration section <c>Verifier</c> (spec battle-verify 3.6).</summary>
public sealed class VerifierOptions
{
    public const string Section = "Verifier";

    /// <summary>Consumers, each with prefetch 1, so this many Godot processes at most.</summary>
    public int Concurrency { get; set; } = 2;

    /// <summary>A replay that runs longer is killed (the whole process tree) and counts as a runner error.</summary>
    public TimeSpan ProcessTimeout { get; set; } = TimeSpan.FromSeconds(60);

    /// <summary>Runner errors after which a job is dead-lettered.</summary>
    public int MaxAttempts { get; set; } = 5;

    /// <summary>The godot executable (the .NET build, headless capable).</summary>
    public string GodotPath { get; set; } = "godot";

    /// <summary>The client-godot project folder the replay runs from.</summary>
    public string ProjectPath { get; set; } = "client-godot";

    /// <summary>Content the replay loads (the runner's --content-root); empty = the runner's default, res://content/.</summary>
    public string ContentRoot { get; set; } = "";

    /// <summary>Frames after which Godot quits whatever happens (the headless safeguard).</summary>
    public int QuitAfterFrames { get; set; } = 200000;

    /// <summary>
    /// Ruleset versions this worker verifies. Empty = only its own. The replay always runs this worker's own project, so
    /// list another version only when that project is known to replay it identically (an operator's promise): otherwise an
    /// honest battle is rejected, and the verdict records only the worker's version.
    /// </summary>
    public string[] AcceptedRulesets { get; set; } = [];

    /// <summary>Overrides the version read from the project (tests and e2e); empty = ask Godot once at startup.</summary>
    public string RulesetVersion { get; set; } = "";

    /// <summary>How long a stopping worker lets running jobs finish before it gives the rest back to the broker.</summary>
    public TimeSpan ShutdownGrace { get; set; } = TimeSpan.FromSeconds(70);  // longer than ProcessTimeout
}

/// <summary>Configuration section <c>Settlement</c> (spec settlement-outbox 3.7). What a boss pays is a server-owned rule (spec economy-rewards), not configuration.</summary>
public sealed class SettlementOptions
{
    public const string Section = "Settlement";

    public bool Enabled { get; set; } = true;
}
