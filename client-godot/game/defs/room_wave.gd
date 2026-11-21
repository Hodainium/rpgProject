## One wave of a challenge room (spec floor-rooms 3.1): a fixed encounter, or one picked from a query. With neither, the
## chapter's encounter query. A wave's difficulty comes only from what it draws, so nothing new reaches a battle snapshot.
@tool
class_name RoomWave
extends Resource

@export var encounter: EncounterDefinition
## Used when `encounter` is empty. Empty too: the chapter's encounter_query.
@export var content_query: GameplayTagQuery
