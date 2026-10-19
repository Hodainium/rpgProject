## A piece of equipment (spec game-skeleton, section 3.1): one per slot tag on a character.
@tool
class_name EquipmentDefinition
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D
## A tag such as Equipment.Slot.Weapon. Equipping a second piece in the same slot replaces the first.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var slot: StringName = &""
@export var grants: AbilitySet
