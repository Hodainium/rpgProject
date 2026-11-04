namespace Rpg.Contracts.Battle;

/// <summary>
/// What the replay learned from content that C# must never know (spec settlement-outbox 3.1): computed by the Godot
/// runner from the content the replay loaded, never by the worker and never by the client. Settlement multiplies these
/// by a configured amount and nothing more.
/// </summary>
/// <param name="EncounterId">The encounter the battle was played against.</param>
/// <param name="BossIds">The encounter's enemies tagged <c>Enemy.Boss</c>; empty for an ordinary battle.</param>
/// <param name="PartyCharacterIds">The party's character ids, in slot order.</param>
public sealed record BattleFacts(string EncounterId, IReadOnlyList<string> BossIds, IReadOnlyList<string> PartyCharacterIds);
