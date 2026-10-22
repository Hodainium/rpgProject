## Spec animation-sets: the shared AnimationTree drives the gate exactly like playing the ability's animation did,
## the flinch is additive, death waits for a cast, sets fall back, and nothing under presentation reaches combat.
## Headless: each probe view's tree runs in manual mode and the test advances it.
extends TestCase

const PROBE_VIEW := "res://tests/fixtures/views/probe_view.tscn"
const STEP: float = 0.05


## A ClientGate that remembers which rows the animation released.
class RecordingGate extends ClientGate:
	var rows: Array[StringName] = []

	func release_execution(row_id: StringName = &"") -> void:
		rows.append(row_id)
		super(row_id)

	func is_finished() -> bool:
		return _finished


func _view() -> UnitAnimator:
	var view: UnitAnimator = load(PROBE_VIEW).instantiate()
	host.add_child(view)
	view.tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	view.tree.advance(0.0)
	return view


func _ability(name: String) -> BattleAbility:
	return fixtures().units[&"fixture.unit.striker"].abilities[0].instantiate() if name == "" else \
		(load("res://tests/fixtures/abilities/%s.tscn" % name) as PackedScene).instantiate()


func _cast(view: UnitAnimator, ability: BattleAbility) -> RecordingGate:
	var gate := RecordingGate.new()
	gate.begin_ability(&"P1", ability, ExecutionReader.sequence_for(ability.animation))
	view.play(ability, gate)
	return gate


func _state(view: UnitAnimator) -> StringName:
	return (view.tree.get("parameters/state/playback") as AnimationNodeStateMachinePlayback).get_current_node()


func test_montage_releases_in_order() -> void:
	var view := _view()
	var combo := _ability("combo")
	var gate := _cast(view, combo)
	var steps := 0
	while not gate.is_finished() and steps < 100:
		view.tree.advance(STEP)
		steps += 1
	eq(gate.rows, ExecutionReader.sequence_for(combo.animation), "every execute key, in the animation's order")
	check(gate.is_finished(), "the montage's end releases the gate")
	check(steps * STEP >= combo.animation.length - STEP, "not before the animation has played (%.2f s)" % (steps * STEP))
	combo.free()
	view.queue_free()


func test_montage_never_stalls() -> void:
	var view := _view()
	var silent := _ability("strike")
	silent.animation = null
	var gate := _cast(view, silent)
	check(gate.is_finished(), "no animation: released at once")
	var strike := _ability("strike")
	gate = _cast(view, strike)  # the tree is never advanced: as if the animation were stuck
	await host.get_tree().create_timer(strike.animation.length + UnitAnimator.SAFETY_SECONDS + 0.3).timeout
	check(gate.is_finished(), "the safety timer releases a stuck animation")
	silent.free()
	strike.free()
	view.queue_free()


func test_montage_merges_cast_into_keys_only_animations() -> void:
	var view := _view()
	var strike := _ability("strike")
	check(not UnitAnimator.moves_model(strike.animation), "the fixture animation has keys only")
	var gate := _cast(view, strike)
	var highest := 0.0
	for step in 100:
		if gate.is_finished():
			break
		view.tree.advance(STEP)
		highest = maxf(highest, (view.get_node("Body") as Node3D).position.y)
	check(highest > 0.3, "the set's cast hop shows under a keys-only ability, well above idle's 0.1 (peak %.2f)" % highest)
	eq(gate.rows, [&"hit"], "and its key still releases the row")
	strike.free()
	view.queue_free()


func test_flinch_is_additive() -> void:
	var view := _view()
	var body: Node3D = view.get_node("Body")
	var combo := _ability("combo")
	var gate := _cast(view, combo)
	for step in 2:
		view.tree.advance(STEP)
	view.flinch()
	var both := false
	for step in 3:
		view.tree.advance(STEP)
		both = both or (body.position.x > 0.05 and body.position.y > 0.05)
	check(both, "mid-cast the flinch (x) adds to the cast's hop (y): %s" % body.position)
	for step in 100:
		if gate.is_finished():
			break
		view.tree.advance(STEP)
	eq(gate.rows, ExecutionReader.sequence_for(combo.animation), "the cast was not cut: every key still fired")
	combo.free()
	view.queue_free()


func test_death_waits_for_montage() -> void:
	var view := _view()
	var combo := _ability("combo")
	var gate := _cast(view, combo)
	view.tree.advance(STEP * 4)
	view.die()
	view.tree.advance(STEP)
	check(_state(view) != &"death" and _state(view) != &"dead", "no death while the cast plays")
	for step in 100:
		if gate.is_finished():
			break
		view.tree.advance(STEP)
	for step in 10:
		view.tree.advance(STEP)
	check(_state(view) in [&"death", &"dead"], "death after the cast (state: %s)" % _state(view))
	view.revive()
	for step in 10:
		view.tree.advance(STEP)
	eq(_state(view), &"idle", "revive returns to idle")
	combo.free()
	view.queue_free()


func test_animation_set_fallback() -> void:
	var base := UnitAnimationSet.new()
	base.idle = Animation.new()
	base.hit = Animation.new()
	var own := UnitAnimationSet.new()
	own.hit = Animation.new()
	own.fallback = base
	check(own.animation_for(&"idle") == base.idle, "an empty slot comes from the fallback")
	check(own.animation_for(&"hit") == own.hit, "a filled slot is the set's own")
	check(own.animation_for(&"death") == null, "nobody has it: null")
	eq(own.own_slots(), [&"hit"] as Array[StringName], "own slots")
	var loop := UnitAnimationSet.new()
	loop.fallback = loop
	check(loop.animation_for(&"idle") == null, "a set falling back to itself ends")
	var view: UnitAnimator = load(PROBE_VIEW).instantiate()
	view.animation_set = own
	host.add_child(view)
	check(view.tree.get_animation(&"set/idle") == base.idle, "the view's library takes the fallback's idle")
	check(view.tree.get_animation(&"set/walk") != null, "an empty slot still plays something (silent)")
	view.queue_free()


func test_montage_per_unit() -> void:
	var first := _view()
	var second := _view()
	var a := _ability("combo")
	var b := _ability("combo")
	var gate_a := _cast(first, a)
	var gate_b := RecordingGate.new()
	gate_b.begin_ability(&"P2", b, ExecutionReader.sequence_for(b.animation))
	second.play(b, gate_b)
	for step in 100:
		if gate_a.is_finished() and gate_b.is_finished():
			break
		first.tree.advance(STEP)
		second.tree.advance(STEP)
	eq(gate_a.rows, gate_b.rows, "two units casting the same ability each release their own keys")
	check(first.tree.get_animation_library(&"montage") != second.tree.get_animation_library(&"montage"),
		"each view has its own montage library")
	a.free()
	b.free()
	first.queue_free()
	second.queue_free()


## The same battle with every animation skipped and with every animation played on probe views: same log, same hash.
func test_skip_and_animated_same_hash() -> void:
	var snap := snapshot("duel", [[1, "striker"]])
	var skipped := ViewGate.new()
	skipped.skip_all = true
	var expected := await record(snap, skipped)
	var animated := ViewGate.new()
	var views := {}
	animated.ability_began.connect(func(unit_id: StringName, ability: BattleAbility) -> void:
		if not views.has(unit_id):
			views[unit_id] = _view()
		views[unit_id].play(ability, animated))
	var drive := func() -> void:
		for view in views.values():
			view.tree.advance(0.25)
	host.get_tree().process_frame.connect(drive)
	var played := await record(snap, animated)
	host.get_tree().process_frame.disconnect(drive)
	eq(WireJson.stringify(played), WireJson.stringify(expected), "animated play logs and hashes like skipped play")
	for view in views.values():
		view.queue_free()


func test_headless_never_loads_views() -> void:
	check(typeof(UnitDefinition.new().view) == TYPE_STRING, "UnitDefinition.view is a path, not a scene")
	var view_path := "user://animation_sets_probe_view.tscn"
	var scene := PackedScene.new()
	var root := UnitAnimator.new()
	scene.pack(root)
	root.free()
	ResourceSaver.save(scene, view_path)
	var definition := EnemyDefinition.new()
	definition.id = &"test.enemy.viewed"
	definition.view = view_path
	ResourceSaver.save(definition, "user://animation_sets_probe_enemy.tres")
	var loaded: UnitDefinition = ResourceLoader.load("user://animation_sets_probe_enemy.tres", "",
		ResourceLoader.CACHE_MODE_IGNORE)
	eq(loaded.view, view_path, "the path survives a save")
	check(not ResourceLoader.has_cached(view_path), "loading the definition doesn't load its view")
	var fallback := PackedScene.new()
	check(UnitAnimator.view_scene(loaded, fallback) != fallback, "presentation loads it on request")
	definition.view = "res://nowhere/missing_view.tscn"
	check(UnitAnimator.view_scene(definition, fallback) == fallback, "a missing view falls back to the default")


## Godot blends onto RESET (or zero): a scale flinch or a `visible` track must come back to the rest value, not 0.
func test_rest_values_survive() -> void:
	var pulse := Animation.new()
	pulse.length = 0.2
	var scale_track := pulse.add_track(Animation.TYPE_VALUE)
	pulse.track_set_path(scale_track, NodePath("Body:scale"))
	pulse.track_insert_key(scale_track, 0.0, Vector3.ONE)
	pulse.track_insert_key(scale_track, 0.1, Vector3.ONE * 1.25)
	pulse.track_insert_key(scale_track, 0.2, Vector3.ONE)
	var own := UnitAnimationSet.new()
	own.hit = pulse
	own.fallback = load("res://tests/fixtures/animation_sets/probe_set.tres")
	var view: UnitAnimator = load(PROBE_VIEW).instantiate()
	view.animation_set = own
	host.add_child(view)
	view.tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	view.tree.advance(0.0)
	var body: Node3D = view.get_node("Body")
	view.flinch()
	var peak := 0.0
	for step in 10:
		view.tree.advance(STEP)
		peak = maxf(peak, body.scale.x)
	check(is_equal_approx(peak, 1.25), "the pulse is added once around the rest scale (peak %.2f)" % peak)
	eq(body.scale, Vector3.ONE, "and the scale comes back to 1, not 0")
	var flash := _ability("strike")
	var blink: Animation = flash.animation.duplicate()
	var visible_track := blink.add_track(Animation.TYPE_VALUE)
	blink.track_set_path(visible_track, NodePath("Body:visible"))
	blink.track_insert_key(visible_track, 0.1, false)
	blink.track_insert_key(visible_track, 0.4, true)
	flash.animation = blink
	var gate := _cast(view, flash)
	for step in 100:
		if gate.is_finished():
			break
		view.tree.advance(STEP)
	for step in 5:
		view.tree.advance(STEP)
	check(body.visible, "a flash ability leaves the body visible afterwards")
	flash.free()
	view.queue_free()


## Content test: every unit under res://content/ gets a view with a UnitAnimator and a set, and the validator finds
## nothing wrong with any view. A failure means content or presentation is broken, not the system.
func test_content_units_have_views() -> void:
	var content := ContentIndex.new("res://content/")
	if content.units.is_empty():
		print("    skipped: res://content/ has no units")
		return
	var default_path: String = GameMain.VIEW_DIR + "unit_view.tscn"  # what GameMain falls back to
	check(ResourceLoader.exists(default_path), "[content] the default unit view exists")
	if not ResourceLoader.exists(default_path):
		return
	var default_scene: PackedScene = load(default_path)
	for id in content.units:
		var view := UnitAnimator.view_scene(content.units[id], default_scene).instantiate()
		check(view is UnitAnimator and view.animation_set != null, "[content] %s has a view with an animation set" % id)
		view.free()
	var codes := ["view_missing", "animation_set_loop", "animation_set_profile", "ability_montage_path"]
	var found := ContentValidator.validate(content, {"tags": false}).filter(func(issue): return issue.code in codes)
	eq(found.map(func(issue): return str(issue)), [], "[content] no view or animation set warnings")
