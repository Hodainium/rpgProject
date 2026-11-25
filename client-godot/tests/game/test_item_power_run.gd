## Spec item-power, around the kernel: copies that a run outcome names (2.2), the HOLDER recipient, the validator's proc rules,
## the play report's procs, the faster pacing of a chain and the bots' fit rule. Fixtures only.
extends TestCase

var _runs: Array[RunController] = []
var _nodes: Array[Node] = []


func after_each() -> void:
	super()
	for node in _nodes:
		if is_instance_valid(node):
			node.free()
	_nodes.clear()
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()


func _run(content: ContentIndex) -> RunController:
	var run := RunController.new()
	host.add_child(run)
	_runs.append(run)
	eq(run.start_run(content, ["fixture.character.knight", "fixture.character.medic"], "7"), "", "run starts")
	return run


func _give(item: ItemDefinition, recipient: int) -> GiveItem:
	var gift := GiveItem.new()
	gift.item = item
	gift.recipient = recipient as GiveItem.Recipient
	return gift


# --- Copies and HOLDER ---------------------------------------------------------------------------------------------------

func test_a_named_item_given_twice_is_held_and_fights_twice() -> void:
	var run := _run(fixtures())
	var copied: ItemDefinition = fixtures().items[&"fixture.item.ip_copy"]
	for time in 2:
		_give(copied, GiveItem.Recipient.FIRST).apply(run)
	eq(run.state.member(1)["items"].count(copied.id), 2, "held twice")
	check(run._pools()["held"].has(copied.id), "pools see it as held, so they never offer another")
	var member: Dictionary = run.state.member(1)
	var snap: Dictionary = preload("res://tests/combat/test_item_power.gd").power_snapshot({}, "named", "3")
	snap["party"][0]["items"] = member["items"].filter(func(id) -> bool: return id == copied.id).map(func(id) -> String: return String(id))
	var battle := new_battle(snap)
	eq(battle.unit_by_id(&"P1").abilities().filter(func(ability: BattleAbility) -> bool:
		return ability.ability_tag == &"Fixture.Ability.IpCopyHit").size(), 2, "and it fights with both")


func test_holder_recipient_gives_to_the_member_whose_hook_runs() -> void:
	var content := ContentIndex.new(FIXTURES)
	var gold := ItemDefinition.new()
	gold.id = &"test.item.gold"
	content.items[gold.id] = gold
	var coin := ItemDefinition.new()
	coin.id = &"test.item.coin"
	coin.on_floor_start.assign([_give(gold, GiveItem.Recipient.HOLDER)])
	content.items[coin.id] = coin
	var run := _run(content)
	run.state.member(2)["items"].append(coin.id)
	for floor_number in 2:
		run._run_hooks("on_floor_start")
	eq(run.state.member(1)["items"].count(gold.id), 0, "not the first member")
	eq(run.state.member(2)["items"].count(gold.id), 2, "one more at each floor's start, to the holder")
	run.state.member(2)["alive"] = false
	run._run_hooks("on_floor_start")
	eq([run.state.member(1)["items"].count(gold.id), run.state.member(2)["items"].count(gold.id)], [0, 3], "a dead holder keeps being paid")
	_give(gold, GiveItem.Recipient.HOLDER).apply(run)
	eq(run.state.member(1)["items"].count(gold.id), 1, "outside a hook it falls back to the first who can hold it")


## A pool pick (it may be food) never goes to a dead holder.
func test_a_drawn_item_is_not_lost_on_a_dead_holder() -> void:
	for alive in [true, false]:
		var content := ContentIndex.new(FIXTURES)
		var drop := ItemDefinition.new()
		drop.id = &"test.item.drop"
		drop.tags.assign([&"Pool.TestDrop"])
		content.items[drop.id] = drop
		var run := _run(content)
		var drawn := _give(null, GiveItem.Recipient.HOLDER)
		drawn.item_query = GameplayTagQuery.new()
		drawn.item_query.require_all_tags.assign([&"Pool.TestDrop"])
		run.state.member(2)["alive"] = alive
		run.hook_slot = 2
		drawn.apply(run)
		run.hook_slot = 0
		eq([run.state.member(1)["items"].count(drop.id), run.state.member(2)["items"].count(drop.id)], [0, 1] if alive else [1, 0],
			"to the holder while alive, else to a living member")


# --- Validator -----------------------------------------------------------------------------------------------------------

func _codes(ability: BattleAbility) -> Array:
	var validator := ContentValidator.new(fixtures())
	validator._check_procs(ability, "test")
	ability.free()
	return validator.issues.map(func(issue: ValidationIssue) -> String: return issue.code)


func _ability(scene: String) -> BattleAbility:
	return load(FIXTURES + "abilities/%s.tscn" % scene).instantiate()


func test_validator_proc_rules() -> void:
	for scene in ["ip_bell", "ip_hook", "ip_twin", "ip_reflect", "ip_drink", "ip_spread", "ip_undying", "strike"]:
		eq(_codes(_ability(scene)), [], "%s is fine" % scene)
	var action := _ability("strike")
	action.trigger_chance_x100 = 3000
	eq(_codes(action), ["trigger_chance_on_action"], "a chance on an action")
	var kind := _ability("ip_knife")
	var row: ExecutionRow = kind.executions[0].duplicate()
	row.effect = load(FIXTURES + "effects/st_ward.tres")
	kind.executions = [row] as Array[ExecutionRow]
	eq(_codes(kind), ["random_target_on_ally"], "a buff on a random enemy")
	var mute := _ability("ip_twin")
	mute.trigger_event_tag = Battle.EVENT_UNIT_KILLED
	eq(_codes(mute), ["echo_without_trigger"], "an echo of nothing that was used")
	var unscaled := _ability("ip_twin")
	unscaled.echo_scale_x100 = 0
	eq(_codes(unscaled), ["echo_without_trigger"], "an echo without a scale")
	var early := _ability("ip_drink")
	early.trigger_event_tag = Battle.EVENT_BATTLE_START
	eq(_codes(early), ["event_amount_outside_trigger"], "an amount from an event that has none")
	var spread := _ability("ip_spread")
	spread.trigger_event_tag = Battle.EVENT_DAMAGE_DEALT
	eq(_codes(spread), ["event_effect_outside_tick"], "the event's effect where there is none")


func test_validator_holder_recipient() -> void:
	var gift := _give(fixtures().items[&"fixture.item.whetstone"], GiveItem.Recipient.HOLDER)
	var validator := ContentValidator.new(fixtures())
	validator._check_outcome(gift, "test", null, false, true)
	eq(validator.issues.size(), 0, "fine in an item hook")
	var named := _give(gift.item, GiveItem.Recipient.HOLDER)
	named.character = fixtures().characters[&"fixture.character.knight"]
	var warned := ContentValidator.new(fixtures())
	warned._check_outcome(named, "test", null, false, true)
	eq(warned.issues.map(func(issue): return issue.code), ["holder_ignores_character"], "a named character is ignored: a warning")
	validator._check_outcome(gift, "test", null)
	eq(validator.issues.map(func(issue): return issue.code), ["give_holder_outside_item"], "an error elsewhere")


func test_validator_knows_the_new_events() -> void:
	var known := ContentValidator.new(fixtures())._battle_events()
	for event in [Battle.EVENT_ALLY_DAMAGE_TAKEN, Battle.EVENT_ALLY_ULTIMATE, Battle.EVENT_DOT_DEALT, Battle.EVENT_DOT_TAKEN,
			Battle.EVENT_SKILL_USED, Battle.EVENT_UNIT_DYING, &"Event.Damage.Dealt.Echo"]:
		check(known.has(event), "%s is an event the battle sends" % event)


# --- Play report, pacing, hints, bots ------------------------------------------------------------------------------------

func test_report_counts_procs() -> void:
	var record := {"battles": [{}], "party": []}
	var battle := new_battle(preload("res://tests/combat/test_item_power.gd").power_snapshot(
		{1: ["crown", "hook"], 2: ["copy", "copy", "vow"]}, "procs", "3"))
	for ability in battle.unit_by_id(&"P1").abilities() + battle.unit_by_id(&"P2").abilities():
		if ability.trigger_chance_x100 > 0:
			ability.trigger_chance_x100 = 10000  # always, and still a chance
	PlayReport._watch_procs(battle, fixtures(), record)
	for action in [[&"P2", &"Fixture.Ability.Strike", &"E1"], [&"P1", &"Fixture.Ability.Strike", &"E1"],
			[&"E3", &"Fixture.Ability.FireBolt", &"P1"]]:
		var unit := battle.unit_by_id(action[0])
		await battle._activate(unit, unit.ability_by_tag(action[1]), battle.unit_by_id(action[2]))
		await battle._drain_triggers()
	battle.battle_ended.emit("Victory", "")
	var block := PlayReport.proc_block([record] as Array[Dictionary])
	eq(block["hooks"]["K8 copy"]["fires"], 2, "both copies' triggers: %s" % block)
	check(block["hooks"]["K1 ally"]["fires"] >= 1, "the counter")
	check(block["hooks"]["K3 chance"]["fires"] >= 3, "the chances")
	check(block["hooks"]["K4 random"]["fires"] >= TriggerQueue.MAX_DEPTH, "the random targets")
	eq(block["items"]["fixture.item.ip_copy"]["fires"], 2, "by item")
	eq(block["items"]["fixture.item.ip_copy"]["perBattleX100"], 200, "per battle (x100)")
	eq(block["chainCapHits"], 1, "the crown's chain reached the cap")
	eq(PlayReport.proc_block([{"battles": [{}]}] as Array[Dictionary]), {}, "no block without procs")


func test_a_chained_attack_is_paced_faster() -> void:
	var gate := ViewGate.new()
	gate.min_action_seconds = 1.0
	gate.pause_seconds = 0.4
	var follow_up: BattleAbility = _ability("ip_vow")
	_nodes.append(follow_up)
	gate.chained = true
	gate.begin_ability(&"P1", follow_up, [&"hit"] as Array[StringName])
	gate.release_finished()
	check(not gate._finished, "still a moment on screen")
	check(gate._min_timer.time_left <= ViewGate.CHAINED_MIN_ACTION, "a shorter minimum time")
	eq(gate._pause, ViewGate.CHAINED_PAUSE, "and a shorter pause")
	var took := await _seconds_until_finished(gate)
	var short := ViewGate.CHAINED_MIN_ACTION + ViewGate.CHAINED_PAUSE
	check(took > 0.1, "but not at once (%.2f s)" % took)
	Engine.time_scale = 3.0
	gate.begin_ability(&"P1", follow_up, [&"hit"] as Array[StringName])
	gate.release_finished()
	var start := Time.get_ticks_msec()
	await _seconds_until_finished(gate)
	var real := (Time.get_ticks_msec() - start) / 1000.0
	Engine.time_scale = 1.0
	check(real < short, "and the play speed scales it (%.2f s at 3x)" % real)
	gate.min_action_seconds = 0.2
	gate.pause_seconds = 0.0
	gate.begin_ability(&"P1", follow_up, [&"hit"] as Array[StringName])
	check(gate._min_timer.time_left <= 0.2, "never longer than the player's own pacing")
	eq(gate._pause, 0.0, "nor its pause")
	gate.release_finished()
	await _seconds_until_finished(gate)


func _seconds_until_finished(gate: ViewGate) -> float:
	var waited := 0.0
	var finished := [false]
	var watch := func() -> void:
		await gate.finished()
		finished[0] = true
	watch.call()
	while not finished[0] and waited < 4.0:
		await host.get_tree().process_frame
		waited += host.get_tree().root.get_process_delta_time()
	return waited


func test_strikes_and_echoes_on_screen() -> void:
	var strike := _ability("ip_knife")
	var passive := _ability("ip_vow_heal")
	_nodes.append_array([strike, passive])
	check(not strike.is_follow_up() and strike.plays_like_attack(), "a strike is no follow-up but plays like one")
	check(not UnitAnimator.plays_nothing(strike), "so the view animates it")
	check(UnitAnimator.plays_nothing(passive), "another passive stays still")
	eq(AbilityHint.TARGET_TEXT.size(), BattleAbility.Targeting.size(), "every targeting has its words")


func test_fit_of_a_follow_up_that_answers_follow_ups() -> void:
	var crown: ItemDefinition = fixtures().items[&"fixture.item.ip_crown"]
	eq(FitProposal.propose(crown), [LootScorer.FIT_FOLLOW_UP], "it fits a follow-up character but makes nobody one")
	eq(FitProposal.propose(fixtures().items[&"fixture.item.ip_hook"]), [LootScorer.FIT_FOLLOW_UP, LootScorer.GRANT_FOLLOW_UP],
		"an on-hit follow-up does")
