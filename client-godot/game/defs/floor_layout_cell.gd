## One room of a hand-made floor (spec game-skeleton, section 3.1).
@tool
class_name FloorLayoutCell
extends Resource

enum Role { NORMAL, START, BOSS, SPECIAL }

@export var cell: Vector2i = Vector2i.ZERO
@export var room: RoomDefinition
@export var role: Role = Role.NORMAL
## Optional overrides of the room's content.
@export var encounter: EncounterDefinition
@export var event: EventDefinition
