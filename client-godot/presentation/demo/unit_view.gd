## Demo unit (placeholder): a coloured cube. Root of unit_view.tscn: Body (MeshInstance3D), Audio, Label (Label3D).
##
## Spec animation-sets: UnitAnimator plays everything. The cube's motions (bob, hit pulse, fall over, cast hop…) are
## the default animation set, presentation/demo/animation_sets/default.tres, and abilities play as montages whose
## `execute` keys release the battle's gate. This script only colours the cube and greys it out when dead.
extends UnitAnimator

@onready var _body: MeshInstance3D = $Body


func _paint() -> void:
	# Spec cube-style: the unit's look (its colour override, rim, roughness); with no style registry this is today's material.
	var alive := body_color()
	var material := body_material(Color(0.35, 0.35, 0.35, alive.a) if is_dead else alive)  # dead grey keeps a see-through body's alpha
	_body.material_override = mark_stencil(material)
