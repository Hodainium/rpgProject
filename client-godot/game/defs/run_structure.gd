## The shape of a run (spec game-skeleton, section 3.1): its floors in order.
@tool
class_name RunStructure
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var floors: Array[FloorSlot] = []
## Given when an item pool has nothing left (Isaac's Breakfast).
@export var fallback_item: ItemDefinition
## The equipment slots characters have in this run, in display order (spec item-pass 3.5): tags such as
## Equipment.Slot.Weapon, Equipment.Slot.Head. A new slot is one more tag here; no code.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var equipment_slots: Array[StringName] = []
## Spec playable-demo 2.2: started when the content root holds several runs and none is named (menu, `new`).
@export var default_run: bool = false
## Spec playable-demo 3.7: pool pick weight by rarity tag (Item.Rarity.Common: 60 ...), as typed. A candidate's weight
## is its own weight × its rarity's / 100 (no rarity tag: unchanged). Empty: pools pick as before. Editor-only view of
## rarity_weights_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var rarity_weights: Dictionary[StringName, float]:
	get:
		var typed: Dictionary[StringName, float] = {}
		for tag in rarity_weights_x100:
			typed[tag] = Fixed.to_display(rarity_weights_x100[tag])
		return typed
	set(typed):
		var stored: Dictionary[StringName, int] = {}
		for tag in typed:
			if Fixed.has_extra_decimals(typed[tag]):
				push_warning("RunStructure '%s': %s keeps only 2 decimals." % [id, tag])
			stored[tag] = Fixed.from_typed(typed[tag])
		rarity_weights_x100 = stored

## Saved form of `rarity_weights` (×100 whole numbers).
@export_storage var rarity_weights_x100: Dictionary[StringName, int] = {}

@export_group("Experience")
## Spec playable-demo 3.11 (D28): XP every living member gains per enemy beaten in a won battle (per boss: xp_per_boss).
@export var xp_per_enemy: int = 0
@export var xp_per_boss: int = 0
## Total XP for level 2, 3, 4...; rising. Empty: no XP and no levels in this run.
@export var xp_to_level: Array[int] = []
@export_group("Keys and chests")
## Spec keys-and-gear 2.1-2.3 (Isaac-style). Keys the party starts with; floors before this number (1-based count:
## 1 = the first floor) have no locked rooms.
@export var starting_keys: int = 0
@export var unlocked_floors: int = 0
## Typed percentages (20 = 20%), rolled when a room is cleared after a battle (never the boss room). A key is golden
## with golden_key_chance. Editor-only views of the ×100 fields; all 0 = no keys or chests in this run.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var key_drop_chance: float:
	get:
		return Fixed.to_display(key_drop_chance_x100)
	set(typed):
		key_drop_chance_x100 = Fixed.from_typed(typed)
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var golden_key_chance: float:
	get:
		return Fixed.to_display(golden_key_chance_x100)
	set(typed):
		golden_key_chance_x100 = Fixed.from_typed(typed)
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var chest_drop_chance: float:
	get:
		return Fixed.to_display(chest_drop_chance_x100)
	set(typed):
		chest_drop_chance_x100 = Fixed.from_typed(typed)
## Which chest a chest drop is (weighted).
@export var chest_drops: Array[ChestDrop] = []

@export_storage var key_drop_chance_x100: int = 0
@export_storage var golden_key_chance_x100: int = 0
@export_storage var chest_drop_chance_x100: int = 0

@export_group("")
## Spec playable-demo 3.11 (D29): shown when the party takes the stairs, before the next floor is built (a rest stop).
@export var rest_event: EventDefinition

const RARITY_PREFIX: String = "Item.Rarity."
## Spec keys-and-gear 2.1: Isaac's key cap.
const MAX_KEYS: int = 99


## True when this run uses keys at all (drops, a start stock or locks): the menu shows "Keys: n" (D13).
func uses_keys() -> bool:
	return starting_keys > 0 or key_drop_chance_x100 > 0 or chest_drop_chance_x100 > 0


## A pool candidate's weight ×100 with its rarity applied (spec playable-demo 3.7).
@warning_ignore("integer_division")
func weighted(entry: Resource) -> int:
	var base := maxi(int(entry.get("weight_x100")), 0)
	for tag in entry.get("tags"):
		if String(tag).begins_with(RARITY_PREFIX) and rarity_weights_x100.has(tag):
			return base * rarity_weights_x100[tag] / 100
	return base
