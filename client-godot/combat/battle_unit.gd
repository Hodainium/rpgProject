## One combatant: a node holding its CombatASC (named "AbilitySystemComponent", as GodotGAS looks it up) and its
## granted BattleAbilities. Unit ids are assigned by the battle: P<slot> for the party, E<slot> for enemies.
class_name BattleUnit
extends Node

enum Side { PARTY, ENEMY }

const HP: String = "HP"
const SPD: String = "SPD"

var unit_id: StringName
var side: Side
var slot: int
var level: int
var definition: UnitDefinition
var asc: CombatASC
var alive: bool = true


## Builds the unit under `parent` (which must be inside the scene tree so GodotGAS's _ready hooks run).
static func create(parent: Node, id: StringName, unit_side: int, unit_slot: int, unit_def: UnitDefinition,
		unit_level: int) -> BattleUnit:
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

	for scene in unit_def.abilities:
		var ability := scene.instantiate() as BattleAbility
		ability.ability_level = unit_level
		unit.asc.add_child(ability)  # GameplayAbility._ready grants itself to its parent ASC.

	unit._apply_stats()
	return unit


## Applies the definition's stats (stored ×100) through GodotGAS. Max* attributes first, so clamps like
## HP ≤ MaxHP see the final maximum.
func _apply_stats() -> void:
	var maxima: Dictionary[String, float] = {}
	var others: Dictionary[String, float] = {}
	var names := definition.stats_x100.keys()
	names.sort()
	for attribute_name in names:
		var value := float(definition.stats_x100[attribute_name])
		if String(attribute_name).begins_with("Max"):
			maxima[attribute_name] = value
		else:
			others[attribute_name] = value
	asc.initialize_attribute_overrides(maxima)
	asc.initialize_attribute_overrides(others)


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


func ability_by_tag(tag: StringName) -> BattleAbility:
	for ability in abilities():
		if ability.ability_tag == tag:
			return ability
	return null
