## Particles in the 3D world (spec vfx-framework 3.1): a GPUParticles3D with a ParticleProcessMaterial built from the
## exports (or your own process material, including a custom `shader_type particles` ShaderMaterial). Billboarded
## quads, additive by default. Bind any property with "amount", "lifetime", "process_material:color",
## "draw_pass_1:material:shader_parameter/depth_bias"… Quality scales the amount.
class_name FxParticles3DLayer
extends FxParticlesLayer

const PARTICLE_SHADER: Shader = preload("res://game/fx/shaders/material/particle_3d.gdshader")

@export var size_min: float = 0.1
@export var size_max: float = 0.25
@export var direction: Vector3 = Vector3.UP
@export_range(0.0, 180.0) var spread: float = 180.0
@export var speed_min: float = 1.0
@export var speed_max: float = 3.0
@export var gravity: Vector3 = Vector3(0, -2, 0)
@export var damping: float = 0.0
## Pull toward (negative) or push away from (positive) the emitter's centre, in units/s^2: a collapse into a point, a swirl outward.
@export var radial_accel: float = 0.0
## Each particle turns this many degrees a second (a spinning coin, a tumbling shard, a fluttering feather); the sprite is rotated, camera-facing.
@export var spin_min: float = 0.0
@export var spin_max: float = 0.0
## A sphere emission shape when above 0.
@export var emission_radius: float = 0.0
## A ring around the Y axis when above 0 (stars circling a head): its radius, height and the inner radius (0 = a filled disc).
@export var emission_ring_radius: float = 0.0
## Moves the emission shape (a ring above a head, a spray from a hand).
@export var emission_offset: Vector3 = Vector3.ZERO
## Replaces the generated process material (a ParticleProcessMaterial or a ShaderMaterial with a particles shader).
@export var process_material_override: Material
@export var draw_mesh: Mesh
## World units the depth test sees each particle closer to the camera (spec vfx-content-pass 3.6). A flame or glow is a flat
## quad centred on the unit, and the unit's own mesh would cut it in half; the bias lifts it past the unit's surface, while a wall
## or another unit that really is in front still hides it. About the target's radius; bind it to an effect parameter.
@export var depth_bias: float = 0.0
## Soft particles (spec vfx-content-pass 3.6): a particle fades out over this many world units where it nears scene geometry
## (its depth, with the bias applied, against the depth buffer), which removes the hard cut line against walls and other units.
## 0 = off.
@export var soft_distance: float = 0.0
## Surface emission (spec 3.6): particles start on the surface of the target's first mesh instead of at one point, so a flame or a
## bubble is born on the body. The points are sampled once per mesh (area-weighted) and the emitter follows the mesh every tick, which
## is right for a unit that moves as a rigid whole; a skinned model emits from a bone-attached layer instead.
@export var emit_from_mesh: bool = false
## Spec vfx-stencil 3.3: do the particles draw over the unit they sit on? AUTO: yes (a flame on the body, sparks off a hit). Only the
## generated draw material takes part; a custom `draw_mesh` keeps its own material and the plain depth test.
@export var over_own_unit: FxLayer.OverOwnUnit = FxLayer.OverOwnUnit.AUTO
@export var emission_point_count: int = 128
## Only faces whose outward normal points at least this far up (-1 = every face, 0 = not the underside, 0.5 = the top and gentle slopes). A flame
## should not be born under the unit and burn through the floor.
@export_range(-1.0, 1.0) var emission_min_normal_y: float = -1.0


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
	material.radial_accel_min = radial_accel
	material.radial_accel_max = radial_accel
	material.angular_velocity_min = spin_min
	material.angular_velocity_max = spin_max
	material.scale_min = size_min
	material.scale_max = size_max
	material.emission_shape_offset = emission_offset
	_style(material)
	if emission_ring_radius > 0.0:
		material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
		material.emission_ring_axis = Vector3.UP
		material.emission_ring_radius = emission_ring_radius
		material.emission_ring_inner_radius = emission_ring_radius * 0.98
		material.emission_ring_height = 0.0
	elif emission_radius > 0.0:
		material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		material.emission_sphere_radius = emission_radius
	return material


func _make_draw_material() -> ShaderMaterial:
	var material := FxStencilMaterial.new()  # spec vfx-stencil 3.4: a shader material with a stencil setting
	material.base_shader = PARTICLE_SHADER
	material.set_shader_parameter("albedo_texture", texture if texture != null else FxQuality.soft_dot())
	material.set_shader_parameter("h_frames", maxi(h_frames, 1))
	material.set_shader_parameter("v_frames", maxi(v_frames, 1))
	material.set_shader_parameter("additive", 1.0 if additive else 0.0)
	material.set_shader_parameter("depth_bias", depth_bias)
	material.set_shader_parameter("soft_distance", soft_distance)
	return material


const EMIT_MESH: StringName = &"fx_emit_mesh"
## "mesh id:count:normal" -> [WeakRef to the mesh, its sampled points as a texture] (the points are the mesh's, whoever plays the
## effect). An entry whose mesh is gone is dropped (review fix: freed meshes' textures were kept for the whole session, and a
## recycled instance id could have answered with another mesh's points).
static var _points: Dictionary = {}


func apply(node: Node, params: Dictionary, anchor: FxAnchor, quality: int, definition: FxDefinition) -> void:
	super(node, params, anchor, quality, definition)
	var draw := _stencil_material(node)
	if draw != null:
		draw.stencil_unit = stencil_value(anchor, PARTICLE_SHADER, over_own_unit)
	node.set_meta(EMIT_MESH, null)
	if not emit_from_mesh or process_material_override != null:
		return
	var body := FxAttach.first_mesh(anchor.world_node())
	if body == null or body.mesh == null:
		return  # no mesh to emit from: the layer keeps its own emission shape
	var material := (node as GPUParticles3D).process_material as ParticleProcessMaterial
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	material.emission_point_texture = points_for(body.mesh, emission_point_count, emission_min_normal_y)
	material.emission_point_count = emission_point_count
	node.set_meta(EMIT_MESH, weakref(body))
	_follow_mesh(node)


func update(node: Node, local_time: float, length_seconds: float, params: Dictionary) -> void:
	_follow_mesh(node)
	super(node, local_time, length_seconds, params)
	follow_stencil(node, _stencil_material(node), PARTICLE_SHADER, over_own_unit)


func over_own_default() -> bool:
	return true


func stencil_shader() -> Shader:
	return PARTICLE_SHADER if draw_mesh == null and draws_over_own_unit(over_own_unit) else null


## The generated draw material (an FxStencilMaterial), or null for a custom draw mesh.
func _stencil_material(node: Node) -> FxStencilMaterial:
	var particles := node as GPUParticles3D
	var mesh := particles.draw_pass_1 as PrimitiveMesh if particles != null else null
	return mesh.material as FxStencilMaterial if mesh != null else null


## The emitter sits on the mesh it samples, so the points stay on its surface while the unit moves.
func _follow_mesh(node: Node) -> void:
	var reference: WeakRef = FxLayer.meta_of(node, EMIT_MESH)
	var body: Node3D = reference.get_ref() if reference != null else null
	if body != null and body.is_inside_tree() and node.is_inside_tree():
		(node as Node3D).global_transform = body.global_transform


## `count` points spread over the surface of `mesh` (area-weighted, in the mesh's own space) as a one-row RGBF texture, the form
## Godot's point emission reads. Cached per mesh; the generator is unseeded-independent (a fixed seed), so a mesh always gets the
## same points.
static func points_for(mesh: Mesh, count: int, min_normal_y: float = -1.0) -> ImageTexture:
	var key := "%d:%d:%s" % [mesh.get_instance_id(), count, min_normal_y]
	if _points.has(key) and (_points[key][0] as WeakRef).get_ref() == mesh:
		return _points[key][1]
	for stale in _points.keys().filter(func(k) -> bool: return (_points[k][0] as WeakRef).get_ref() == null):
		_points.erase(stale)
	var faces := mesh.get_faces()
	var image := Image.create(count, 1, false, Image.FORMAT_RGBF)
	var triangles := faces.size() / 3
	if triangles > 0:
		var cumulative := PackedFloat32Array()
		var total := 0.0
		for index in triangles:
			var a := faces[index * 3]
			var b := faces[index * 3 + 1]
			var c := faces[index * 3 + 2]
			var normal := (b - a).cross(c - a)
			# Godot's front faces wind clockwise, so the cross product points inward: the outward normal is its negative.
			if normal.length() > 0.0 and -normal.normalized().y >= min_normal_y:
				total += normal.length() * 0.5
			cumulative.append(total)
		var rng := RandomNumberGenerator.new()
		rng.seed = 1
		for slot in (count if total > 0.0 else 0):
			var pick := rng.randf() * total
			var triangle := cumulative.bsearch(pick)
			triangle = mini(triangle, triangles - 1)
			var u := rng.randf()
			var v := rng.randf()
			if u + v > 1.0:
				u = 1.0 - u
				v = 1.0 - v
			var a := faces[triangle * 3]
			var point := a + (faces[triangle * 3 + 1] - a) * u + (faces[triangle * 3 + 2] - a) * v
			image.set_pixel(slot, 0, Color(point.x, point.y, point.z))
	var texture := ImageTexture.create_from_image(image)
	_points[key] = [weakref(mesh), texture]
	return texture


func extra_problems(_definition: FxDefinition, _probe: Node) -> PackedStringArray:
	var out := PackedStringArray()
	if over_own_unit == OverOwnUnit.ON and draw_mesh != null:
		out.append("fx_stencil_include_missing: particles layer '%s' draws over its unit, but a custom draw_mesh keeps its own material" % id)
	return out
