## Spec cube-style (round 1): looks resolve exact > tag rule > default, variants fall back to their base, moods and camera framings
## resolve, the stage rig shows a mood (or today's single light), unit views paint in their look and keep the stencil stamp, the
## validator and the `style` command work, and nothing headless loads the style or reaches the ruleset. Registries are built in
## code here; one smoke test reads the demo registry.
extends TestCase

const PROBE_VIEW := "res://tests/fixtures/views/probe_view.tscn"


func after_each() -> void:
	UnitStyle.reset()
	super()


func _look(rim: float = -1.0, color := Color(0, 0, 0, 0), roughness: float = -1.0) -> UnitLook:
	var look := UnitLook.new()
	look.rim = rim
	look.use_color_override = color.a > 0.0
	look.color_override = color
	look.roughness = roughness
	return look


func _unit(id: StringName, tags: Array = []) -> UnitDefinition:
	var unit := UnitDefinition.new()
	unit.id = id
	unit.tags.assign(tags)
	return unit


func _rule(tag: StringName, look: UnitLook) -> UnitLookRule:
	var rule := UnitLookRule.new()
	var query := GameplayTagQuery.new()
	var wanted: Array[StringName] = [tag]
	query.require_any_tags = wanted
	rule.query = query
	rule.look = look
	return rule


func _mood(title: String) -> StageMood:
	var mood := StageMood.new()
	mood.display_name = title
	mood.environment = Environment.new()
	mood.key_light = MoodLight.new()
	mood.rim_light = MoodLight.new()
	mood.rim_light.energy = 2.0
	mood.floor_material = StandardMaterial3D.new()
	return mood


func _registry() -> StyleRegistry:
	var registry := StyleRegistry.new()
	registry.default_look = _look(0.5, Color(0, 0, 0, 0), 0.4)
	registry.tag_rules.append(_rule(&"Enemy.Boss", _look(0.9, Color.RED)))
	registry.looks[&"u.exact"] = _look(-1.0, Color.BLUE)
	registry.default_mood = _mood("default")
	registry.moods[&"chapter.a"] = _mood("a")
	return registry


func test_looks_resolve_exact_then_rule_then_default() -> void:
	var registry := _registry()
	var plain := registry.look_for(_unit(&"u.plain"))
	eq(plain.rim, 0.5, "a unit with nothing of its own takes the default look")
	check(not plain.use_color_override, "and no colour override")
	var picked := UnitLook.new()
	picked.color_override = Color(1, 0, 0, 0)
	picked.use_color_override = true
	eq(picked.body_color(Color.GREEN), Color(1, 0, 0, 0), "the switch decides, not the picker's alpha")
	eq(registry.look_source(_unit(&"u.plain")), "default", "source: default")
	var boss := registry.look_for(_unit(&"u.boss", [&"Enemy.Boss"]))
	eq(boss.rim, 0.9, "a tag rule beats the default")
	eq(boss.color_override, Color.RED, "the rule's colour")
	eq(boss.roughness, 0.4, "what the rule leaves unset comes from the default")
	eq(registry.look_source(_unit(&"u.boss", [&"Enemy.Boss"])), "rule 0", "source: the rule's index")
	var exact := registry.look_for(_unit(&"u.exact", [&"Enemy.Boss"]))
	eq(exact.color_override, Color.BLUE, "an exact look beats the rule")
	eq(exact.rim, 0.9, "its unset rim comes from the matching rule")
	eq(exact.roughness, 0.4, "and its roughness from the default")
	eq(registry.look_source(_unit(&"u.exact")), "exact", "source: exact")
	check(registry.look_for(null) != null, "a missing definition still gets a look")


func test_a_variant_falls_back_to_its_base() -> void:
	var main := _registry()
	var variant := StyleRegistry.new()
	variant.base = main
	variant.battle_camera = CameraFraming.new()
	variant.battle_camera.fov = 50.0
	eq(variant.look_for(_unit(&"u.exact")).color_override, Color.BLUE, "looks come from the base")
	eq(variant.mood_for(&"chapter.a").display_name, "a", "moods come from the base")
	eq(variant.mood_for(&"chapter.unknown").display_name, "default", "and the default mood")
	eq(variant.battle_framing().fov, 50.0, "the variant's own battle framing")
	eq(variant.explore_framing().fov, CameraFraming.today().fov, "an unset exploration framing is today's")
	var overview := StyleRegistry.new()
	overview.explore_camera = CameraFraming.new()
	overview.explore_camera.fov = 30.0
	eq(overview.battle_framing().fov, CameraFraming.today().fov, "no battle framing = today's camera, not the exploration one")
	check(variant.mood_chapters().has(&"chapter.a"), "the base's chapters are listed")


func test_a_variants_partial_look_sets_only_what_it_changes() -> void:
	var main := _registry()
	var variant := StyleRegistry.new()
	variant.base = main
	variant.default_look = _look(0.3)
	variant.looks[&"u.exact"] = _look(0.8)
	var plain := variant.look_for(_unit(&"u.plain"))
	eq(plain.rim, 0.3, "the variant's default rim")
	eq(plain.roughness, 0.4, "the base default's roughness stays")
	var exact := variant.look_for(_unit(&"u.exact"))
	eq(exact.rim, 0.8, "the variant's exact rim")
	eq(exact.color_override, Color.BLUE, "the base's exact colour stays")


func test_a_new_framing_stops_the_running_camera_move() -> void:
	var camera := Camera3D.new()
	host.add_child(camera)
	var far := CameraFraming.today()
	var near := CameraFraming.new()
	near.position = Vector3(0, 3, 4)
	var moving := near.tween_to(camera, 5.0)
	check(moving != null and moving.is_valid(), "a move starts")
	far.apply_to(camera)
	check(not moving.is_valid(), "an instant framing kills the running move")
	eq(camera.position, far.position, "and stays put")
	check(far.tween_to(camera, 5.0) == null, "a camera already at the framing makes no tween")
	var other := CameraFraming.new()
	other.position = Vector3(5, 5, 5)
	var first := near.tween_to(camera, 5.0)
	var second := other.tween_to(camera, 5.0)
	check(not first.is_valid() and second.is_valid(), "a new move replaces the old one")
	CameraFraming.stop_move(camera)
	check(not second.is_valid(), "stop_move stops it")
	camera.queue_free()


func test_a_variants_default_mood_wins_over_its_base_chapters() -> void:
	var main := _registry()
	var variant := StyleRegistry.new()
	variant.base = main
	eq(variant.mood_for(&"chapter.a").display_name, "a", "a variant with no moods shows the base's chapter mood")
	variant.default_mood = _mood("everywhere")
	eq(variant.mood_for(&"chapter.a").display_name, "everywhere", "its own default mood wins over the base's chapters")
	variant.moods[&"chapter.a"] = _mood("own a")
	eq(variant.mood_for(&"chapter.a").display_name, "own a", "and its own chapter mood over its default")


func test_validator_reports_a_base_problem_once() -> void:
	var content := fixtures()
	var main := StyleRegistry.new()
	main.looks[&"no.such.unit"] = _look()
	var variant := StyleRegistry.new()
	variant.base = main
	eq(StyleValidator.validate(variant, content, "variant").size(), 0, "a variant is not blamed for its base's entries")
	check(StyleValidator.validate(main, content, "main").size() > 0, "the base reports them itself")


func test_camera_framing_defaults_are_todays_camera() -> void:
	var framing := CameraFraming.today()
	eq(framing.position, Vector3(0, 9, 8), "today's position")
	eq(framing.rotation_degrees, Vector3(-50, 0, 0), "today's pitch")
	var camera := Camera3D.new()
	eq(framing.fov, camera.fov, "the engine's default fov")
	var close := CameraFraming.new()
	close.position = Vector3(0, 3, 4)
	check(close.tween_to(camera, 0.5) == null, "a camera outside the tree moves at once")
	eq(camera.position, Vector3(0, 3, 4), "applied")
	camera.free()


func test_headless_loads_no_registry_and_use_sets_one() -> void:
	UnitStyle.reset()
	check(UnitStyle.registry() == null, "a headless process loads no style registry")
	check(UnitStyle.look_for(_unit(&"u.plain")) == null, "so views paint today's look")
	check(UnitStyle.mood_for(&"chapter.a") == null, "and rooms show today's light")
	eq(UnitStyle.battle_framing().position, CameraFraming.today().position, "and today's camera")
	UnitStyle.use(_registry(), "test")
	eq(UnitStyle.mood_for(&"chapter.a").display_name, "a", "use() sets one, headless too")
	UnitStyle.mood_override = &"chapter.unknown"
	eq(UnitStyle.mood_for(&"chapter.a").display_name, "default", "the console's mood override wins over the room's chapter")
	eq(UnitStyle.use_path("res://nope.tres"), "no file res://nope.tres", "a missing variant is refused")


func test_style_stays_out_of_the_ruleset() -> void:
	if skip_in_export():
		return
	for path in RulesetVersion.files():
		check(not path.begins_with("res://presentation/"), "presentation/ is not a ruleset root: %s" % path)
	for script in ["camera_framing", "mood_light", "stage_mood", "unit_look", "unit_look_rule", "style_registry", "unit_style", "stage_rig"]:
		var source := FileAccess.get_file_as_string("res://game/view/%s.gd" % script)
		check(not source.contains("RandomNumberGenerator") and not source.contains("randi") and not source.contains("randf"),
			"%s draws from no RNG" % script)
	for root in ["res://combat/"]:
		for path in _scripts(root):
			var source := FileAccess.get_file_as_string(path)
			check(not source.contains("UnitStyle") and not source.contains("StyleRegistry") and not source.contains("StageMood"),
				"combat never names the style: %s" % path)


func _scripts(directory: String) -> PackedStringArray:
	var found := PackedStringArray()
	for file in DirAccess.get_files_at(directory):
		if file.ends_with(".gd"):
			found.append(directory + file)
	for sub in DirAccess.get_directories_at(directory):
		found.append_array(_scripts(directory + sub + "/"))
	return found


func test_stage_rig_shows_a_mood_or_todays_light() -> void:
	var rig := StageRig.new()
	host.add_child(rig)
	check(rig.world_environment.environment == null, "no mood: no environment")
	check(rig.key.visible and not rig.fill.visible and not rig.rim.visible, "no mood: today's single light")
	eq(rig.key.rotation_degrees, Vector3(-60, 30, 0), "at today's angle")
	eq(rig.key.light_energy, 1.0, "with today's energy")
	check(not rig.key.shadow_enabled, "and no shadows")
	var mood := _mood("a")
	rig.apply(mood)
	check(rig.world_environment.environment == mood.environment, "the mood's environment")
	check(rig.key.visible and rig.rim.visible and not rig.fill.visible, "lights the mood leaves empty are off")
	eq(rig.rim.light_energy, 2.0, "the rim light's energy")
	check(rig.floor_material() == mood.floor_material and rig.wall_material() == null, "the room box's materials")
	rig.active = false
	check(rig.world_environment.environment == null, "a hidden room view tints no menu")
	rig.active = true
	check(rig.world_environment.environment == mood.environment, "and gets it back")
	rig.apply(null)
	check(rig.world_environment.environment == null and not rig.rim.visible, "back to today's look")
	rig.queue_free()


func test_unit_view_paints_its_look_and_keeps_the_stencil_stamp() -> void:
	var definition := _unit(&"u.exact")
	definition.display_color = Color.GREEN
	var probe := load(PROBE_VIEW) as PackedScene
	var plain: UnitAnimator = UnitAnimator.instantiate_for(definition, probe)
	check(plain.look == null, "no registry: no look")
	eq(plain.body_color(), Color.WHITE, "the colour comes from setup (display_color), as today")
	var material := plain.body_material(Color.GREEN)
	check(not material.rim_enabled, "today's material has no rim")
	plain.free()
	UnitStyle.use(_registry(), "test")
	var styled: UnitAnimator = UnitAnimator.instantiate_for(definition, probe)
	host.add_child(styled)
	check(styled.look != null and styled.unit_definition == definition, "instantiate_for resolves the look")
	styled.setup("x", definition.display_color)
	eq(styled.body_color(), Color.BLUE, "the look's colour override")
	var body := styled.body_material(styled.body_color())
	check(body.rim_enabled and is_equal_approx(body.rim, 0.5), "the default look's rim")
	check(is_equal_approx(body.roughness, 0.4), "and roughness (a 32-bit material float)")
	styled.stencil_value = StencilIds.values_for(1)[0]
	var stamped := styled.mark_stencil(body) as BaseMaterial3D
	eq(stamped.stencil_mode, BaseMaterial3D.STENCIL_MODE_CUSTOM, "a styled body still takes the stencil stamp")
	check(stamped.rim_enabled, "and keeps its rim")
	UnitStyle.use(null)
	styled.restyle()
	check(styled.look == null, "restyle() follows the registry in use")
	styled.queue_free()


func test_validator_codes() -> void:
	var content := fixtures()
	var registry := StyleRegistry.new()
	registry.looks[&"no.such.unit"] = _look()
	registry.looks[&"fixture.unit.brute"] = null
	registry.moods[&"no.such.chapter"] = _mood("x")
	registry.tag_rules.append(UnitLookRule.new())
	var quiet: Array = []
	for issue in StyleValidator.validate(registry, content, "test"):
		quiet.append(issue.code)
	check(not quiet.has("style_unit_without_look"), "units without a look are not reported unless asked (validate_content)")
	var codes: Array = []
	for issue in StyleValidator.validate(registry, content, "test", true):
		codes.append(issue.code)
	for code in ["style_look_unknown_unit", "style_look_empty", "style_mood_unknown_chapter", "style_rule_incomplete",
			"style_unit_without_look"]:
		check(codes.has(code), "%s is reported: %s" % [code, codes])
	var loop := StyleRegistry.new()
	var other := StyleRegistry.new()
	loop.base = other
	other.base = loop
	var cycle: Array = []
	for issue in StyleValidator.validate(loop, content):
		cycle.append(issue.code)
	check(cycle.has("style_base_cycle"), "a looping base chain is reported, not followed forever")
	other.base = null  # break the reference cycle so both free
	var clean := StyleRegistry.new()
	clean.default_look = _look(0.5)
	eq(StyleValidator.validate(clean, content).size(), 0, "a registry with only defaults is clean")


func test_style_console_command() -> void:
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	check(console.commands.has("style"), "the style command exists")
	var none: Dictionary = await console.execute("style list")
	check(none["ok"] and none["text"].contains("no style registry"), "headless: no registry in use: %s" % none["text"])
	UnitStyle.use(_registry(), "test")
	var list: Dictionary = await console.execute("style list")
	check(list["ok"] and list["text"].contains("chapter.a"), "style list names the moods: %s" % list["text"])
	var show: Dictionary = await console.execute("style show res://tests/fixtures/units/brute.tres")
	check(show["ok"] and show["text"].contains("rim 0.50"), "style show resolves a unit's look: %s" % show["text"])
	var not_unit: Dictionary = await console.execute("style show res://tests/fixtures/chapters/a.tres")
	check(not not_unit["ok"] and not_unit["text"].contains("is not a unit"), "a chapter is not a unit: %s" % not_unit["text"])
	var not_chapter: Dictionary = await console.execute("style mood res://tests/fixtures/units/brute.tres")
	check(not not_chapter["ok"] and not_chapter["text"].contains("is not a chapter"), "a unit is not a chapter: %s" % not_chapter["text"])
	var mood: Dictionary = await console.execute("style mood off")
	check(mood["ok"] and mood["text"].contains("each room its own"), "style mood off: %s" % mood["text"])
	var off: Dictionary = await console.execute("style registry off")
	check(off["ok"] and UnitStyle.registry() == null, "style registry off uses none: %s" % off["text"])
	var reload: Dictionary = await console.execute("style reload")
	check(not reload["ok"] and UnitStyle.registry() == null, "reload with no registry in use turns none on: %s" % reload["text"])
	var missing: Dictionary = await console.execute("style registry res://nope.tres")
	check(not missing["ok"], "an unknown registry file is refused")
	var camera: Dictionary = await console.execute("style camera sideways")
	check(not camera["ok"], "an unknown framing is refused")
	var wrong: Dictionary = await console.execute("style dance")
	check(not wrong["ok"], "an unknown operation is refused")


func test_demo_registry_loads_and_validates() -> void:
	if not ResourceLoader.exists(UnitStyle.DEFAULT_REGISTRY):
		return
	var registry := load(UnitStyle.DEFAULT_REGISTRY) as StyleRegistry
	check(registry != null, "the demo style registry loads")
	var content := ContentIndex.new("res://content/")
	var errors: Array = []
	for issue in StyleValidator.validate(registry, content):
		if issue.is_error():
			errors.append(str(issue))
	eq(errors, [], "the demo registry has no errors")
	for path in StyleValidator.registries_under("res://presentation/demo/style/variants"):
		var variant_errors: Array = []
		for issue in StyleValidator.validate(load(path) as StyleRegistry, content, path):
			if issue.is_error():
				variant_errors.append(str(issue))
		eq(variant_errors, [], "%s has no errors" % path)


# --- Round 2: attachments as data (spec cube-style 3.3) ------------------------------------------------------------------

func _part(kind: int) -> AttachmentPart:
	var part := AttachmentPart.new()
	part.kind = kind
	match kind:
		AttachmentPart.Kind.LATHE:
			part.profile = PackedVector2Array([Vector2(0.2, 0), Vector2(0.3, 0), Vector2(0.3, 0.1), Vector2(0.2, 0.1)])
		AttachmentPart.Kind.EXTRUDE:
			part.profile = PackedVector2Array([Vector2(0, 0), Vector2(0.5, 0.2), Vector2(0.4, -0.1), Vector2(0.2, 0.05), Vector2(0.1, -0.1)])
			part.size = Vector3(0, 0, 0.03)
		AttachmentPart.Kind.TUBE:
			part.curve = PackedVector3Array([Vector3.ZERO, Vector3(0.2, 0.2, 0), Vector3(0.1, 0.4, 0)])
			part.radius_top = 0.01
		AttachmentPart.Kind.TORUS:
			part.radius_top = 0.15
	return part


func _shape(parts: Array) -> AttachmentShape:
	var shape := AttachmentShape.new()
	shape.display_name = "test"
	for part in parts:
		shape.parts.append(part)
	return shape


func _attachment(shape: AttachmentShape, socket: StringName, mirror := false) -> UnitAttachment:
	var attachment := UnitAttachment.new()
	attachment.shape = shape
	attachment.socket = socket
	attachment.mirror = mirror
	return attachment


func _motion(view: UnitAnimator) -> AttachmentMotionDriver:
	if view.attachments_node() == null:
		return null
	for child in view.attachments_node().get_children():
		if child is AttachmentMotionDriver:
			return child
	return null


func test_every_part_kind_builds_and_caches_its_mesh() -> void:
	AttachmentMesh.clear_cache()
	for kind in AttachmentPart.Kind.values():
		var part := _part(kind)
		eq(part.problem(), "", "kind %s is valid" % kind)
		var mesh := AttachmentMesh.mesh_for(part)
		check(mesh != null and mesh.get_aabb().size.length() > 0.0, "kind %s builds a mesh with a size" % kind)
		check(AttachmentMesh.mesh_for(_part(kind)) == mesh, "an equal part shares the cached mesh (kind %s)" % kind)
	var before := AttachmentMesh.cache_size()
	var changed := _part(AttachmentPart.Kind.TUBE)
	changed.radius_bottom = 0.3
	check(AttachmentMesh.mesh_for(changed) != null and AttachmentMesh.cache_size() == before + 1, "an edit makes a new mesh")
	var broken := AttachmentPart.new()
	broken.kind = AttachmentPart.Kind.TUBE
	check(broken.problem() != "" and AttachmentMesh.mesh_for(broken) == null, "a tube with no curve builds nothing")
	var flat_torus := AttachmentPart.new()
	flat_torus.kind = AttachmentPart.Kind.TORUS
	check(flat_torus.problem() != "" and AttachmentMesh.mesh_for(flat_torus) == null, "a torus with equal radii builds nothing")


func test_wall_blocks_are_bevelled_by_the_mood() -> void:
	var size := Vector3(1, 0.6, 1)
	var mesh := AttachmentMesh.bevel_box(size, 0.06) as ArrayMesh
	check(mesh != null, "a bevel builds an ArrayMesh")
	check(mesh.get_aabb().size.is_equal_approx(size), "the block keeps its size: %s" % mesh.get_aabb().size)
	check(AttachmentMesh.bevel_box(size, 0.06) == mesh, "every wall shares one cached block")
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	eq((arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size(), vertices.size(), "every vertex has a UV")
	# 6 faces and 12 edge strips (2 triangles each) and 8 corners.
	eq(vertices.size(), (6 * 2 + 12 * 2 + 8) * 3, "faces, edge strips and corners")
	var wrong := 0
	for t in range(0, vertices.size(), 3):
		var face := (vertices[t + 1] - vertices[t]).cross(vertices[t + 2] - vertices[t])
		var centre := (vertices[t] + vertices[t + 1] + vertices[t + 2]) / 3.0
		if face.dot(normals[t]) > 0.0 or normals[t].dot(centre) <= 0.0:
			wrong += 1
	eq(wrong, 0, "every triangle is wound clockwise and faces out")
	check(AttachmentMesh.bevel_box(size, 0.0) is BoxMesh, "a bevel of 0 is a plain box")
	check(AttachmentMesh.bevel_box(size, 5.0).get_aabb().size.is_equal_approx(size), "a too deep bevel is held inside the box")
	check((arrays[Mesh.ARRAY_TANGENT] as PackedFloat32Array).size() == vertices.size() * 4, "tangents, so a normal map lights right")
	check(AttachmentMesh.bevel_box(Vector3(1, 0.001, 1), 0.06) is BoxMesh, "a box too thin to bevel is a plain box, never inside out")
	check(AttachmentMesh.bevel_box(size, NAN) is BoxMesh, "a bevel that is not a number is a plain box")
	var slab_size := Vector3(15, 0.2, 9)
	var slab := AttachmentMesh.corner_slab(slab_size, 0.06) as ArrayMesh
	check(slab != null and slab.get_aabb().size.is_equal_approx(slab_size), "the floor slab keeps its size")
	var slab_vertices: PackedVector3Array = slab.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var slab_normals: PackedVector3Array = slab.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	eq(slab_vertices.size(), (6 * 2 + 8 * 2) * 3, "an octagon top and bottom (6 triangles each) and 8 sides")
	var slab_wrong := 0
	for t in range(0, slab_vertices.size(), 3):
		var face := (slab_vertices[t + 1] - slab_vertices[t]).cross(slab_vertices[t + 2] - slab_vertices[t])
		var centre := (slab_vertices[t] + slab_vertices[t + 1] + slab_vertices[t + 2]) / 3.0
		if face.dot(slab_normals[t]) > 0.0 or slab_normals[t].dot(centre) <= 0.0:
			slab_wrong += 1
	eq(slab_wrong, 0, "every slab triangle is wound clockwise and faces out")
	check(AttachmentMesh.corner_slab(slab_size, 0.0) is BoxMesh, "a slab with no bevel is a plain box")
	var rig := StageRig.new()
	eq(rig.wall_bevel(), 0.0, "no mood: today's sharp walls")
	check(rig.floor_mesh(slab_size) is BoxMesh, "and a plain floor")
	check(rig.wall_mesh(size) is BoxMesh, "a plain box")
	var mood := _mood("a")
	eq(mood.wall_bevel, 0.06, "a mood bevels its walls by default")
	rig.apply(mood)
	check(rig.wall_mesh(size) == mesh, "the mood's bevelled block")
	check(rig.floor_mesh(slab_size) == slab, "and the corner-chamfered floor")
	rig.queue_free()
	var registry := StyleRegistry.new()
	registry.default_mood = _mood("deep")
	registry.default_mood.wall_bevel = 0.4
	registry.moods[&"no.such.chapter"] = _mood("negative")
	registry.moods[&"no.such.chapter"].wall_bevel = -0.1
	registry.moods[&"no.such.nan"] = _mood("nan")
	registry.moods[&"no.such.nan"].wall_bevel = NAN
	var codes: Array = []
	for issue in StyleValidator.validate(registry, null, "test"):
		if issue.code == "style_wall_bevel_invalid":
			codes.append(issue.path)
	eq(codes.size(), 3, "a bevel outside 0..0.25 (or not a number) is reported per mood: %s" % [codes])


func test_extruded_and_lathed_faces_point_outward() -> void:
	for kind in [AttachmentPart.Kind.EXTRUDE, AttachmentPart.Kind.LATHE, AttachmentPart.Kind.TUBE]:
		var mesh := AttachmentMesh.mesh_for(_part(kind)) as ArrayMesh
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var wrong := 0
		for t in range(0, vertices.size(), 3):
			# Godot's front faces are clockwise from outside: (b - a) x (c - a) points inward, against the normal.
			var face := (vertices[t + 1] - vertices[t]).cross(vertices[t + 2] - vertices[t])
			if face.length() > 0.0000001 and face.dot(normals[t] + normals[t + 1] + normals[t + 2]) > 0.0:
				wrong += 1
		eq(wrong, 0, "kind %s: every triangle is wound clockwise around its outward normal" % kind)


func test_ring_parts_repeat_around_y() -> void:
	var spike := _part(AttachmentPart.Kind.CYLINDER)
	spike.ring_count = 7
	spike.ring_radius = 0.3
	var placed := spike.transforms()
	eq(placed.size(), 7, "seven copies")
	for transform in placed:
		check(is_equal_approx(Vector2(transform.origin.x, transform.origin.z).length(), 0.3), "each on the ring")
	var node := _shape([spike]).build()
	eq(node.get_child_count(), 7, "the shape builds one node per copy")
	node.free()


func test_tint_replaces_only_tintable_parts() -> void:
	var cloth := _part(AttachmentPart.Kind.BOX)
	cloth.color = Color.BLUE
	var gem := _part(AttachmentPart.Kind.SPHERE)
	gem.color = Color.GREEN
	gem.tintable = false
	gem.emission = 2.0
	eq(cloth.material(Color.RED).albedo_color, Color.RED, "a tintable part takes the tint")
	eq(gem.material(Color.RED).albedo_color, Color.GREEN, "a fixed part keeps its colour")
	check(gem.material().emission_enabled and gem.material().emission == Color.GREEN, "emission glows in the part's colour")


func test_mirror_and_motion() -> void:
	var attachment := _attachment(_shape([_part(AttachmentPart.Kind.BOX)]), &"Back", true)
	attachment.offset = Vector3(0.3, 0, 0)
	var pivots: Array = []
	var holder := attachment.build(Vector3(0, 0, -0.4), pivots)
	eq(pivots.size(), 2, "a mirrored attachment has two pivots")
	var mirror := holder.get_node("Mirror") as Node3D
	check(mirror != null and mirror.scale == Vector3(-1, 1, 1), "the copy sits under a mirror across X")
	eq((pivots[0][0] as Node3D).position, Vector3(0.3, 0, -0.4), "socket + offset")
	holder.free()
	var rest := Transform3D.IDENTITY
	attachment.motion = UnitAttachment.Motion.BOB
	attachment.motion_amount = 0.1
	attachment.motion_speed = 1.0
	check(is_equal_approx(attachment.animate(rest, 0.25).origin.y, 0.1), "a bob is at its top a quarter cycle in")
	attachment.motion = UnitAttachment.Motion.FLAP
	attachment.motion_amount = 30.0
	var swing := absf(rad_to_deg(attachment.animate(rest, 0.25).basis.get_euler().z))
	check(is_equal_approx(swing, 30.0), "a flap swings its full amount around Z (%.2f)" % swing)
	attachment.motion = UnitAttachment.Motion.NONE
	eq(attachment.animate(rest, 0.25), rest, "no motion stays at rest")
	attachment.motion = UnitAttachment.Motion.SPIN
	var tilted := Transform3D(Basis(Vector3.BACK, deg_to_rad(90.0)), Vector3(0.4, 0, 0))  # a gear stood on its side (axle along X)
	var around_up := attachment.animate(tilted, 0.25)
	check(around_up.basis.is_equal_approx(Basis(Vector3.UP, TAU * 0.25) * tilted.basis) and around_up.origin == tilted.origin,
		"an unset spin axis turns around the parent's up, as before")
	attachment.spin_axis = Vector3.UP
	var axle := tilted.basis * Vector3.UP  # the gear's own axle in the parent's frame
	var own := attachment.animate(tilted, 0.25)
	check((own.basis * Vector3.UP).is_equal_approx(axle), "a spin axis turns the attachment on its own axle (the axle stays put)")
	check(not own.basis.is_equal_approx(tilted.basis), "and it does turn")


func test_unit_view_wears_its_attachments_stamped() -> void:
	var registry := _registry()
	var look := UnitLook.new()
	look.attachments.append(_attachment(_shape([_part(AttachmentPart.Kind.SPHERE)]), &"Top"))
	var moving := _attachment(_shape([_part(AttachmentPart.Kind.BOX)]), &"Front", true)
	moving.motion = UnitAttachment.Motion.BOB
	look.attachments.append(moving)
	registry.looks[&"u.dressed"] = look
	UnitStyle.use(registry, "test")
	var view: UnitAnimator = UnitAnimator.instantiate_for(_unit(&"u.dressed"), load(PROBE_VIEW) as PackedScene)
	host.add_child(view)
	var worn := view.attachments_node()
	check(worn != null, "the view wears its look's attachments")
	eq(worn.get_children().filter(func(n: Node) -> bool: return not n is AttachmentMotionDriver).size(), 2, "one holder per attachment")
	eq(view.socket_position(&"Top"), Vector3(0, 0.4, 0), "Top is the top face of the 0.8 cube")
	eq(view.socket_position(&"Front"), Vector3(0, 0, 0.4), "Front faces the camera (+Z)")
	check(_motion(view) != null and _motion(view).is_processing(), "a moving attachment runs its own motion driver")
	check(not view.is_processing(), "the view's own processing is left alone")
	view.stencil_value = StencilIds.values_for(1)[0]
	var stamped := 0
	var meshes := 0
	for node in view.attachments_node().find_children("*", "MeshInstance3D", true, false):
		meshes += 1
		var paint := (node as MeshInstance3D).material_override as BaseMaterial3D
		if paint != null and paint.stencil_mode == BaseMaterial3D.STENCIL_MODE_CUSTOM:
			stamped += 1
	check(meshes == 3 and stamped == meshes, "every attachment mesh carries the unit's stencil stamp (%d of %d)" % [stamped, meshes])
	UnitStyle.use(null)
	view.restyle()
	check(view.attachments_node() == null, "with no look it wears nothing (and its motion driver goes with it)")
	view.queue_free()


func test_attachments_face_opponents_and_go_grey_when_dead() -> void:
	var registry := _registry()
	var look := UnitLook.new()
	var glowing := _part(AttachmentPart.Kind.SPHERE)
	glowing.color = Color.GREEN
	glowing.emission = 2.0
	var flapping := _attachment(_shape([glowing]), &"Back", true)
	flapping.motion = UnitAttachment.Motion.FLAP
	look.attachments.append(flapping)
	registry.looks[&"u.dressed"] = look
	UnitStyle.use(registry, "test")
	var view: UnitAnimator = UnitAnimator.instantiate_for(_unit(&"u.dressed"), load(PROBE_VIEW) as PackedScene)
	host.add_child(view)
	eq(view.attachments_node().rotation_degrees.y, 90.0, "out of battle (and the party) faces +X, toward the enemies")
	view.unit_id = &"E2"
	eq(view.attachments_node().rotation_degrees.y, -90.0, "an enemy faces -X, toward the party")
	view.unit_id = &"P1"
	eq(view.attachments_node().rotation_degrees.y, 90.0, "a party member faces +X")
	eq(view.socket_position(&"Right"), Vector3(-0.4, 0, 0), "Right is the unit's own right (-X while facing +Z)")
	var before := view.attachments_node()
	view.stencil_value = StencilIds.values_for(1)[0]
	check(view.attachments_node() == before, "a new stencil value repaints, it does not rebuild")
	check(view.effect_stencil_value() == StencilIds.NONE, "the probe body takes no stamp, and the attachments' stamps do not change that")
	view.set_dead(true)
	var mesh := view.attachments_node().find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var paint := mesh.material_override as StandardMaterial3D
	check(paint.albedo_color == Color(0.35, 0.35, 0.35) and not paint.emission_enabled, "a dead unit's attachments are grey and dark")
	check(not _motion(view).is_processing(), "and still")
	view.set_dead(false)
	paint = mesh.material_override as StandardMaterial3D
	check(paint.albedo_color == Color.GREEN and paint.emission_enabled and _motion(view).is_processing(), "revived: its colours and motion back")
	view.queue_free()


func test_battle_formation_fills_rows_front_first() -> void:
	var enemies := BattleFormation.new()
	var five := enemies.positions(5, 1)
	eq(five.size(), 5, "five places")
	check(is_equal_approx(five[0].x, 2.6) and is_equal_approx(five[1].x, 2.6), "two in the front row")
	check(is_equal_approx(five[2].x, 4.4) and is_equal_approx(five[3].x, 4.4) and is_equal_approx(five[4].x, 4.4), "three in the back row")
	check(is_equal_approx(five[0].z + five[1].z, -0.8) and is_equal_approx(five[3].z, -0.4), "each row centred on center_z")
	check(enemies.positions(1, 1)[0].is_equal_approx(Vector3(2.6, 0, -0.4)), "a lone boss stands front centre")
	var party := BattleFormation.new()
	party.row_sizes = PackedInt32Array([2, 2])
	var four := party.positions(4, -1)
	check(four[0].x < 0 and four[2].x < four[0].x, "the party stands on the left, its back row further left")
	party.row_lane_spacing = PackedFloat32Array([2.0, 4.0])
	var staggered := party.positions(4, -1)
	check(is_equal_approx(staggered[1].z - staggered[0].z, 2.0) and is_equal_approx(staggered[3].z - staggered[2].z, 4.0),
		"each row can have its own lane spacing (a wider back row)")
	check(is_equal_approx(enemies.positions(8, 1)[7].x, 6.2), "big groups repeat the last row size further back")
	var registry := _registry()
	UnitStyle.use(registry, "test")
	eq(UnitStyle.battle_positions(false, 3), [] as Array[Vector3], "no formation: the rooms' spawn cells")
	registry.enemy_formation = enemies
	eq(UnitStyle.battle_positions(false, 3).size(), 3, "a formation places every unit")


func test_a_surface_replaces_the_plain_colour() -> void:
	var registry := _registry()
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.4, 0.38, 0.35)
	stone.roughness = 0.95
	var look := UnitLook.new()
	look.surface = stone
	registry.looks[&"u.stone"] = look
	UnitStyle.use(registry, "test")
	var view: UnitAnimator = UnitAnimator.instantiate_for(_unit(&"u.stone"), load(PROBE_VIEW) as PackedScene)
	host.add_child(view)
	var body := view.body_material(Color.RED)
	check(body != stone and body.albedo_color == Color.RED, "a copy of the surface, tinted by the unit's colour")
	check(is_equal_approx(body.roughness, 0.95), "the surface keeps its own roughness over the default look's")
	check(body.rim_enabled, "and still gets the look's rim")
	view.is_dead = true
	eq(view.body_material(Color(0.35, 0.35, 0.35)).albedo_color, Color(0.35, 0.35, 0.35), "a dead unit is plain grey")
	view.queue_free()


func test_face_sockets_stay_on_the_surface_at_any_facing_and_rest_when_dead() -> void:
	var registry := _registry()
	registry.facing_degrees = 45.0
	var look := UnitLook.new()
	var bobbing := _attachment(_shape([_part(AttachmentPart.Kind.BOX)]), &"Front")
	bobbing.motion = UnitAttachment.Motion.BOB
	bobbing.motion_amount = 0.2
	look.attachments.append(bobbing)
	registry.looks[&"u.turned"] = look
	UnitStyle.use(registry, "test")
	var view: UnitAnimator = UnitAnimator.instantiate_for(_unit(&"u.turned"), load(PROBE_VIEW) as PackedScene)
	host.add_child(view)
	var holder := view.attachments_node()
	var pivot := holder.find_children("Pivot", "Node3D", true, false)[0] as Node3D
	var on_body := holder.transform * pivot.position  # in the view's (body's) frame
	check(is_equal_approx(maxf(absf(on_body.x), absf(on_body.z)), 0.4), "at 45° the Front socket sits on the cube's surface: %s" % on_body)
	var rest := pivot.transform
	_motion(view)._process(0.25)  # a quarter cycle in: lifted
	check(not pivot.transform.is_equal_approx(rest), "the bob moved it")
	view.set_dead(true)
	check(pivot.transform.is_equal_approx(rest), "a dead unit's attachments go back to rest, not frozen mid-motion")
	view.queue_free()


func test_attachment_lists_are_not_merged() -> void:
	var registry := _registry()
	var hat := _attachment(_shape([_part(AttachmentPart.Kind.BOX)]), &"Top")
	registry.default_look.attachments.append(hat)
	eq(registry.look_for(_unit(&"u.plain")).attachments, [hat], "the default look's attachments")
	var own := _attachment(_shape([_part(AttachmentPart.Kind.SPHERE)]), &"Front")
	var exact := UnitLook.new()
	exact.attachments.append(own)
	registry.looks[&"u.own"] = exact
	eq(registry.look_for(_unit(&"u.own")).attachments, [own], "an exact look's list wins whole")


## A looping effect for a look: one light layer (no rendering needed).
func _looping_effect(loop: bool = true) -> FxDefinition:
	var effect := FxDefinition.new()
	effect.id = &"fx.test_look"
	var light := FxLightLayer.new()
	light.id = &"light"
	light.loop = loop
	effect.layers.append(light)
	return effect


func test_a_looks_effect_merges_like_its_other_fields() -> void:
	var registry := _registry()
	var aura := _looping_effect()
	registry.default_look.effect = aura
	registry.default_look.effect_params = {"color": Color.RED}
	var plain := registry.look_for(_unit(&"u.plain"))
	check(plain.effect == aura and plain.effect_params == {"color": Color.RED}, "the default look's effect and its parameters")
	var own_effect := _looping_effect()
	var exact := UnitLook.new()
	exact.effect = own_effect
	registry.looks[&"u.own"] = exact
	var own := registry.look_for(_unit(&"u.own"))
	check(own.effect == own_effect and own.effect_params.is_empty(), "an exact look's effect wins, with its own (empty) parameters")


## Spec cube-style 3.2: the view plays its look's effect while the unit lives, from the frame after it is built; stops it on a death,
## plays it again on a revive, keeps it on a same-effect restyle, and stops it when it leaves the tree (code review, PR #34: and
## starts it again when it comes back).
func test_a_unit_view_plays_its_looks_effect_while_alive() -> void:
	var saved := _fx_on()
	var view := _burning_view()
	host.add_child(view)
	check(view.get("_look_fx") == null, "not on the frame it is built (a caller may still set it dead)")
	await host.get_tree().process_frame
	var first: FxHandle = view.get("_look_fx")
	check(first != null and first.is_playing() and first.definition == view.look.effect, "the effect plays from the next frame")
	view.set_dead(true)
	check(view.get("_look_fx") == null and (first.stopping or not first.is_playing()), "a death stops it")
	view.set_dead(false)
	var second: FxHandle = view.get("_look_fx")
	check(second != null and second != first and second.is_playing(), "a revive plays it again")
	view.restyle()
	check(view.get("_look_fx") == second, "a restyle with the same effect keeps it running")
	host.remove_child(view)
	check(view.get("_look_fx") == null and (second.stopping or not second.is_playing()), "leaving the tree stops it")
	host.add_child(view)
	var third: FxHandle = view.get("_look_fx")
	check(third != null and third.is_playing(), "coming back into the tree plays it again")
	view.free()
	_fx_restore(saved)


## Code review, PR #34: a view built dead (set_dead right after add_child) never starts its effect.
func test_a_view_built_dead_never_plays_its_looks_effect() -> void:
	var saved := _fx_on()
	var view := _burning_view()
	host.add_child(view)
	view.set_dead(true)
	await host.get_tree().process_frame
	check(view.get("_look_fx") == null, "no play and stop for a dead unit's view")
	view.free()
	_fx_restore(saved)


## Code review, PR #34: quality off stops the look effect and a raised tier brings it back; a view built while quality is off
## starts its effect once the quality is raised.
func test_the_looks_effect_follows_the_quality_setting() -> void:
	var saved := _fx_on()
	var view := _burning_view()
	host.add_child(view)
	await host.get_tree().process_frame
	check(view.get("_look_fx") != null, "playing at the starting tier")
	FxManager.quality = FxQuality.OFF
	check(view.get("_look_fx") == null, "quality off: no effect")
	FxManager.quality = FxQuality.MEDIUM
	var back: FxHandle = view.get("_look_fx")
	check(back != null and back.is_playing(), "a raised tier plays it again")
	FxManager.quality = FxQuality.OFF
	var late := _burning_view()
	host.add_child(late)
	await host.get_tree().process_frame
	check(late.get("_look_fx") == null, "built while quality is off: nothing yet")
	FxManager.quality = FxQuality.HIGH
	check(late.get("_look_fx") != null and (late.get("_look_fx") as FxHandle).is_playing(), "and its effect starts when the tier is raised")
	view.free()
	late.free()
	_fx_restore(saved)


## Code review, PR #34: a death waiting behind a cast keeps the effect until the death starts; a death fade (also the console's
## `style death test` on a living unit) takes it with the body.
func test_the_looks_effect_ends_when_the_death_starts() -> void:
	var saved := _fx_on()
	var view := _burning_view()
	host.add_child(view)
	await host.get_tree().process_frame
	view.set("_gate", ClientGate.new())
	view.die()
	check(view.get("_pending_death") and view.get("_look_fx") != null, "a death waiting behind a cast keeps the effect")
	view.call("_finish_montage")
	check(view.get("_look_fx") == null, "the death starts: the effect goes")
	view.revive()
	check(view.get("_look_fx") != null, "revived: back")
	view.play_death_fade()
	check(view.get("_look_fx") == null, "a death fade on a living unit takes the effect with the body")
	view.set_dead(false)
	check(view.get("_look_fx") != null, "the fade cancelled: back")
	view.free()
	_fx_restore(saved)


## FxManager switched on with a manual clock at high quality; returns what to restore.
func _fx_on() -> Dictionary:
	var saved := {"enabled": FxManager.enabled, "manual": FxManager.manual_clock, "quality": FxManager.quality}
	FxManager.enabled = true
	FxManager.manual_clock = true
	FxManager.quality = FxQuality.HIGH
	return saved


func _fx_restore(saved: Dictionary) -> void:
	FxManager.quality = saved["quality"]
	FxManager.enabled = saved["enabled"]
	FxManager.manual_clock = saved["manual"]


## A probe view whose look carries a looping effect (the registry in use is set here).
func _burning_view() -> UnitAnimator:
	var registry := _registry()
	var look := UnitLook.new()
	look.effect = _looping_effect()
	registry.looks[&"u.burning"] = look
	UnitStyle.use(registry, "test")
	return UnitAnimator.instantiate_for(_unit(&"u.burning"), load(PROBE_VIEW) as PackedScene)


func test_validator_attachment_codes() -> void:
	var registry := StyleRegistry.new()
	var look := UnitLook.new()
	look.attachments.append(null)
	look.attachments.append(_attachment(_shape([_part(AttachmentPart.Kind.BOX)]), &"Elbow"))
	var broken := AttachmentPart.new()
	broken.kind = AttachmentPart.Kind.LATHE
	look.attachments.append(_attachment(_shape([broken]), &"Top"))
	look.effect = _looping_effect(false)
	registry.default_look = look
	var codes: Array = []
	for issue in StyleValidator.validate(registry, null, "test"):
		codes.append(issue.code)
	for code in ["style_attachment_shape_missing", "style_socket_unknown", "style_part_invalid", "style_effect_not_looping"]:
		check(codes.has(code), "%s is reported: %s" % [code, codes])
