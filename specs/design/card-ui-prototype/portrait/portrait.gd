## Throwaway console command (scratchpad): one character cube alone, facing the camera, close camera, for a card portrait shot.
extends DevCommand


func _init() -> void:
	name = "portrait"
	usage = "portrait <unit id> [yaw]"
	help = "Shows one unit alone with its main look, close up, for a card portrait."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.size() < 1:
		return ctx.fail(usage)
	var room: Node3D = _room_view(ctx.console.tree.root)
	if room == null:
		return ctx.fail("no room view")
	for i in 3:
		await ctx.console.tree.process_frame
	var units_root: Node3D = room.get("_units_root")
	for child in units_root.get_children():
		child.visible = false
	(room.get("_props_root") as Node3D).visible = false
	var tree_root: Node = ctx.console.tree.root
	if tree_root.has_meta(&"portrait_view"):
		var old: Node = tree_root.get_meta(&"portrait_view")
		if is_instance_valid(old):
			old.queue_free()
	var registry: StyleRegistry = UnitStyle.registry()
	registry.facing_degrees = float(args[1]) if args.size() > 1 else 0.0
	var definition: UnitDefinition = ctx.content.units.get(StringName(args[0]))
	if definition == null:
		return ctx.fail("unknown unit %s" % args[0])
	var view: Node3D = room.call("_unit", Vector2i(6, 3), definition, &"")
	var ground := view.position.y
	view.position = Vector3(0, ground, 0)
	print("portrait ground ", ground)
	if view.has_method("set_stats"):
		view.set_stats("")
	tree_root.set_meta(&"portrait_view", view)
	_studio(room, Color(args[2]) if args.size() > 2 else Color(0.55, 0.65, 1.0), ground)
	_hide_ui(tree_root)
	_hide_meshes(room, units_root)
	var camera: Camera3D = room.get("_camera")
	camera.fov = 32.0
	camera.position = Vector3(0.0, ground + 0.75, 3.4)
	camera.look_at(Vector3(0, ground + 0.12, 0))
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.03, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.38, 0.5)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.3
	env.fog_enabled = true
	env.fog_light_color = Color(0.06, 0.06, 0.09)
	env.fog_density = 0.04
	camera.environment = env
	return "portrait %s" % args[0]


func _hide_meshes(node: Node, keep: Node) -> void:
	for child in node.get_children():
		if child == keep or child.name == "PortraitStudio":
			continue
		if child is GeometryInstance3D:
			(child as GeometryInstance3D).visible = false
		_hide_meshes(child, keep)


func _hide_ui(node: Node) -> void:
	for child in node.get_children():
		if child is CanvasLayer:
			child.visible = false
		elif child is Control and not (child.get_parent() is SubViewport):
			child.visible = false
		else:
			_hide_ui(child)


## A small photo studio in front of the room: a dark backdrop, a warm key, a coloured rim behind, a soft fill. Rebuilt per shot.
func _studio(room: Node3D, rim_color: Color, ground: float) -> void:
	var old := room.get_node_or_null("PortraitStudio")
	if old != null:
		room.remove_child(old)
		old.free()
	var studio := Node3D.new()
	studio.name = "PortraitStudio"
	studio.position.y = ground
	room.add_child(studio)
	var backdrop := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(14, 9)
	backdrop.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.055, 0.09)
	mat.roughness = 1.0
	backdrop.material_override = mat
	backdrop.position = Vector3(0, 2.0, -1.6)
	studio.add_child(backdrop)
	var floor := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(14, 8)
	floor.mesh = plane
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.015, 0.016, 0.025)
	fmat.roughness = 0.95
	floor.material_override = fmat
	floor.position = Vector3(0, -0.405, 0)
	studio.add_child(floor)
	var key := SpotLight3D.new()
	key.light_color = Color(1.0, 0.92, 0.8)
	key.light_energy = 0.9
	key.spot_range = 9.0
	key.spot_angle = 22.0
	key.shadow_enabled = true
	key.position = Vector3(2.0, 2.6, 2.6)
	studio.add_child(key)
	key.look_at(Vector3(0, 0.1, 0))
	var rim := OmniLight3D.new()
	rim.light_color = rim_color
	rim.light_energy = 5.0
	rim.omni_range = 3.5
	rim.position = Vector3(-0.8, 0.7, -0.9)
	studio.add_child(rim)
	var rim2 := OmniLight3D.new()
	rim2.light_color = rim_color
	rim2.light_energy = 1.6
	rim2.omni_range = 3.0
	rim2.position = Vector3(0.8, 0.5, -0.9)
	studio.add_child(rim2)
	var glow := OmniLight3D.new()
	glow.light_color = rim_color
	glow.light_energy = 0.8
	glow.omni_range = 2.6
	glow.position = Vector3(0, -0.3, -1.4)
	studio.add_child(glow)
	var fill := OmniLight3D.new()
	fill.light_color = Color(0.6, 0.7, 1.0)
	fill.light_energy = 0.8
	fill.omni_range = 5.0
	fill.position = Vector3(-2.0, 1.2, 2.0)
	studio.add_child(fill)
	var motes := CPUParticles3D.new()
	motes.amount = 70
	motes.lifetime = 3.0
	motes.preprocess = 3.0
	motes.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	motes.emission_box_extents = Vector3(1.4, 0.1, 0.7)
	motes.position = Vector3(0, -0.4, -0.4)
	motes.direction = Vector3(0, 1, 0)
	motes.spread = 12.0
	motes.gravity = Vector3(0, 0.05, 0)
	motes.initial_velocity_min = 0.25
	motes.initial_velocity_max = 0.6
	motes.scale_amount_min = 0.5
	motes.scale_amount_max = 1.2
	var mote_mesh := SphereMesh.new()
	mote_mesh.radius = 0.012
	mote_mesh.height = 0.024
	var mote_mat := StandardMaterial3D.new()
	mote_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mote_mat.albedo_color = rim_color
	mote_mat.emission_enabled = true
	mote_mat.emission = rim_color
	mote_mat.emission_energy_multiplier = 4.0
	mote_mesh.material = mote_mat
	motes.mesh = mote_mesh
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0))
	fade.add_point(0.2, Color(1, 1, 1, 1))
	fade.set_color(fade.get_point_count() - 1, Color(1, 1, 1, 0))
	motes.color_ramp = fade
	mote_mat.vertex_color_use_as_albedo = true
	mote_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	studio.add_child(motes)


func _room_view(node: Node) -> Node3D:
	if node is Node3D and node.has_method("_unit") and node.get("_units_root") != null:
		return node
	for child in node.get_children():
		var found := _room_view(child)
		if found != null:
			return found
	return null
