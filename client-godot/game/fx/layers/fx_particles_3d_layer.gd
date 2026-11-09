## Particles in the 3D world (spec vfx-framework 3.1): a GPUParticles3D with a ParticleProcessMaterial built from the
## exports (or your own process material, including a custom `shader_type particles` ShaderMaterial). Billboarded
## quads, additive by default. Bind any property with "amount", "lifetime", "process_material:color",
## "draw_pass_1:material:albedo_color"… Quality scales the amount.
class_name FxParticles3DLayer
extends FxParticlesLayer

@export var size_min: float = 0.1
@export var size_max: float = 0.25
@export var direction: Vector3 = Vector3.UP
@export_range(0.0, 180.0) var spread: float = 180.0
@export var speed_min: float = 1.0
@export var speed_max: float = 3.0
@export var gravity: Vector3 = Vector3(0, -2, 0)
@export var damping: float = 0.0
## A sphere emission shape when above 0.
@export var emission_radius: float = 0.0
## Replaces the generated process material (a ParticleProcessMaterial or a ShaderMaterial with a particles shader).
@export var process_material_override: Material
@export var draw_mesh: Mesh


func kind() -> StringName:
	return &"particles3d"


func native_space() -> int:
	return Space.WORLD_3D


func build() -> Node:
	var particles := GPUParticles3D.new()
	particles.emitting = false
	particles.one_shot = not loop
	particles.amount = amount
	particles.lifetime = lifetime
	particles.explosiveness = explosiveness
	particles.local_coords = local_coords
	particles.visibility_aabb = AABB(Vector3(-6, -6, -6), Vector3(12, 12, 12))
	particles.process_material = process_material_override.duplicate() if process_material_override != null else _make_process_material()
	var mesh: Mesh = draw_mesh.duplicate() if draw_mesh != null else QuadMesh.new()
	if draw_mesh == null:
		mesh.material = _make_draw_material()
	particles.draw_pass_1 = mesh
	return particles


func _make_process_material() -> ParticleProcessMaterial:
	var material := ParticleProcessMaterial.new()
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
	if emission_radius > 0.0:
		material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		material.emission_sphere_radius = emission_radius
	return material


func _make_draw_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.billboard_keep_scale = true
	material.albedo_texture = texture if texture != null else FxQuality.soft_dot()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material
