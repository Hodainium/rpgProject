## Demo unit (placeholder): a coloured cube. Root of unit_view.tscn: Body (MeshInstance3D), Audio, Label (Label3D).
##
## Spec animation-sets: UnitAnimator plays everything. The cube's motions (bob, hit pulse, fall over, cast hop…) are
## the default animation set, presentation/demo/animation_sets/default.tres, and abilities play as montages whose
## `execute` keys release the battle's gate. This script only colours the cube and greys it out when dead.
extends UnitAnimator

@onready var _body: MeshInstance3D = $Body


func _paint() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.35, 0.35, 0.35) if is_dead else display_color
	_body.material_override = material
