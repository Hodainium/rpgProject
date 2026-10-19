## A starting kit (spec game-skeleton, section 3.1), never the current inventory.
##
## Characters: copied into the character's run state once, at run start (learned skills, items, equipment); battles
## then capture the run state, not the loadout. Enemies: applied at each battle start, with precedence the unit's
## default_loadout → an encounter slot's loadout → a room placement's loadout (the winner replaces the others).
@tool
class_name Loadout
extends Resource

## Needed when the loadout is its own file (referenced by id). Inline loadouts are referenced as "<ownerId>#<n>".
@export var id: StringName = &""
## Skills (BattleAbility scenes) the unit starts with, on top of its base abilities.
@export var skills: Array[PackedScene] = []
## Items the unit starts with (passive or usable; a usable item fills a use slot).
@export var items: Array[ItemDefinition] = []
## Gear the unit starts with (one per slot tag).
@export var equipment: Array[EquipmentDefinition] = []

## Enemies only: stat overrides as typed, with up to 2 decimals. A character's stats live on its definition, so they
## can always be re-derived. Editor-only view of stats_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var stats: Dictionary[String, float]:
	get:
		var typed: Dictionary[String, float] = {}
		for attribute_name in stats_x100:
			typed[attribute_name] = Fixed.to_display(stats_x100[attribute_name])
		return typed
	set(typed):
		var stored: Dictionary[String, int] = {}
		for attribute_name in typed:
			if Fixed.has_extra_decimals(typed[attribute_name]):
				push_warning("Loadout '%s': %s keeps only 2 decimals." % [id, attribute_name])
			stored[attribute_name] = Fixed.from_typed(typed[attribute_name])
		stats_x100 = stored

## Saved form of `stats` (×100 whole numbers).
@export_storage var stats_x100: Dictionary[String, int] = {}
