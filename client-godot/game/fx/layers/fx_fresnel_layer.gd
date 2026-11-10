## A fresnel rim glow on the anchor's own mesh (spec vfx-content-pass 3.6): the unit's silhouette lights up where its surface
## turns away from the camera, for status looks (a burning rim, a frost rim, a poison sheen) and hit flashes. Nothing is drawn
## off the model, so it can never intersect it. Works like FxMeshFlashLayer (the same overlay stack, restored when it ends) with
## a rim-and-shell shader instead of a flat tint. Bind `color`, `intensity`, `power`, `fill`, `grow`, `erosion`, `noise_scale`, `scroll`.
class_name FxFresnelLayer
extends FxMeshFlashLayer

const FRESNEL_SHADER: Shader = preload("res://game/fx/shaders/material/fresnel_overlay.gdshader")

## How thin the rim is (higher = a narrower edge).
@export var power: float = 2.5
## The shell look (spec 3.6): how much of the body glows besides the rim, how far the shell is pushed out, and the scrolling noise that
## eats it (erosion 0 = solid; scroll moves it up the body). All zero = the plain rim glow.
@export_range(0.0, 1.0) var fill: float = 0.0
@export var grow: float = 0.0
@export_range(0.0, 1.0) var erosion: float = 0.0
@export var noise_scale: float = 4.0
@export var scroll: float = 0.0


func kind() -> StringName:
	return &"fresnel"


func build() -> Node:
	# Everything an effect may bind is carried by the node, so one effect serves many statuses by parameters.
	return FxValueNode.new().declare({"color": color, "intensity": intensity, "power": power, "fill": fill, "grow": grow,
		"erosion": erosion, "noise_scale": noise_scale, "scroll": scroll})


func make_overlay() -> Material:
	var material := ShaderMaterial.new()
	material.shader = FRESNEL_SHADER
	return material


func set_strength(overlay: Material, node: Node, strength: float) -> void:
	var material := overlay as ShaderMaterial
	material.set_shader_parameter("color", node.get(&"color"))
	material.set_shader_parameter("intensity", node.get(&"intensity"))
	material.set_shader_parameter("power", node.get(&"power"))
	material.set_shader_parameter("strength", strength)
	material.set_shader_parameter("fill", node.get(&"fill"))
	material.set_shader_parameter("grow", node.get(&"grow"))
	material.set_shader_parameter("erosion", node.get(&"erosion"))
	material.set_shader_parameter("noise_scale", node.get(&"noise_scale"))
	material.set_shader_parameter("scroll", node.get(&"scroll"))
