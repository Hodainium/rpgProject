namespace Rpg.Contracts.Runs;

/// <summary>POST /api/v1/runs (spec server-authority 3.1). Starts a run and abandons the player's active one.</summary>
/// <param name="RulesetVersion">The client's ruleset version, <c>&lt;godot version&gt;+&lt;16 hex&gt;</c> (3.5).</param>
/// <param name="RunStructureId">The run picked (a <c>RunStructure</c> id); not checked by the server.</param>
/// <param name="CharacterIds">The party, in slot order; not checked by the server.</param>
/// <param name="Session">Spec account-session 2.2: the player's current account session. Required (null is a 400); an older
/// one is refused with 409 1412 and nothing changes, so a stale device never abandons the current run by starting one.</param>
public sealed record RunStartRequest(string RulesetVersion, string RunStructureId, IReadOnlyList<string> CharacterIds,
    long? Session);

/// <summary>201. Floor is 0; FloorSeed is a decimal string (int64 isn't safe as a JSON number in browsers).</summary>
/// <param name="UnlockedCharacterIds">Spec card-collection 2.5: core + owned characters; absent when the card system is off.</param>
/// <param name="CardPool">Spec card-collection 2.5: the item pool of the run (core + owned item cards), a verified input; absent when off.</param>
public sealed record RunStartResponse(string RunId, int Floor, string FloorSeed, DateTimeOffset StartedAt,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<string>? UnlockedCharacterIds = null,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<string>? CardPool = null);
