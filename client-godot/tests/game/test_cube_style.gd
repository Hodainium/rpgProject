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
	var codes: Array = []
	for issue in StyleValidator.validate(registry, content, "test"):
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
