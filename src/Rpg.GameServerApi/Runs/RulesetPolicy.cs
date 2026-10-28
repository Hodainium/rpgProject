namespace Rpg.GameServerApi.Runs;

/// <summary>Configuration section <c>Ruleset</c> (spec server-authority 3.5).</summary>
public sealed class RulesetOptions
{
    public const string Section = "Ruleset";

    /// <summary>The ruleset versions a run may start under.</summary>
    public List<string> Accepted { get; set; } = [];

    /// <summary>Development only: accept and record any version. Ignored in every other environment.</summary>
    public bool AcceptAny { get; set; }
}

/// <summary>Decides whether a client's ruleset version may start a run (409 1001 otherwise).</summary>
public sealed class RulesetPolicy(Microsoft.Extensions.Options.IOptions<RulesetOptions> options, IHostEnvironment environment)
{
    public bool Accepts(string rulesetVersion) =>
        (options.Value.AcceptAny && environment.IsDevelopment())
        || options.Value.Accepted.Contains(rulesetVersion, StringComparer.Ordinal);
}
