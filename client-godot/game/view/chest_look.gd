## Spec cube-style 6a Set K: how a chest on the floor looks in its three states: closed, open and filled (the lid up, a glow and the
## reward showing), open and empty (the lid up, dark inside). One body and one lid turning on a hinge, so 5a5 `floor-chests` can
## animate the lid. Listed in a PropStyle by chest id. Presentation only.
class_name ChestLook
extends Resource

enum State { CLOSED, OPEN_FILLED, OPEN_EMPTY }

const STATE_NAMES: Array[String] = ["closed", "filled", "empty"]

## The box (its origin on the floor, its front +Z).
@export var body: AttachmentShape
## The lid, modelled closed with its hinge line at the origin (the lid's back edge, along X).
@export var lid: AttachmentShape
## Where the hinge sits on the body.
@export var hinge: Vector3 = Vector3(0, 0.4, -0.25)
## How far the lid turns back when open (degrees around the hinge, X).
@export_range(0.0, 150.0) var open_degrees: float = 105.0
## Shown inside an open chest that still holds its reward (a glow surface, coins); null = nothing.
@export var filled_inside: AttachmentShape
## Shown inside an open, emptied chest (a dark floor); null = nothing.
@export var empty_inside: AttachmentShape
## A looping effect over an open, filled chest (the reward's glow); null = none.
@export var filled_effect: FxDefinition
@export var filled_params: Dictionary = {}
## Tints the tintable parts of body and lid (the gilded chest's gold); unset = the parts' own colours.
@export var use_tint: bool = false
@export var tint: Color = Color.WHITE
@export var offset: Vector3 = Vector3.ZERO
@export var rotation_degrees: Vector3 = Vector3.ZERO
@export var scale: Vector3 = Vector3.ONE
@export var label_height: float = 1.2


static func state_named(text: String) -> int:
	return STATE_NAMES.find(text)
