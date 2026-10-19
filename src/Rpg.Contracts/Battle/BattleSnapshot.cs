namespace Rpg.Contracts.Battle;

/// <summary>
/// Frozen at checkout (slice 2). Identities only: Godot derives every stat from content, so no game logic lives here.
/// </summary>
/// <param name="SchemaVersion">Currently 1.</param>
/// <param name="Seed">Decimal string, "0".."9223372036854775807": int64 is not safe as a JSON number in browsers.</param>
/// <param name="EncounterId">Content id of the enemy encounter, e.g. "fixture.encounter.duel".</param>
public sealed record BattleSnapshot(
    int SchemaVersion,
    string BattleId,
    string Seed,
    string EncounterId,
    IReadOnlyList<PartyMemberSnapshot> Party);

/// <param name="Slot">1..4. The battle assigns unit id "P{Slot}".</param>
/// <param name="UnitDefId">Content id of the unit definition.</param>
public sealed record PartyMemberSnapshot(int Slot, string UnitDefId, int Level);
