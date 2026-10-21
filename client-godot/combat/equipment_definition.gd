## A piece of equipment (spec game-skeleton, section 3.1): one per slot tag on a character.
##
## Spec item-pass 3.5: armor and weapons can also be found on pedestals and in shops (the pickup fields below, like an
## item's). A piece taken in a run goes into the party's armor inventory and is equipped from there on the map.
@tool
class_name EquipmentDefinition
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
## One line for the pickup and party panels.
@export_multiline var description: String = ""
@export var icon: Texture2D
@export var mesh: Mesh
## A tag such as Equipment.Slot.Weapon, one of the run structure's equipment_slots. Equipping a second piece in the
## same slot sends the first back to the armor inventory.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var slot: StringName = &""
@export var grants: AbilitySet

@export_group("Pickup")
## Pools (Pool.Treasure, Pool.Shop...) and rarity, matched by pedestal and shop queries together with items.
## No pool tag: never offered (only loadouts and events give it).
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var tags: Array[StringName] = []
@export var price: int = 15

@export_group("")
## Pick weight as typed. Editor-only view of weight_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var weight: float:
	get:
		return Fixed.to_display(weight_x100)
	set(typed):
		weight_x100 = Fixed.from_typed(typed)

@export_storage var weight_x100: int = 100
