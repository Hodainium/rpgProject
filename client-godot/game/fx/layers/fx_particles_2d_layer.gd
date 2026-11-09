## Particles in a 2D screen (spec vfx-framework 3.1): a GPUParticles2D for menus and cards. It sits at `anchor_point`
## of the effect's rectangle (0.5, 0.5 = the middle of a card) and, with `fit_to_anchor`, emits from a box as big as the
## rectangle (sparkles all over a card). Pixels for sizes and speeds. Same exports and bindings as the 3D layer.
class_name FxParticles2DLayer
extends FxParticlesLayer

## Multiplies the sprite (the default soft dot is 64 px).
@export var size_min: float = 0.3
@export var size_max: float = 0.8
@export var direction: Vector3 = Vector3(0, -1, 0)
@export_range(0.0, 180.0) var spread: float = 180.0
@export var speed_min: float = 80.0
@export var speed_max: float = 240.0
@export var gravity: Vector3 = Vector3(0, 120, 0)
@export var damping: float = 0.0
## Where in the effect's rectangle the emitter sits (0..1).
@export var anchor_point: Vector2 = Vector2(0.5, 0.5)
## Emit from a box the size of the rectangle instead of a point.
@export var fit_to_anchor: bool = false
## Replaces the generated process material (note: `fit_to_anchor` still sets its emission shape to a box).
@export var process_material_override: Material

const FIT_SIZE: StringName = &"fx_fit_size"


func kind() -> StringName:
	return &"particles2d"


func native_space() -> int:
	return Space.UI


func build() -> Node:
	var particles := GPUParticles2D.new()
	particles.emitting = false
	particles.one_shot = not loop
	particles.amount = amount
	particles.lifetime = lifetime
	particles.explosiveness = explosiveness
	particles.local_coords = local_coords
	particles.visibility_rect = Rect2(-640, -640, 1280, 1280)
	particles.texture = texture if texture != null else FxQuality.soft_dot()
	particles.process_material = process_material_override.duplicate() if process_material_override != null else _make_process_material()
	if additive:
		var canvas_material := CanvasItemMaterial.new()
		canvas_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		particles.material = canvas_material
	return particles


func start(node: Node) -> void:
	_place(node)
	super(node)


func update(node: Node, local_time: float, length_seconds: float, params: Dictionary) -> void:
	_place(node)
	super(node, local_time, length_seconds, params)


## Puts the emitter at the anchor point of the holder's rectangle (and sizes the emission box).
func _place(node: Node) -> void:
	var holder := node.get_parent() as Control
	if holder == null:
		return
	node.position = holder.size * anchor_point
	if fit_to_anchor and node.process_material is ParticleProcessMaterial:
		if node.has_meta(FIT_SIZE) and node.get_meta(FIT_SIZE) == holder.size:
			return  # unchanged: no material update this frame
		node.set_meta(FIT_SIZE, holder.size)
		var material := node.process_material as ParticleProcessMaterial
		material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		material.emission_box_extents = Vector3(maxf(holder.size.x * 0.5, 1.0), maxf(holder.size.y * 0.5, 1.0), 1.0)


func _make_process_material() -> ParticleProcessMaterial:
	var material := ParticleProcessMaterial.new()
	material.particle_flag_disable_z = true
	material.direction = direction
	material.spread = spread
	material.initial_velocity_min = speed_min
	material.initial_velocity_max = speed_max
	material.gravity = gravity
	material.damping_min = damping
	material.damping_max = damping
	material.scale_min = size_min
	material.scale_max = size_max
	_style(material)
	return material
