## One floor of a run (spec game-skeleton, section 3.1).
@tool
class_name FloorSlot
extends Resource

## One is picked per run (alt paths).
@export var chapters: Array[ChapterDefinition] = []
## Delirium-style: rooms come from every chapter's room pool.
@export var rooms_from_any_chapter: bool = false
## Optional hand-made floor, used instead of generating.
@export var layout: FloorLayout
