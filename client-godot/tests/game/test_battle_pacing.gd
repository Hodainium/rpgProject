## Spec playtest-fixes B16-B22: a spin no longer turns back when its montage fades out, a passive plays nothing (follow-ups do), casts never blink, the battle tears down silently, no
## screen time, and the view gate paces actions (minimum time on screen, a pause after) while skips cut it short.
## Presentation only: none of this is in a hash, a log or the verifier.
extends TestCase

const PROBE_VIEW := "res://tests/fixtures/views/probe_view.tscn"


static func _spin(turns: float = 1.0) -> Animation:
	var animation := Animation.new()
	animation.length = 0.8
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, "Body:rotation")
	animation.track_insert_key(track, 0.0, Vector3.ZERO)
	animation.track_insert_key(track, 0.8, Vector3(0, TAU * turns, 0))
	return animation


static func _same_pose(a: float, b: float) -> bool:
	return absf(fposmod(a - b + PI, TAU) - PI) < 0.02


func test_a_spin_stays_within_half_a_turn_and_keeps_its_motion() -> void:
	for turns in [1.0, 2.0, -1.0]:
		var spin := _spin(turns)
		var unwound := UnitAnimator.unwound(spin)
		check(unwound != spin, "%s turn(s): a copy" % turns)
		var track := unwound.find_track(NodePath("Body:rotation"), Animation.TYPE_VALUE)
		var widest := 0.0
		for index in unwound.track_get_key_count(track):
			widest = maxf(widest, absf((unwound.track_get_key_value(track, index) as Vector3).y))
		check(widest <= PI + 0.2, "%s turn(s): every key within about half a turn (widest %.2f)" % [turns, widest])
		var start: Vector3 = unwound.value_track_interpolate(track, 0.0)
		var end: Vector3 = unwound.value_track_interpolate(track, 0.8)
		check(absf(start.y) < 0.01 and absf(end.y) < 0.01, "%s turn(s): it starts and ends at rest, so the fades turn nothing" % turns)
		var off := 0
		for step in 81:
			var at := step * 0.01
			var original: Vector3 = spin.value_track_interpolate(0, at)
			var now: Vector3 = unwound.value_track_interpolate(track, at)
			if not _same_pose(original.y, now.y):
				off += 1
		eq(off, 0, "%s turn(s): the same pose at every moment" % turns)
	var still := Animation.new()
	var hop := still.add_track(Animation.TYPE_VALUE)
	still.track_set_path(hop, "Body:rotation")
	still.track_insert_key(hop, 0.0, Vector3.ZERO)
	still.track_insert_key(hop, 0.5, Vector3(0, 1.0, 0))
	check(UnitAnimator.unwound(still) == still, "a turn that stays within half a turn is played as it is")


func test_passives_play_nothing_but_follow_ups_do() -> void:
	var passive := BattleAbility.new()
	passive.trigger_event_tag = &"Event.Battle.Start"
	check(UnitAnimator.plays_nothing(passive), "a battle-start passive plays nothing (no spin, B21)")
	var follow_up := BattleAbility.new()
	follow_up.trigger_event_tag = &"Event.Damage.Dealt"
	follow_up.asset_tags.assign([BattleAbility.FOLLOW_UP_TAG])
	check(not UnitAnimator.plays_nothing(follow_up), "a follow-up attack still plays")
	var action := BattleAbility.new()
	check(not UnitAnimator.plays_nothing(action), "an action plays")
	passive.free()
	follow_up.free()
	action.free()


func test_casts_never_blink() -> void:
	var blink := _spin()
	var shown := blink.add_track(Animation.TYPE_VALUE)
	blink.track_set_path(shown, "Body:visible")
	blink.track_insert_key(shown, 0.0, false)
	blink.track_insert_key(shown, 0.1, true)
	var clean := UnitAnimator.without_blinks(blink)
	check(clean != blink, "a copy")
	eq(clean.find_track(NodePath("Body:visible"), Animation.TYPE_VALUE), -1, "without the visible track (B21)")
	check(clean.find_track(NodePath("Body:rotation"), Animation.TYPE_VALUE) != -1, "the motion stays")
	check(UnitAnimator.without_blinks(_spin()) is Animation, "an animation without a blink is played as it is")
	var flash_only := Animation.new()
	var only := flash_only.add_track(Animation.TYPE_VALUE)
	flash_only.track_set_path(only, "Body:visible")
	flash_only.track_insert_key(only, 0.0, false)
	check(not UnitAnimator.moves_model(UnitAnimator.without_blinks(flash_only)),
		"a flash-only cast moves nothing once cleaned, so the set's cast hop is merged in")


func test_an_invisible_passive_takes_no_screen_time() -> void:
	var view: UnitAnimator = load(PROBE_VIEW).instantiate()
	host.add_child(view)
	view.tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var passive := BattleAbility.new()
	passive.trigger_event_tag = &"Event.Test"
	var keys_only := Animation.new()
	keys_only.length = 0.3
	var method := keys_only.add_track(Animation.TYPE_METHOD)
	keys_only.track_set_path(method, ".")
	keys_only.track_insert_key(method, 0.0, {"method": &"execute", "args": [&"charge"]})
	passive.animation = keys_only
	var gate := ClientGate.new()
	gate.begin_ability(&"P1", passive, ExecutionReader.sequence_for(keys_only))
	view.play(passive, gate)
	check(gate._finished, "released at once, nothing played")
	passive.free()
	view.queue_free()


func _action(triggered: bool = false) -> BattleAbility:
	var ability := BattleAbility.new()
	if triggered:
		ability.trigger_event_tag = &"Event.Test"
	return ability


func _seconds_until_finished(gate: ViewGate) -> float:
	var waited := 0.0  # game time, the clock the gate waits on
	var finished := [false]
	var watch := func() -> void:
		await gate.finished()
		finished[0] = true
	watch.call()
	while not finished[0] and waited < 3.0:
		await host.get_tree().process_frame
		waited += host.get_tree().root.get_process_delta_time()
	return waited


func test_the_gate_paces_actions_and_skips_cut_it_short() -> void:
	var gate := ViewGate.new()
	gate.min_action_seconds = 0.3
	gate.pause_seconds = 0.2
	var action := _action()
	gate.begin_ability(&"P1", action, [&"hit"] as Array[StringName])
	gate.release_finished()
	eq(gate._released, 1, "the hits are released at once")
	check(not gate._finished, "the end waits")
	var took := await _seconds_until_finished(gate)
	check(took >= 0.45 and took < 1.0, "an action: its minimum time, then the pause (%.2f s)" % took)
	gate.begin_ability(&"P1", action, [] as Array[StringName])
	gate.release_finished()
	gate.skip()
	check(gate._finished, "skip ends the wait at once")
	var passive := _action(true)
	gate.begin_ability(&"P1", passive, [] as Array[StringName])
	gate.release_finished()
	check(gate._finished, "a triggered passive is never paced")
	var follow_up := _action(true)
	follow_up.asset_tags.assign([BattleAbility.FOLLOW_UP_TAG])
	gate.begin_ability(&"P1", follow_up, [] as Array[StringName])
	gate.release_finished()
	check(not gate._finished, "a follow-up attack is paced like an action (it plays like one)")
	gate.skip()
	follow_up.free()
	gate.skip_all = true
	gate.begin_ability(&"P1", action, [] as Array[StringName])
	check(gate._finished, "skip_all: at once")
	gate.skip_all = false
	gate.min_action_seconds = 0.0
	gate.pause_seconds = 0.0
	gate.begin_ability(&"P1", action, [] as Array[StringName])
	gate.release_finished()
	check(gate._finished, "both 0: pacing off")
	action.free()
	passive.free()


func test_the_pace_command() -> void:
	var console := DevConsole.new()
	console.keep_history = false
	console.load_commands(false)
	check(console.commands.has("pace"), "the Settings rows have the console command pace")
	var result: Dictionary = await console.execute("pace -1")
	check(not result["ok"], "a negative time is refused")


func test_a_finished_battle_tears_down_silently() -> void:
	var snap: Dictionary = preload("res://tests/combat/test_battle_v2.gd").v2_snapshot("7")
	var battle := Battle.new()
	host.add_child(battle)
	eq(battle.setup(snap, fixtures()), "", "the battle builds")
	var router := GameplayMessageRouter.new()
	host.add_child(router)
	var heard: Array = []
	router.listen(&"Message.Battle", func(channel, _message): heard.append(channel), GameplayMessageRouter.Match.PARTIAL, null,
		router)
	BattleMessages.new().attach(battle, &"fixture.encounter.pack", router)
	await battle.run(ScriptedController.new())
	check(heard.has(GameplayMessageRouter.BATTLE_ENDED), "the end is broadcast")
	for unit in battle.units():
		check(unit.asc.cues_closed, "%s: cues closed at the end (B22)" % unit.unit_id)
	var at_end := heard.size()
	battle.free()
	eq(heard.size(), at_end, "freeing it broadcasts nothing more (no phantom numbers, B22)")
	router.free()
