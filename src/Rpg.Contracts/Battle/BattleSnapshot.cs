using System.Text.Json.Serialization;

namespace Rpg.Contracts.Battle;

/// <summary>
/// Frozen at checkout (slice 2). Identities only: Godot derives every stat from content, so no game logic lives here.
/// Schema v2 (spec game-skeleton, section 3.5) adds optional run fields; they are omitted from the JSON when null, so
/// a v1 document binds and re-serializes unchanged.
/// </summary>
/// <param name="SchemaVersion">1 or 2.</param>
/// <param name="Seed">Decimal string, "0".."9223372036854775807": int64 is not safe as a JSON number in browsers.</param>
/// <param name="EncounterId">Content id of the enemy encounter, e.g. "fixture.encounter.duel".</param>
/// <param name="Enemies">v2: the encounter's slots as resolved for this room; null means the encounter's own slots.</param>
/// <param name="ScalingId">v2: content id of the chapter's scaling rules.</param>
/// <param name="Depth">v2: 0-based floor depth the scaling applies to.</param>
public sealed record BattleSnapshot(
    int SchemaVersion,
    string BattleId,
    string Seed,
    string EncounterId,
    IReadOnlyList<PartyMemberSnapshot> Party,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<EnemySnapshot>? Enemies = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ScalingId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Depth = null);

/// <summary>
/// v2: a capture of the character's run state when the battle starts (spec game-skeleton 3.5). There is no loadout
/// here: a character's loadout only seeds its run state at run start. Stats other than HP/MP/Energy are re-derived
/// from content, level, items and equipment.
/// </summary>
/// <param name="Slot">1..4. The battle assigns unit id "P{Slot}".</param>
/// <param name="UnitDefId">Content id of the unit definition.</param>
/// <param name="Hp">v2: carried HP, stored ×100 like the attribute; 0 means the member is dead. Null means full.</param>
/// <param name="Mp">v2: carried MP (×100). Null means full.</param>
/// <param name="Energy">v2: carried ult charge (×100). Null means the attribute's default.</param>
/// <param name="Skills">v2: learned skills (ability tags) beyond the character's base kit.</param>
/// <param name="EquipmentIds">v2: content ids of the equipped pieces.</param>
/// <param name="Items">v2: passive items held, in pickup order.</param>
/// <param name="UseSlots">v2: the member's use slots (1, or more with slot items).</param>
public sealed record PartyMemberSnapshot(
    int Slot,
    string UnitDefId,
    int Level,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Hp = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Mp = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Energy = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<string>? Skills = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<string>? EquipmentIds = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<string>? Items = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<UseSlotSnapshot>? UseSlots = null);

/// <param name="ItemId">Content id of the usable item in this slot.</param>
/// <param name="Ready">Off cooldown and not used up.</param>
public sealed record UseSlotSnapshot(string ItemId, bool Ready);

/// <summary>v2: one enemy slot after loadout precedence and elite rolls. Null fields are written explicitly.</summary>
/// <param name="Slot">1-based. The battle assigns unit id "E{Slot}".</param>
/// <param name="LoadoutRef">A loadout id, "&lt;ownerId&gt;#&lt;n&gt;" for an inline loadout, or null for none.</param>
/// <param name="VariantId">The elite variant's content id, or null.</param>
public sealed record EnemySnapshot(int Slot, string UnitDefId, string? LoadoutRef, string? VariantId);
