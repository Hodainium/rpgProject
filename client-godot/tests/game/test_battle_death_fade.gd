## Spec battle-death-fade: an enemy view turns red and fades out when it dies (a party view falls and greys as before), its
## attachments with it, a revive cancels it; the battle's end waits for open fades and holds (never longer than the cap, never with
## skip_all or headless), and the battle's log and hash are the same with or without the wait. Probe views and fixtures only.
extends TestCase

const PROBE_VIEW := "res://tests/fixtures/views/probe_view.tscn"

var _runs: Array[RunController] = []


func after_each() -> void:
	UnitStyle.reset()
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


func _unit(id: StringName, tags: Array = []) -> UnitDefinition:
	var unit := UnitDefinition.new()
	unit.id = id
	unit.tags.assign(tags)
	return unit


## A probe view with a coloured mesh on its body (the probe's body has none), as unit `unit_id`.
func _view(unit_id: StringName, definition: UnitDefinition = null, color := Color.BLUE) -> UnitAnimator:
	var view: UnitAnimator = UnitAnimator.instantiate_for(definition if definition != null else _unit(&"u.probe"),
		load(PROBE_VIEW) as PackedScene)
	var mesh := MeshInstance3D.new()
	mesh.name = "Cube"
	mesh.mesh = BoxMesh.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	mesh.material_override = material
	view.get_node(^"Body").add_child(mesh)
	host.add_child(view)
	view.unit_id = unit_id
	return view


func _material(view: UnitAnimator, name := "Cube") -> StandardMaterial3D:
	return (view.get_node(NodePath("Body/" + name)) as MeshInstance3D).material_override as StandardMaterial3D


func _fade(tint: float, fade: float, beat: float, flash := 0.0) -> DeathFade:
	var settings := DeathFade.new()
	settings.tint_seconds = tint
	settings.fade_seconds = fade
	settings.end_beat = beat
	settings.flash_seconds = flash
	return settings


func test_an_enemy_fades_a_party_member_falls() -> void:
	var enemy := _view(&"E1")
	var driver: DeathFadeDriver = null
	enemy.die()
	driver = enemy.death_fade_driver()
	check(driver != null, "an enemy view fades when it dies")
	check(not enemy.tree.active, "its idle freezes")
	var settings := driver.fade
	driver.set_process(false)  # driven by hand below
	driver.advance(settings.flash_seconds + settings.tint_seconds)
	var paint := _material(enemy)
	check(paint.albedo_color.r > 0.8 and paint.albedo_color.b < 0.1 and is_equal_approx(paint.albedo_color.a, 1.0),
		"red and opaque once tinted (%s)" % paint.albedo_color)
	check(paint.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and paint.emission_enabled, "a glowing alpha copy")
	driver.advance(settings.fade_seconds * 0.5)
	check(_material(enemy).albedo_color.a < 0.6 and enemy.visible, "half faded, still shown")
	driver.advance(settings.fade_seconds * 0.5 + 0.001)
	check(not enemy.visible and not driver.is_done(), "hidden at the fade's end, the end beat still holding")
	driver.advance(settings.end_beat)
	check(driver.is_done(), "done after the end beat")
	var party := _view(&"P1")
	party.die()
	check(party.death_fade_driver() == null and party.tree.active, "a party member keeps today's fall")
	enemy.queue_free()
	party.queue_free()


func test_attachments_fade_too_and_revive_cancels() -> void:
	var registry := StyleRegistry.new()
	var look := UnitLook.new()
	var part := AttachmentPart.new()
	part.kind = AttachmentPart.Kind.SPHERE
	part.color = Color.GREEN
	var shape := AttachmentShape.new()
	shape.parts.append(part)
	var attachment := UnitAttachment.new()
	attachment.shape = shape
	attachment.socket = &"Top"
	look.attachments.append(attachment)
	registry.looks[&"u.hat"] = look
	registry.enemy_death = _fade(0.2, 0.4, 0.1)
	UnitStyle.use(registry, "test")
	var view := _view(&"E2", _unit(&"u.hat"))
	var worn := view.attachments_node().find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var before := worn.material_override
	view.die()
	var driver := view.death_fade_driver()
	eq(driver.fade, registry.enemy_death, "the registry's enemy fade")
	driver.set_process(false)
	driver.advance(0.2 + 0.2)
	var paint := worn.material_override as StandardMaterial3D
	check(paint != before and paint.albedo_color.r > 0.8 and paint.albedo_color.a < 0.6, "the hat turns red and fades with the body")
	view.revive()
	check(view.death_fade_driver() == null and view.visible and view.tree.active, "a revive cancels the fade")
	var restored := worn.material_override as StandardMaterial3D
	check(restored.albedo_color == Color.GREEN and restored.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED,
		"the hat's own colour and opacity are back")
	check(_material(view).albedo_color.a == 1.0, "the body is opaque again")
	view.queue_free()


func test_a_boss_takes_the_boss_fade() -> void:
	var view := _view(&"E1", _unit(&"u.boss", [&"Enemy.Boss"]))
	view.die()
	var fade := view.death_fade_driver().fade
	check(fade.fade_seconds > DeathFade.enemy_default().fade_seconds and fade.flash_seconds > 0.0,
		"no registry: the built-in boss fade, longer and with a flash")
	view.queue_free()


func test_settings_through_the_base_chain() -> void:
	var main := StyleRegistry.new()
	main.boss_death = _fade(1, 2, 0.5)
	var variant := StyleRegistry.new()
	variant.base = main
	eq(variant.death_fade(true), main.boss_death, "a variant takes its base's boss fade")
	variant.boss_death = _fade(0.1, 0.1, 0.1)
	eq(variant.death_fade(true), variant.boss_death, "the nearer registry wins")
	check(variant.death_fade(false).tint_seconds == DeathFade.enemy_default().tint_seconds, "unset everywhere: the defaults")
	UnitStyle.use(null)
	check(UnitStyle.death_fade(true).fade_seconds == DeathFade.boss_default().fade_seconds, "no registry: the defaults")


func test_hold_none_one_many_cap_and_skip() -> void:
	var gate := ViewGate.new()
	var start := Time.get_ticks_msec()
	await gate.hold_end()
	check(Time.get_ticks_msec() - start < 100, "no holds: at once")
	var first := gate.begin_hold()
	var second := gate.begin_hold()
	eq(gate.open_holds(), 2, "two holds")
	var released := [false]
	var release := func() -> void:
		await host.get_tree().create_timer(0.1).timeout
		gate.end_hold(first)
		await host.get_tree().create_timer(0.2).timeout
		released[0] = true
		gate.end_hold(second)
	release.call()
	await gate.hold_end()
	check(released[0] and gate.open_holds() == 0, "waits for the longest hold")
	gate.begin_hold()
	gate.skip_all = true
	start = Time.get_ticks_msec()
	await gate.hold_end()
	check(Time.get_ticks_msec() - start < 100, "skip_all: at once")
	gate.skip_all = false
	start = Time.get_ticks_msec()
	await gate.hold_end()
	var waited := Time.get_ticks_msec() - start
	check(waited >= int(ViewGate.HOLD_CAP * 1000.0) - 50 and waited < int(ViewGate.HOLD_CAP * 1000.0) + 500,
		"a hold never released: the cap (%d ms)" % waited)
	eq(gate.open_holds(), 0, "the cap clears the holds")


func test_an_open_fade_holds_the_gate() -> void:
	var gate := ViewGate.new()
	UnitStyle.use(StyleRegistry.new(), "test")
	UnitStyle.registry().enemy_death = _fade(0.05, 0.1, 0.05)
	var view := _view(&"E1")
	view.die()
	eq(gate.open_holds(), 1, "a fading enemy holds the battle's end")
	var start := Time.get_ticks_msec()
	await gate.hold_end()
	var driver := view.death_fade_driver()
	check(driver != null and driver.is_done() and driver.clock >= 0.2, "the end waited for the fade and its beat (%s, %d ms)" % [
		driver.clock if driver != null else -1.0, Time.get_ticks_msec() - start])
	eq(gate.open_holds(), 0, "a finished fade holds nothing")
	view.queue_free()


func _fight(gate: ViewGate, hold_seconds: float) -> Dictionary:
	var run := start_run(host, "7", ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"])
	_runs.append(run)
	var encounter: EncounterDefinition = run.content.encounters[&"fixture.encounter.lone"]
	var generator := FloorGenerator.new(run.content, run.structure, run.state.run_seed, run.state.floor_index)
	var enemies: Array = generator.resolve_enemies(encounter, null, true, null, RunSeeds.rng(1, "test"))
	var cell := run.state.current_cell
	run.state.map.cells[cell]["content"]["enemies"] = enemies
	run.pending_battle = {"cell": cell, "encounter": encounter.id, "enemies": enemies, "label": "/test"}
	gate.ability_began.connect(func(_unit_id: StringName, _ability: BattleAbility) -> void: gate.release_finished())
	var state := {"finished_at": 0, "held_until": 0, "current_while_held": false, "current_at_finish": true}
	run.battle_finished.connect(func(_outcome: String) -> void:
		state["finished_at"] = Time.get_ticks_msec()
		state["current_at_finish"] = run.current_battle != null)
	if hold_seconds > 0.0:
		var id := gate.begin_hold()
		run.battle_started.connect(func(battle: Battle) -> void:
			await battle.battle_ended
			await host.get_tree().create_timer(hold_seconds).timeout
			# Review fix: the battle stays current and alive through the wait (a rebuild waits for battle_finished while it is set).
			state["current_while_held"] = run.current_battle == battle and is_instance_valid(battle) \
				and not battle.is_queued_for_deletion()
			state["held_until"] = Time.get_ticks_msec()
			gate.end_hold(id))
	eq(await run.fight(ScriptedController.new(), gate), "", "the fight runs")
	var logged: Dictionary = run.run_log.filter(func(e: Dictionary) -> bool: return e["type"] == "battle")[-1]
	return {"log": WireJson.stringify(logged), "finished_at": state["finished_at"], "held_until": state["held_until"],
		"current_while_held": state["current_while_held"], "current_at_finish": state["current_at_finish"]}


func test_the_run_waits_and_the_result_does_not_change() -> void:
	var plain := await _fight(ViewGate.new(), 0.0)
	var held := await _fight(ViewGate.new(), 0.3)
	check(held["held_until"] > 0 and held["finished_at"] >= held["held_until"], "battle_finished fires only after the hold is released")
	eq(held["log"], plain["log"], "the logged battle (outcome, final hash, action log) is the same with the wait")
	check(held["current_while_held"], "during the wait the battle is still current and alive")
	check(not held["current_at_finish"], "at battle_finished it is no longer current")


## Review fixes: Skip during the wait ends it and finishes the fades; the cap finishes a fade that never ends, so it cannot hold a
## later battle; the unit's label fades with it.
func test_skip_and_the_cap_finish_the_fades_and_the_label_fades() -> void:
	UnitStyle.use(StyleRegistry.new(), "test")
	UnitStyle.registry().enemy_death = _fade(5.0, 5.0, 0.0)
	var view := _view(&"E1")
	var label := Label3D.new()
	view.add_child(label)
	view.die()
	var driver := view.death_fade_driver()
	driver.set_process(false)
	driver.advance(5.0 + 2.5)
	check(label.modulate.a < 0.6 and label.modulate.a > 0.4, "the label is half faded with the cube (%.2f)" % label.modulate.a)
	driver.set_process(true)
	var gate := ViewGate.new()
	var skip := func() -> void:
		await host.get_tree().create_timer(0.2).timeout
		gate.skip_all = true
	skip.call()
	var start := Time.get_ticks_msec()
	await gate.hold_end()
	check(Time.get_ticks_msec() - start < 1000, "Skip during the wait ends it (%d ms)" % (Time.get_ticks_msec() - start))
	check(driver.is_done() and not view.visible, "and finishes the fade")
	view.revive()
	check(view.visible and is_equal_approx(label.modulate.a, 1.0), "a revive brings the label back")
	var stuck := _view(&"E2")
	stuck.die()
	stuck.death_fade_driver().set_process(false)  # a fade that never advances
	gate.skip_all = false
	await gate.hold_end()
	check(stuck.death_fade_driver().is_done(), "the cap finishes it")
	eq(gate.open_holds(), 0, "so it holds no later battle")
	view.queue_free()
	stuck.queue_free()


## Review fix: a unit that dies during its own cast starts its fade before its cast releases the gate (the release can run the
## battle on to its end, which waits only for fades that exist).
func test_a_death_during_a_cast_fades_before_the_gate_is_released() -> void:
	var view := _view(&"E1")
	var gate := ViewGate.new()
	var seen := [false]
	gate.released.connect(func() -> void: seen[0] = view.death_fade_driver() != null)
	view._gate = gate
	view.die()
	check(view.death_fade_driver() == null, "a cast is playing: the death waits")
	view._finish_montage()
	check(seen[0], "the fade exists when the gate is released")
	view.queue_free()


func test_the_base_gate_never_waits() -> void:
	var start := Time.get_ticks_msec()
	await PresentationGate.new().hold_end()
	await ClientGate.new().hold_end()
	check(Time.get_ticks_msec() - start < 50, "the replay's and scripted gates return at once")


func test_style_death_command() -> void:
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	var shown: Dictionary = await console.execute("style death")
	check(shown["ok"] and shown["text"].contains("enemy:") and shown["text"].contains("boss:"), "style death shows both fades: %s" % shown["text"])
	var refused: Dictionary = await console.execute("style death bogus")
	check(not refused["ok"] and refused["text"].contains("usage"), "a bad option shows the usage")
	var view := _view(&"E3")
	var test: Dictionary = await console.execute("style death test E3")
	# Headless the console has no game node, so the command refuses; with views it plays the fade (checked live).
	check(test["ok"] == (view.death_fade_driver() != null), "style death test plays on the named enemy or refuses: %s" % test["text"])
	view.queue_free()
