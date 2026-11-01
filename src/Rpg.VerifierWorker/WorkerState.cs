using Microsoft.Extensions.Options;

namespace Rpg.VerifierWorker;

/// <summary>What the worker learned at startup: its ruleset version, and whether it is consuming (for readiness).</summary>
public sealed class WorkerState(IOptions<VerifierOptions> options)
{
    private volatile string _rulesetVersion = options.Value.RulesetVersion;
    private volatile bool _ready;

    /// <summary>The project's ruleset version; empty until startup read it.</summary>
    public string RulesetVersion => _rulesetVersion;

    public bool Ready => _ready;

    public void SetRulesetVersion(string version) => _rulesetVersion = version;

    public void SetReady(bool ready) => _ready = ready;

    /// <summary>Spec battle-verify 2.5: only the configured versions, by default only the worker's own.</summary>
    public bool Accepts(string ruleset) =>
        options.Value.AcceptedRulesets is { Length: > 0 } accepted
            ? accepted.Contains(ruleset, StringComparer.Ordinal)
            : string.Equals(ruleset, _rulesetVersion, StringComparison.Ordinal);
}
