## Spec cube-style 3.6: how a chapter's rooms look: the environment (tonemap, glow, ambient occlusion, ambient light, fog), a
## three-point light rig and the room box's floor and wall materials. Listed per chapter id in a StyleRegistry; StageRig shows it.
## Presentation only: never in a hash, snapshot or upload.
class_name StageMood
extends Resource

@export var display_name: String = ""
## Null = no WorldEnvironment (the engine's defaults, today's look).
@export var environment: Environment
## Null = that light is off.
@export var key_light: MoodLight
@export var fill_light: MoodLight
@export var rim_light: MoodLight
## Null = the engine's default material (today's white room).
@export var floor_material: Material
@export var wall_material: Material
## How deep the wall blocks' edges and corners are chamfered, in metres (0 = sharp boxes). A wall block is 1 × 0.6 × 1.
@export_range(0.0, 0.25, 0.01) var wall_bevel: float = 0.06

## The deepest bevel a wall block takes (below half its 0.6 height); the validator reports a mood outside 0..this.
const MAX_WALL_BEVEL: float = 0.25
