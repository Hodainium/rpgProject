## A room (spec game-skeleton, section 3.1). The floor generator picks rooms whose doors fit their map cell.
@tool
class_name RoomDefinition
extends Resource

enum ContentMode { NONE, ENCOUNTER, ENCOUNTER_QUERY, EVENT, EVENT_QUERY }

## Door bits, matching the `doors` flags.
const DOOR_N: int = 1
const DOOR_E: int = 2
const DOOR_S: int = 4
const DOOR_W: int = 8
## Room grid size in cells (fixed for now; sizes and shapes come with the room editor).
const GRID := Vector2i(13, 7)

@export var id: StringName = &""
@export var display_name: String = ""
## Room type (Room.Type.Normal...) and the chapters it belongs to (Chapter.Basement...).
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var tags: Array[StringName] = []
## Sides that MAY have a door. The generator only uses a room whose doors cover every neighbour of its cell.
@export_flags("North", "East", "South", "West") var doors: int = 15
## Fewest doors this room accepts; 1 means it can be a dead end.
@export_range(1, 4) var min_doors: int = 1
@export var content_mode: ContentMode = ContentMode.NONE
@export var encounter: EncounterDefinition
@export var event: EventDefinition
## Pool for the *_QUERY modes. Empty uses the chapter's encounter or event query.
@export var content_query: GameplayTagQuery
@export var placements: Array[RoomPlacement] = []

## Pick weight as typed. Editor-only view of weight_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var weight: float:
	get:
		return Fixed.to_display(weight_x100)
	set(typed):
		weight_x100 = Fixed.from_typed(typed)

@export_storage var weight_x100: int = 100


static func door_count(mask: int) -> int:
	var count := 0
	for bit in [DOOR_N, DOOR_E, DOOR_S, DOOR_W]:
		if mask & bit:
			count += 1
	return count


## True when this room can sit in a cell whose neighbours need `mask`.
func fits(mask: int) -> bool:
	return (doors & mask) == mask and door_count(mask) >= min_doors
