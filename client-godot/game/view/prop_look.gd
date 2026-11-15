## Spec cube-style 6a Set K: how a pickup on the floor looks (a shop key, an armor piece): one AttachmentShape floating above its cell,
## turning and bobbing, with an optional rarity outline and a looping effect. Listed in a PropStyle. Presentation only.
class_name PropLook
extends Resource

@export var shape: AttachmentShape
## Where the shape's origin sits above the floor's top (the room's floor is at y -0.5 in cell space).
@export var offset: Vector3 = Vector3(0, 0.55, 0)
@export var rotation_degrees: Vector3 = Vector3.ZERO
@export var scale: Vector3 = Vector3.ONE
## Turns a second around Y (0 = still).
@export var spin_speed: float = 0.25
## Units up and down, and cycles a second (0 amount = no bob).
@export var bob_amount: float = 0.06
@export var bob_speed: float = 0.5
## Width of the silhouette outline in the shape's own units, so it scales with `scale` (an inverted hull drawn after each part);
## 0 = none. Its colour is the prop's colour (an armor piece's rarity), else outline_color.
@export_range(0.0, 0.2) var outline: float = 0.0
@export var outline_color: Color = Color.WHITE
## A looping effect played on the prop while it is shown; its `color` parameter (when it has one and effect_params leaves it
## unset) takes the prop's colour when the prop has one (an armor piece's rarity), else keeps the effect's default.
@export var effect: FxDefinition
@export var effect_params: Dictionary = {}
## Height of the name label above the floor.
@export var label_height: float = 1.15
