## A chapter / floor theme (spec game-skeleton, section 3.1): which pools its floors draw from, how they're generated
## and how enemies scale.
@tool
class_name ChapterDefinition
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
## The chapter's own tag, e.g. Chapter.Basement.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var tags: Array[StringName] = []
@export var room_query: GameplayTagQuery
@export var encounter_query: GameplayTagQuery
@export var boss_encounter_query: GameplayTagQuery
@export var event_query: GameplayTagQuery
@export var floor_gen_rules: FloorGenRules
@export var scaling: ScalingRules
