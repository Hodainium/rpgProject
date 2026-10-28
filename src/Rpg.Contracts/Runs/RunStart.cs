namespace Rpg.Contracts.Runs;

/// <summary>POST /api/v1/runs (spec server-authority 3.1). Starts a run and abandons the player's active one.</summary>
/// <param name="RulesetVersion">The client's ruleset version, <c>&lt;godot version&gt;+&lt;16 hex&gt;</c> (3.5).</param>
/// <param name="RunStructureId">The run picked (a <c>RunStructure</c> id); not checked by the server.</param>
/// <param name="CharacterIds">The party, in slot order; not checked by the server.</param>
public sealed record RunStartRequest(string RulesetVersion, string RunStructureId, IReadOnlyList<string> CharacterIds);

/// <summary>201. Floor is 0; FloorSeed is a decimal string (int64 isn't safe as a JSON number in browsers).</summary>
public sealed record RunStartResponse(string RunId, int Floor, string FloorSeed, DateTimeOffset StartedAt);
