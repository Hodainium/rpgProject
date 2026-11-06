namespace Rpg.Contracts.Battle;

/// <summary>
/// What the replay learned from content that C# must never know (spec settlement-outbox 3.1): computed by the Godot
/// runner from the content the replay loaded, never by the worker and never by the client. Settlement multiplies these
/// by a configured amount and nothing more.
/// </summary>
/// <param name="EncounterId">The encounter the battle was played against.</param>
/// <param name="BossIds">The encounter's enemies tagged <c>Enemy.Boss</c>; empty for an ordinary battle.</param>
/// <param name="PartyCharacterIds">The party's character ids, in slot order.</param>
/// <param name="Completions">Challenges the battle completed with the tier (stars) reached (spec economy-challenges 3.1). Omitted
/// from JSON when null; Godot emits none yet. Bosses stay in <paramref name="BossIds"/>.</param>
public sealed record BattleFacts(string EncounterId, IReadOnlyList<string> BossIds, IReadOnlyList<string> PartyCharacterIds,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<CompletionFact>? Completions = null);

/// <summary>One challenge a battle completed and the tier (stars) reached. The server decides what the tier is worth.</summary>
public sealed record CompletionFact(string ChallengeId, int Tier);
