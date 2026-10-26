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
## Spec playable-demo 3.8: the chapter's floors take its bosses in a seeded rotation (never the same twice while it has
## two). Off: each floor picks by weight, as before.
@export var boss_rotation: bool = false
## Spec playable-demo 3.8: the route this chapter belongs to (Route.Light, Route.Dark), for a ROUTE floor slot after it.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var route_tag: StringName = &""
