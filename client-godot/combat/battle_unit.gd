## One combatant: a node holding its CombatASC (named "AbilitySystemComponent", as GodotGAS looks it up) and its
## granted BattleAbilities. Unit ids are assigned by the battle: P<slot> for the party, E<slot> for enemies.
class_name BattleUnit
extends Node

enum Side { PARTY, ENEMY }

const HP: String = "hp"
const MAX_HP: String = "max_hp"
const MP: String = "mp"
const MAX_MP: String = "max_mp"
const SPD: String = "spd"
const ENERGY: String = "energy"
const MAX_ENERGY: String = "max_energy"
## Loose tag on dead units in v2 battles and the field (spec game-skeleton 3.4).
const DEAD_TAG: StringName = &"State.Dead"

var unit_id: StringName
var side: Side
var slot: int
var level: int
var definition: UnitDefinition
var asc: CombatASC
var alive: bool = true
## v2: ability tag → item id, for usable items granted to this unit.
var item_abilities: Dictionary = {}
## Content warnings raised while building the unit (e.g. a duplicate ability tag skipped).
var warnings := PackedStringArray()
## The unit whose effect last lowered this unit's HP (a hit or a DoT tick), for Event.Unit.Killed (spec item-pass 3.1).
## Not hashed: replay recomputes it, and it changes nothing the hash covers.
var last_hit_by: BattleUnit = null


## Builds the unit under `parent` (which must be inside the scene tree so GodotGAS's _ready hooks run).
##
## `kit` is empty for v1 snapshots, which build exactly as in slice 1. For v2 (spec game-skeleton 3.4) the battle
## builds it from the snapshot:
##   "stats": {attribute: int} overrides (enemy loadouts), "skills": Array[PackedScene] (learned skills / loadout
##   skills), "grants": Array of {"set": AbilitySet, "ability": PackedScene, "item": StringName} in grant order
##   (equipment, items, use slots, variant), "extra_effects": Array[GameplayEffect] (floor scaling),
##   "carry": {"hp": int or null, "mp": .., "energy": ..}.
static func create(parent: Node, id: StringName, unit_side: int, unit_slot: int, unit_def: UnitDefinition,
		unit_level: int, kit: Dictionary = {}) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.name = String(id)
	unit.unit_id = id
	unit.side = unit_side as Side
	unit.slot = unit_slot
	unit.level = unit_level
	unit.definition = unit_def
	parent.add_child(unit)

	unit.asc = CombatASC.new()
	unit.asc.name = "AbilitySystemComponent"
	var sets: Array[AttributeSet] = [unit_def.attribute_set.new()]
	unit.asc.attribute_sets = sets
	unit.add_child(unit.asc)

	if kit.is_empty():
		for scene in unit_def.abilities:
			var ability := scene.instantiate() as BattleAbility
			ability.ability_level = unit_level
			unit.asc.add_child(ability)  # GameplayAbility._ready grants itself to its parent ASC.
		unit._apply_stats({})
		return unit

	# v2, steps 1-5 of spec game-skeleton 3.4.
	var grants: Array = kit.get("grants", [])
	for scene in unit_def.abilities:
		unit._grant_ability(scene, &"")
	for scene in kit.get("skills", []):
		unit._grant_ability(scene, &"")
	for grant in grants:
		var ability_set: AbilitySet = grant.get("set")
		if ability_set != null:
			for scene in ability_set.abilities:
				unit._grant_ability(scene, &"")
		if grant.get("ability") != null:
			unit._grant_ability(grant["ability"], StringName(grant.get("item", &"")))
	unit._apply_stats(kit.get("stats", {}))
	for grant in grants:
		var ability_set: AbilitySet = grant.get("set")
		if ability_set != null:
			for effect in ability_set.effects:
				unit.asc.apply_gameplay_effect(effect, unit.asc, unit_level)
	for effect in kit.get("extra_effects", []):
		if effect != null:
			unit.asc.apply_gameplay_effect(effect, unit.asc, unit_level)
	for tag in unit_def.tags:
		unit.asc.add_tag(tag)
	for grant in grants:
		var ability_set: AbilitySet = grant.get("set")
		if ability_set != null:
			for tag in ability_set.tags:
				unit.asc.add_tag(tag)
	unit._apply_carry(kit.get("carry", {}))
	return unit


## Applies the definition's stats (stored ×100) through GodotGAS, with a loadout's overrides on top. max_* attributes
## (GodotGAS's naming for maxima) first, so clamps like hp ≤ max_hp see the final maximum.
func _apply_stats(overrides: Dictionary) -> void:
	var stats: Dictionary = definition.stats_x100.duplicate()
	for attribute_name in overrides:
		stats[attribute_name] = overrides[attribute_name]
	var maxima: Dictionary[String, float] = {}
	var others: Dictionary[String, float] = {}
	var names := stats.keys()
	names.sort()
	for attribute_name in names:
		var value := float(stats[attribute_name])
		if String(attribute_name).begins_with("max_"):
			maxima[attribute_name] = value
		else:
			others[attribute_name] = value
	asc.initialize_attribute_overrides(maxima)
	asc.initialize_attribute_overrides(others)


## v2 step 5: carried HP/MP/Energy. A null HP or MP means full (the current maximum, after item and equipment
## effects); null Energy keeps the attribute's value.
func _apply_carry(carry: Dictionary) -> void:
	var values: Dictionary[String, float] = {}
	for pair in [[HP, MAX_HP], [MP, MAX_MP]]:
		if not asc.has_attribute(pair[0]):
			continue
		var carried: Variant = carry.get(pair[0])
		if carried != null:
			values[pair[0]] = float(carried)
		elif asc.has_attribute(pair[1]):
			values[pair[0]] = asc.get_attribute(pair[1]).current_value
	if asc.has_attribute(ENERGY) and carry.get(ENERGY) != null:
		values[ENERGY] = float(carry[ENERGY])
	# Spec item-pass 3.3: toughness always starts full, after bonuses (an elite's extra toughness counts).
	if asc.has_attribute(Battle.TOUGHNESS) and asc.has_attribute(Battle.MAX_TOUGHNESS):
		values[Battle.TOUGHNESS] = asc.get_attribute(Battle.MAX_TOUGHNESS).current_value
	asc.initialize_attribute_overrides(values)


func _grant_ability(scene: PackedScene, item_id: StringName) -> void:
	if scene == null:
		return
	var ability := scene.instantiate() as BattleAbility
	if ability == null:
		warnings.append("%s: %s is not a BattleAbility scene" % [unit_id, scene.resource_path])
		return
	if ability_by_tag(ability.ability_tag) != null:
		warnings.append("%s already has %s; the duplicate grant is skipped" % [unit_id, ability.ability_tag])
		ability.free()
		return
	ability.ability_level = level
	asc.add_child(ability)
	if item_id != &"":
		item_abilities[ability.ability_tag] = item_id


## Removes an ability for the rest of the battle (a usable item after its one use).
func revoke_ability(ability: BattleAbility) -> void:
	asc.remove_ability(ability)
	asc.remove_child(ability)


func is_party() -> bool:
	return side == Side.PARTY


## Current value of an attribute as a whole number (stored ×100).
func stat(attribute_name: String) -> int:
	var data := asc.get_attribute(attribute_name)
	return int(data.current_value) if data else 0


## Alive and above 0 HP. Executions skip targets that are down even before the end-of-turn death check.
func is_up() -> bool:
	return alive and stat(HP) > 0


## Granted abilities in grant order.
func abilities() -> Array[BattleAbility]:
	var result: Array[BattleAbility] = []
	for child in asc.get_children():
		if child is BattleAbility:
			result.append(child)
	return result


## Abilities the unit can choose as its action: everything except triggered passives and ults.
func action_abilities() -> Array[BattleAbility]:
	var result: Array[BattleAbility] = []
	for ability in abilities():
		if not ability.is_triggered() and not ability.is_ultimate():
			result.append(ability)
	return result


## Ults (spec ult-interrupts): cast only as interrupts, never as turn actions. Grant order.
func ultimate_abilities() -> Array[BattleAbility]:
	var result: Array[BattleAbility] = []
	for ability in abilities():
		if ability.is_ultimate():
			result.append(ability)
	return result


func ability_by_tag(tag: StringName) -> BattleAbility:
	for ability in abilities():
		if ability.ability_tag == tag:
			return ability
	return null
