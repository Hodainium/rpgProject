## Puts a piece in the run's armor inventory (spec playable-demo 3.7, D9: armor is never worn on its own; the player
## equips it on the map). Spec keys-and-gear 3.2: with no fixed piece, one is picked from `query` (seeded, rarity
## weights, never a piece the party holds or has seen); with prefer_open_slot, pieces for a slot some living member has
## empty are picked first (chests: "gear for your active party members").
@tool
class_name GiveEquipment
extends RunOutcome

@export var equipment: EquipmentDefinition
@export var query: GameplayTagQuery
@export var prefer_open_slot: bool = false


func apply(run: Object) -> void:
	if equipment != null:
		run.give_equipment(equipment)
	elif query != null:
		run.give_equipment_from(query, prefer_open_slot)
