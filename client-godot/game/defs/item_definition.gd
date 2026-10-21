## An item (spec game-skeleton, section 3.1). Every item is held by one character, and any character can hold it.
##
## Passive items grant their ability set to the holder or the whole party. Usable items sit in one of the holder's
## use slots and grant use_ability: an ordinary ability (its targeting decides one, several or blast), usable in
## battle and on the map, either once (CONSUMABLE) or again after cooldown_battles won battles (COOLDOWN).
## A Birthright-like item (a different effect per holder) is plain data: grant one ability per character, each with an
## activation_query requiring that character's tag (Character.<Name>, from CharacterDefinition.tags).
@tool
class_name ItemDefinition
extends Resource

enum Kind { PASSIVE, USABLE }
enum AppliesTo { HOLDER, PARTY }
enum UseMode { CONSUMABLE, COOLDOWN }

@export var id: StringName = &""
@export var display_name: String = ""
## One line for the pickup and party panels (spec item-pass 3.5).
@export_multiline var description: String = ""
@export var icon: Texture2D
@export var mesh: Mesh
## Pools (Pool.Treasure, Pool.Shop...) and rarity (Item.Rarity.Rare...).
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var tags: Array[StringName] = []
@export var price: int = 15
@export var kind: Kind = Kind.PASSIVE
@export var grants: AbilitySet
@export var applies_to: AppliesTo = AppliesTo.HOLDER

@export_group("Usable")
## A BattleAbility scene. Its activation_query decides battle-only / map-only / both.
@export var use_ability: PackedScene
@export var use_mode: UseMode = UseMode.CONSUMABLE
@export var cooldown_battles: int = 1
## Extra use slots for the holder (1 for a Schoolbag-like item).
@export var extra_use_slots: int = 0

@export_group("Run hooks")
@export var on_pickup: Array[RunOutcome] = []
@export var on_floor_start: Array[RunOutcome] = []
@export var on_room_cleared: Array[RunOutcome] = []

@export_group("")
## Pick weight as typed. Editor-only view of weight_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var weight: float:
	get:
		return Fixed.to_display(weight_x100)
	set(typed):
		weight_x100 = Fixed.from_typed(typed)

@export_storage var weight_x100: int = 100


func is_usable() -> bool:
	return kind == Kind.USABLE and use_ability != null


## The ability tag of use_ability.
func use_ability_tag() -> StringName:
	return SkillTags.tag_of(use_ability)
