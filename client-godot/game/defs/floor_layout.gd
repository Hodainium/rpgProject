## A hand-made floor (spec game-skeleton, section 3.1), loaded instead of generating. For testing and set pieces.
@tool
class_name FloorLayout
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var grid_size: Vector2i = Vector2i(9, 8)
@export var cells: Array[FloorLayoutCell] = []
