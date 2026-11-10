## Spec content-pass: statuses (H1 control, H2 chance, H3 stacked DoTs, H6 delay and advance, taunt, cleanse and
## dispel), affinities (drain, weak, resist) and the combined break and ult events (H4). Fixtures only: hexer and guard
## against the status trial (E1 wisp, E2 toad, E3 imp).
extends TestCase

const EFFECTS: String = "res://tests/fixtures/effects/"


## v2 snapshot of fixture characters. `items`: slot -> [item names].
static func status_snapshot(party: Array = ["hexer", "guard"], encounter: String = "status_trial", seed_text: String = "3",
		items: Dictionary = {}) -> Dictionary:
	var members: Array = []
	for index in party.size():
		var held: Array = []
		for name in items.get(index + 1, []):
			held.append("fixture.item." + name)
		members.append({"slot": index + 1, "unitDefId": "fixture.character." + party[index], "level": 1, "skills": [],
			"equipmentIds": [], "items": held, "useSlots": []})
	return {
		"schemaVersion": 2,
		"battleId": "status-seed-%s" % seed_text,
		"seed": seed_text,
		"encounterId": "fixture.encounter." + encounter,
		"party": members,
	}


## Applies a fixture effect from `source` to `target` (a flat damage override and row tags optional).
static func apply(source: BattleUnit, target: BattleUnit, effect_name: String, flat: int = 0, tags: Array = []) -> void:
	var context := GameplayEffectContext.new(source, source)
	context.target_data.append_node(target)
	var spec := GameplayEffectSpec.new(load(EFFECTS + effect_name + ".tres"), context, 1)
	if flat > 0:
		spec.set_set_by_caller_magnitude(ExecutionRow.DAMAGE_FLAT_TAG, float(flat))
	for tag in tags:
		spec.inject_tag(tag)
	source.asc.apply_effect_spec_to_target(spec, target.asc)


static func listen(unit: BattleUnit) -> Array:
	var received := []
	unit.asc.gameplay_event_received.connect(func(tag, payload): received.append([String(tag), payload]))
	return received


static func names(received: Array, prefix: String) -> Array:
	return received.filter(func(event): return event[0].begins_with(prefix)).map(func(event): return event[0])


static func ability(unit: BattleUnit, name: String) -> BattleAbility:
	return unit.ability_by_tag(StringName("Fixture.Ability." + name))


static func ids(units: Array) -> Array:
	return units.map(func(unit: BattleUnit) -> String: return String(unit.unit_id))


static func active(unit: BattleUnit, effect_name: String) -> ActiveGameplayEffect:
	for active_effect in unit.asc._active_effects:
		if active_effect.get_effect_def().resource_path == EFFECTS + effect_name + ".tres":
			return active_effect
	return null


func test_poison_ticks_per_stack() -> void:
	var battle := new_battle(status_snapshot())
	var hexer := battle.unit_by_id(&"P1")
	var toad := battle.unit_by_id(&"E2")
	await battle._activate(hexer, ability(hexer, "ToxicCloud"), null)  # two execute keys: two stacks on each enemy
	eq(active(toad, "st_poison").stack_count, 2, "two applications stack")
	var before := toad.stat("hp")
	toad.asc.turn_start()
	eq(before - toad.stat("hp"), 4000, "each stack ticks: 2 × 20 HP")
	apply(toad, hexer, "st_poison")
	before = hexer.stat("hp")
	hexer.asc.turn_start()
	eq(before - hexer.stat("hp"), 2000, "a single stack ticks once, as before")


## Spec vfx-content-pass 2.5: a DoT tick and a drain's heal are HP changes with no damage_dealt; hp_changed reports them
## (negative for a loss, with the status tags of the cause), and a row hit's own damage is not repeated there.
func test_hp_changed_reports_dots_and_heals() -> void:
	var battle := new_battle(status_snapshot())
	var hexer := battle.unit_by_id(&"P1")
	var toad := battle.unit_by_id(&"E2")
	var changes := []
	battle.hp_changed.connect(func(unit, delta, cause): changes.append([unit, delta, cause]))
	await battle._activate(hexer, ability(hexer, "ToxicCloud"), null)
	var after_cast := changes.filter(func(change): return change[1] < 0)
	check(after_cast.is_empty(), "applying a DoT is no HP change and no row damage is repeated: %s" % [changes])
	toad.asc.turn_start()
	var ticks := changes.filter(func(change): return change[0] == &"E2")
	eq(ticks.size(), 1, "two stacks are one tick: one report")
	eq(ticks[0][1], -4000, "the stacks' damage summed: 2 x 20 HP is -40.00 (x100)")
	check(ticks[0][2].has(&"Status.Debuff.Poison"), "the cause is the poison status")


## Spec vfx-content-pass 2.5: a different DoT on the same unit is its own tick and its own report.
func test_two_dots_report_separately() -> void:
	var battle := new_battle(status_snapshot())
	var hexer := battle.unit_by_id(&"P1")
	var toad := battle.unit_by_id(&"E2")
	var changes := []
	battle.hp_changed.connect(func(unit, delta, cause): changes.append([unit, delta, cause]))
	apply(hexer, toad, "st_poison")
	apply(hexer, toad, "st_burn", 3000, [&"Damage.Type.Fire"])
	toad.asc.turn_start()
	var mine := changes.filter(func(change): return change[0] == &"E2")
	eq(mine.size(), 2, "poison and burn each report once")
	var causes := mine.map(func(change): return change[2][0] if not change[2].is_empty() else &"")
	check(causes.has(&"Status.Debuff.Poison") and causes.has(&"Status.Debuff.Burn"), "each with its own status: %s" % [causes])


func test_refresh_vs_stack() -> void:
	var battle := new_battle(status_snapshot())
	var hexer := battle.unit_by_id(&"P1")
	var toad := battle.unit_by_id(&"E2")
	for i in 7:
		apply(hexer, toad, "st_poison")
	eq(active(toad, "st_poison").stack_count, 5, "max_stacks caps the stacks")
	toad.asc.turn_start()
	eq(active(toad, "st_poison").spec.remaining_turns, 2, "one countdown per effect, not per stack")
	apply(hexer, toad, "st_poison")
	eq(active(toad, "st_poison").spec.remaining_turns, 3, "reapplying at the cap refreshes the duration")
	apply(hexer, toad, "st_freeze")
	apply(hexer, toad, "st_freeze")
	var freezes := toad.asc._active_effects.filter(func(e): return e.get_effect_def().resource_path.ends_with("st_freeze.tres"))
	eq(freezes.size(), 1, "a non-stacking status (REFRESH_DURATION, max 1) is one effect, refreshed")
	eq(freezes[0].stack_count, 1, "with one stack")


func test_status_durations_and_countdown() -> void:
	var battle := new_battle(status_snapshot())
	var hexer := battle.unit_by_id(&"P1")
	var toad := battle.unit_by_id(&"E2")
	apply(hexer, toad, "st_burn", 3000, [&"Damage.Type.Fire"])
	apply(hexer, toad, "st_vulnerable")
	var hp := toad.stat("hp")
	toad.asc.turn_start()
	check(toad.stat("hp") < hp, "a DoT ticks at the holder's turn start")
	toad.asc.turn_end()
	check(toad.asc.has_tag_exact(&"Status.Debuff.Vulnerable"), "a 2-turn debuff survives its first turn end")
	toad.asc.turn_start()
	toad.asc.turn_end()
	check(not toad.asc.has_tag_exact(&"Status.Debuff.Burn"), "the DoT ends after its 2 ticks")
	check(not toad.asc.has_tag_exact(&"Status.Debuff.Vulnerable"), "the debuff ends at its second turn end")


func test_status_roll_only_when_needed() -> void:
	var battle := new_battle(status_snapshot())
	var hexer := battle.unit_by_id(&"P1")
	var guard := battle.unit_by_id(&"P2")
	var toad := battle.unit_by_id(&"E2")
	var plain := ExecutionRow.new()
	plain.effect = load(EFFECTS + "st_freeze.tres")
	var state := battle.rng.state
	check(battle._status_lands(guard, toad, plain), "a row without a chance always lands (D13)")
	eq(battle.rng.state, state, "and draws nothing")
	var sure := plain.duplicate()
	sure.chance_x100 = 10000
	check(battle._status_lands(guard, toad, sure), "100% lands")
	eq(battle.rng.state, state, "without a roll")
	var freeze_row := ability(hexer, "FrostHex").row_by_id(&"freeze")
	battle._status_lands(hexer, toad, freeze_row)
	check(battle.rng.state != state, "50% rolls once")


## Spec content-pass H8: a row's turn-based debuff lasts the source's debuff_turns longer; buffs don't.
func test_debuff_turns() -> void:
	var battle := new_battle(status_snapshot())
	var hexer := battle.unit_by_id(&"P1")
	var toad := battle.unit_by_id(&"E2")
	var base_turns: int = (load(EFFECTS + "st_vulnerable.tres") as GameplayEffect).duration_turns
	hexer.asc.initialize_attribute_overrides({"debuff_turns": 100.0})
	var row := ExecutionRow.new()
	row.id = &"hex"
	row.effect = load(EFFECTS + "st_vulnerable.tres")
	var hex := ability(hexer, "Strike").duplicate() as BattleAbility
	battle.resolve_execution(hexer, hex, row, {"primary": toad, "targets": [toad] as Array[BattleUnit]})
	eq(active(toad, "st_vulnerable").spec.remaining_turns, base_turns + 1, "+1 turn from debuff_turns 1")
	var buff := ExecutionRow.new()
	buff.effect = load(EFFECTS + "st_taunt.tres")
	battle.resolve_execution(hexer, hex, buff, {"primary": hexer, "targets": [hexer] as Array[BattleUnit]})
	eq(active(hexer, "st_taunt").spec.remaining_turns, (load(EFFECTS + "st_taunt.tres") as GameplayEffect).duration_turns,
		"a buff keeps its own duration")
	hex.free()


func test_immunity_no_roll() -> void:
	var battle := new_battle(status_snapshot(["guard"], "knight_one"))
	var guard := battle.unit_by_id(&"P1")
	var knight := battle.unit_by_id(&"E1")
	var row := ExecutionRow.new()
	row.effect = load(EFFECTS + "st_stun.tres")
	row.chance_x100 = 4000
	var state := battle.rng.state
	check(battle._status_lands(guard, knight, row), "an immune target skips the roll (GodotGAS refuses the effect)")
	eq(battle.rng.state, state, "no RNG draw for an immune target")
	apply(guard, knight, "st_stun")
	check(not knight.asc.has_tag_exact(&"State.Controlled"), "Immune.Control refuses the stun")


func test_resisted_status_event() -> void:
	var battle := new_battle(status_snapshot())
	var guard := battle.unit_by_id(&"P2")
	var wisp := battle.unit_by_id(&"E1")
	var row := ExecutionRow.new()
	row.id = &"freeze"
	row.effect = load(EFFECTS + "st_freeze.tres")
	row.chance_x100 = 3500
	var dealt := listen(guard)
	var taken := listen(wisp)
	var resisted := []
	battle.status_resisted.connect(func(source, target, path): resisted.append([source, target, path]))
	var misses := 0
	for i in 20:
		if not battle._status_lands(guard, wisp, row):
			misses += 1
	check(misses > 0 and misses < 20, "a 35%% chance both lands and misses over 20 rolls (got %d misses)" % misses)
	eq(names(dealt, "Event.Status.Resisted").size(), misses, "the source hears every miss")
	eq(names(taken, "Event.Status.Resisted").size(), misses, "so does the target")
	eq(resisted.size(), misses, "and the read-only signal")


func test_control_skip_record_replay() -> void:
	var snap := status_snapshot()
	var battle := new_battle(snap)
	battle.unit_by_id(&"P1").asc.apply_gameplay_effect(load(EFFECTS + "st_freeze.tres"),
		battle.unit_by_id(&"E1").asc, 1)
	var skipped := []
	battle.turn_skipped.connect(func(unit_id): skipped.append([unit_id, battle.turn]))
	var controller := ScriptedController.new()
	await battle.run(controller)
	check(battle.runner_error == "", battle.runner_error)
	check(not skipped.is_empty() and skipped[0][0] == &"P1", "the frozen party unit's first turn is skipped")
	var skipped_turn: int = skipped[0][1]
	for entry in controller.entries:
		# An ult cast in the BETWEEN window after the skipped turn carries the same turn number; it isn't the turn's action.
		if not entry.get("interrupt", false):
			check(not (int(entry["turn"]) == skipped_turn and entry["actor"] == "P1"), "nothing is logged for the skipped turn")
	check(not battle.unit_by_id(&"P1").asc.has_tag_exact(&"State.Controlled"), "the freeze counts down on the skipped turn")


## H1 in the recorded flow: an enemy freezes a party unit, the skip is re-simulated in replay, and an entry claimed for
## the frozen turn is a 2002 TurnMismatch. (The golden status-seed-3 carries the same case.)
func test_skip_replays_and_tamper_rejects() -> void:
	var recorded := await _record_with_skip()
	if recorded.is_empty():
		return
	var verdict := await replay(recorded["request"])
	eq(verdict.get("verdict"), "Verified", "a battle with a skipped party turn replays")
	var tampered := copy(recorded["request"])
	var actions: Array = tampered["actionLog"]["actions"]
	var at := 0
	while at < actions.size() and int(actions[at]["turn"]) < int(recorded["turn"]):
		at += 1
	actions.insert(at, {"turn": recorded["turn"], "actor": str(recorded["unit"]), "ability": "Fixture.Ability.Strike",
		"target": "E1"})
	var rejected := await replay(tampered)
	eq(rejected.get("verdict"), "Rejected", "an entry on the frozen turn is rejected")
	eq(rejected.get("errorCode"), 2002, "with 2002")
	eq(rejected.get("mismatch", {}).get("reason"), "TurnMismatch", "as a TurnMismatch")


## Records the golden status battle and returns {"request", "unit", "turn"} for its first skipped party turn.
func _record_with_skip() -> Dictionary:
	var snap := preload("res://tests/combat/test_golden.gd").status_golden_snapshot()
	var battle := new_battle(snap)
	var skipped := []
	battle.turn_skipped.connect(func(unit_id): skipped.append([unit_id, battle.turn]))
	var controller := ScriptedController.new()
	await battle.run(controller)
	var party_skips := skipped.filter(func(skip): return String(skip[0]).begins_with("P"))
	check(not party_skips.is_empty(), "the status golden's battle skips a frozen party turn")
	if party_skips.is_empty():
		return {}
	return {
		"request": {"snapshot": snap, "actionLog": ActionRecorder.build_log(controller.entries, battle.outcome, battle.final_hash)},
		"unit": party_skips[0][0],
		"turn": party_skips[0][1],
	}


func test_drain_heals_and_events() -> void:
	var battle := new_battle(status_snapshot(["hexer", "guard"], "status_trial", "3", {2: ["implant"]}))
	var guard := battle.unit_by_id(&"P2")
	var imp := battle.unit_by_id(&"E3")
	guard.asc.initialize_attribute_overrides({"hp": 100000.0})
	var hit_by := guard.last_hit_by
	var taken := listen(guard)
	var dealt := listen(imp)
	var drained := []
	battle.damage_drained.connect(func(source, target, amount, tags): drained.append([source, target, amount, tags]))
	var damaged := []
	battle.damage_dealt.connect(func(_s, target, amount, _t): damaged.append([target, amount]))
	var state := battle.rng.state
	await battle._activate(imp, ability(imp, "FireBolt"), guard)
	# FLAT 60 × DEF multiplier (DEF 400: 100% − 400/1400 = 71.43%) = 42.85, healed instead of dealt.
	eq(guard.stat("hp"), 104285, "the drained Fire hit heals the guard")
	eq(battle.rng.state, state, "a drained hit takes no crit roll")
	eq(drained, [[&"E3", &"P2", 4285, [&"Hit.Drained", &"Damage.Type.Fire"]]], "damage_drained reports the heal and what was absorbed (the hit and its damage type)")
	eq(damaged, [], "no damage_dealt")
	eq(names(taken, "Event.Damage.Taken"), ["Event.Damage.Taken.Drained"], "only the Drained event: Taken triggers stay silent")
	eq(names(dealt, "Event.Damage.Dealt"), ["Event.Damage.Dealt.Drained"], "the attacker hears Dealt.Drained")
	check(guard.last_hit_by == hit_by, "a drain credits no hit")
	await battle._drain_triggers()
	eq(guard.stat("energy"), 1000, "Siphon (Damage.Taken.Drained) charged the ult")


func test_drain_beats_weakness_and_resist() -> void:
	var battle := new_battle(status_snapshot(["hexer", "guard"], "status_trial", "3", {2: ["implant"]}))
	var guard := battle.unit_by_id(&"P2")
	var imp := battle.unit_by_id(&"E3")
	guard.asc.add_tag(&"Weakness.Fire")
	guard.asc.add_tag(&"Resist.Fire")
	var hp := guard.stat("hp")
	guard.asc.initialize_attribute_overrides({"hp": 100000.0})
	var drained := []
	battle.damage_drained.connect(func(_s, _t, amount, _tags): drained.append(amount))
	await battle._activate(imp, ability(imp, "FireBolt"), guard)
	eq(drained, [4285], "Drain > Weak > Resist: drained, at the plain amount")
	check(hp > 0, "setup")


func test_weakness_beats_resist() -> void:
	var battle := new_battle(status_snapshot(["hexer", "guard"], "status_trial", "3", {2: ["implant", "frostguard"]}))
	var guard := battle.unit_by_id(&"P2")
	var hexer := battle.unit_by_id(&"P1")
	var wisp := battle.unit_by_id(&"E1")
	check(guard.asc.has_tag_exact(&"Weakness.Ice") and guard.asc.has_tag_exact(&"Resist.Ice"), "implant + frostguard")
	var hits := []
	battle.damage_dealt.connect(func(_s, target, amount, hit_tags): hits.append([target, amount, hit_tags]))
	await battle._activate(wisp, ability(wisp, "FrostTouch"), guard)
	# FLAT 50 × 71.43% = 35.71, × 150% weakness damage = 53.56.
	eq(hits[0], [&"P2", 5356, [&"Hit.Weakness", &"Damage.Type.Ice"]], "the implant's weakness wins over Frostguard's resist (D4)")
	var resisted := status_snapshot(["hexer"], "status_trial", "3", {1: ["frostguard"]})
	var second := new_battle(resisted)
	var plain_hits := []
	second.damage_dealt.connect(func(_s, target, amount, hit_tags): plain_hits.append([target, amount, hit_tags]))
	await second._activate(second.unit_by_id(&"E1"), ability(second.unit_by_id(&"E1"), "FrostTouch"), second.unit_by_id(&"P1"))
	# DEF 200: 100% − 200/1200 = 83.34%; 50 × 83.34% = 41.67, × 50% resist = 20.83.
	eq(plain_hits[0], [&"P1", 2083, [&"Hit.Resisted", &"Damage.Type.Ice"]], "a resisted hit: × resist_dmg and Hit.Resisted")
	check(hexer != null, "setup")


func test_drain_dot_tick() -> void:
	var battle := new_battle(status_snapshot(["hexer", "guard"], "status_trial", "3", {2: ["implant"]}))
	var guard := battle.unit_by_id(&"P2")
	var imp := battle.unit_by_id(&"E3")
	guard.asc.initialize_attribute_overrides({"hp": 100000.0})
	apply(imp, guard, "st_burn", 3000, [&"Damage.Type.Fire"])
	guard.asc.turn_start()
	check(guard.stat("hp") > 100000, "a Fire DoT on a Fire drainer heals each tick")


func test_affinity_from_item() -> void:
	var without := new_battle(status_snapshot())
	var hits := []
	without.damage_dealt.connect(func(_s, _t, amount, _tags): hits.append(amount))
	await without._activate(without.unit_by_id(&"E3"), ability(without.unit_by_id(&"E3"), "FireBolt"), without.unit_by_id(&"P2"))
	eq(hits, [4285], "without the implant the Fire hit deals damage")
	var held := new_battle(status_snapshot(["hexer", "guard"], "status_trial", "3", {2: ["implant"]}))
	check(held.unit_by_id(&"P2").asc.has_tag_exact(&"Drain.Fire"), "the item's infinite effect grants the affinity tag")
	check(not without.unit_by_id(&"P2").asc.has_tag_exact(&"Drain.Fire"), "a battle without the item has none")


func test_taunt_targeting() -> void:
	var battle := new_battle(status_snapshot())
	var guard := battle.unit_by_id(&"P2")
	var hexer := battle.unit_by_id(&"P1")
	var imp := battle.unit_by_id(&"E3")
	var bolt := ability(imp, "FireBolt")
	eq(ids(battle.target_candidates(imp, bolt)), ["P1", "P2"], "no taunt: every party unit")
	await battle._activate(guard, ability(guard, "Provoke"), null)
	eq(ids(battle.target_candidates(imp, bolt)), ["P2"], "a taunter is the only valid single target")
	eq(battle.validate_action(imp, {"ability": bolt.ability_tag, "target": &"P1"})[0], "InvalidTarget",
		"aiming past the taunter is illegal")
	eq(battle.target_candidates(hexer, ability(hexer, "Strike")).size(), 3, "party targeting is unchanged")
	apply(imp, guard, "st_freeze")
	eq(ids(battle.target_candidates(imp, bolt)), ["P2"], "a controlled taunter still taunts")
	guard.alive = false
	eq(ids(battle.target_candidates(imp, bolt)), ["P1"], "a dead taunter taunts no more")


func test_cleanse_and_dispel() -> void:
	var battle := new_battle(status_snapshot())
	var hexer := battle.unit_by_id(&"P1")
	var guard := battle.unit_by_id(&"P2")
	var toad := battle.unit_by_id(&"E2")
	apply(toad, hexer, "st_poison")
	apply(toad, hexer, "st_vulnerable")
	apply(toad, guard, "st_burn", 3000, [&"Damage.Type.Fire"])
	await battle._activate(guard, ability(guard, "Provoke"), null)
	hexer.asc.initialize_attribute_overrides({"energy": 10000.0})
	await battle._interrupt(hexer, {"ability": &"Fixture.Ability.UltPurify", "target": &""}, ScriptedController.new())
	for unit in [hexer, guard]:
		check(not unit.asc.has_tag(&"Status.Debuff"), "%s: every debuff removed by a Cleanse that lists only Status.Debuff" % unit.unit_id)
	check(guard.asc.has_tag_exact(&"Status.Buff.Taunt"), "buffs stay")
	var dispel := GameplayEffect.new()
	dispel.policy = GameplayEffect.DurationPolicy.INSTANT
	dispel.remove_effects_with_tags.assign([&"Status.Buff"])
	guard.asc.apply_gameplay_effect(dispel, toad.asc, 1)
	check(not guard.asc.has_tag_exact(&"State.Taunting"), "a Dispel removes the buff with every tag it granted")


func test_controlled_cannot_ult() -> void:
	var battle := new_battle(status_snapshot(["breaker"]))
	var breaker := battle.unit_by_id(&"P1")
	breaker.asc.initialize_attribute_overrides({"energy": 10000.0})
	var locked := ability(breaker, "UltLocked")
	check(breaker.asc.can_activate_ability(locked), "a free unit can ult")
	apply(battle.unit_by_id(&"E1"), breaker, "st_freeze")
	check(not breaker.asc.can_activate_ability(locked), "a frozen unit's ult is refused by its activation query")
	var problem := battle.validate_interrupt(breaker, {"unit": &"P1", "ability": locked.ability_tag, "target": &"E1"}, true)
	eq(problem[0] if not problem.is_empty() else "", "IllegalAbility", "a logged ult from a frozen unit is 2002 IllegalAbility")


func test_breakout_ult() -> void:
	var battle := new_battle(status_snapshot(["breaker"]))
	var breaker := battle.unit_by_id(&"P1")
	breaker.asc.initialize_attribute_overrides({"energy": 10000.0})
	apply(battle.unit_by_id(&"E1"), breaker, "st_freeze")
	var breakout := ability(breaker, "UltBreakout")
	check(breaker.asc.can_activate_ability(breakout), "an ult without the requirement fires while frozen")
	await battle._interrupt(breaker, {"ability": breakout.ability_tag, "target": &""}, ScriptedController.new())
	check(not breaker.asc.has_tag_exact(&"State.Controlled"), "and breaks the freeze (its cleanse)")


func test_action_delay_and_advance() -> void:
	var battle := new_battle(status_snapshot())
	var hexer := battle.unit_by_id(&"P1")
	var guard := battle.unit_by_id(&"P2")
	var toad := battle.unit_by_id(&"E2")
	var delayed := []
	battle.action_delayed.connect(func(unit_id, percent): delayed.append([unit_id, percent]))
	var before: int = battle.turn_manager.av[toad]
	await battle._activate(guard, ability(guard, "Entangle"), toad)
	# Entangle's −10% SPD rescales the remaining action value first; the delay adds 30% of the new full value.
	var full := TurnManager.full_av(toad)
	eq(battle.turn_manager.av[toad], before * 9000 / toad.stat("spd") + Fixed.pct(full, 3000), "delayed by 30% of a full cycle")
	before = battle.turn_manager.av[hexer]
	await battle._activate(guard, ability(guard, "Rally"), hexer)
	eq(battle.turn_manager.av[hexer], before - Fixed.pct(TurnManager.full_av(hexer), 2500), "advanced by 25%")
	battle.turn_manager.av[hexer] = 100
	await battle._activate(guard, ability(guard, "Rally"), hexer)
	eq(battle.turn_manager.av[hexer], 0, "an advance stops at 0")
	eq(delayed, [[&"E2", 3000], [&"P1", -2500], [&"P1", -2500]], "action_delayed per landed row")


func test_delay_on_broken_unit() -> void:
	var battle := new_battle(status_snapshot())
	var guard := battle.unit_by_id(&"P2")
	var imp := battle.unit_by_id(&"E3")
	var before: int = battle.turn_manager.av[imp]
	await battle._activate(guard, ability(guard, "IceSlash"), imp)
	check(imp.asc.has_tag_exact(&"State.Broken"), "the Ice slash breaks the imp")
	var after_break: int = battle.turn_manager.av[imp]
	eq(after_break, before + Fixed.pct(TurnManager.full_av(imp), Battle.BREAK_DELAY), "the break delay")
	battle.turn_manager.av[imp] = after_break
	var spd := imp.stat("spd")
	await battle._activate(guard, ability(guard, "Entangle"), imp)
	eq(battle.turn_manager.av[imp], after_break * spd / imp.stat("spd") + Fixed.pct(TurnManager.full_av(imp), 3000),
		"Entangle's delay stacks on top of the break delay")


func test_delay_not_on_miss() -> void:
	var battle := new_battle(status_snapshot())
	var guard := battle.unit_by_id(&"P2")
	var wisp := battle.unit_by_id(&"E1")
	var entangle := ability(guard, "Entangle").duplicate() as BattleAbility
	var row: ExecutionRow = entangle.executions[0].duplicate()
	row.chance_x100 = 1  # 0.01%: this seed's roll misses
	var before: int = battle.turn_manager.av[wisp]
	battle.resolve_execution(guard, entangle, row, {"primary": wisp, "targets": [wisp] as Array[BattleUnit]})
	eq(battle.turn_manager.av[wisp], before, "a missed status doesn't delay")
	check(not wisp.asc.has_tag_exact(&"Status.Debuff.Entangle"), "and isn't applied")
	entangle.free()


func test_one_more_while_controlled() -> void:
	var battle := new_battle(status_snapshot())
	var guard := battle.unit_by_id(&"P2")
	var imp := battle.unit_by_id(&"E3")
	await battle._activate(guard, ability(guard, "IceSlash"), imp)
	eq(ids(battle.one_more_queue), ["P2"], "the break owes the guard a One More")
	apply(imp, guard, "st_freeze")
	var controller := ScriptedController.new()
	await battle._extra_action(battle.one_more_queue.pop_front(), controller)
	eq(controller.entries.size(), 1, "a One More is not a turn: a frozen unit still takes it")
	eq(controller.entries[0].get("extra"), true, "logged as the extra action")
	check(guard.asc.has_tag_exact(&"State.Controlled"), "the freeze waits for the guard's next real turn")


func test_dot_kills_last_enemy() -> void:
	var battle := new_battle(status_snapshot(["guard"], "knight_one"))
	var guard := battle.unit_by_id(&"P1")
	var knight := battle.unit_by_id(&"E1")
	apply(guard, knight, "st_poison")
	apply(guard, knight, "st_poison")
	knight.asc.initialize_attribute_overrides({"hp": 3000.0, "spd": 100000.0})
	var killed := listen(guard)
	var controller := ScriptedController.new()
	await battle.run(controller)
	eq(battle.outcome, Battle.VICTORY, "the knight's poison tick at its first turn start ends the battle")
	eq(battle.turn, 1, "before any action")
	eq(controller.entries, [], "nothing logged")
	eq(names(killed, "Event.Unit.Killed"), ["Event.Unit.Killed"], "the poisoner is credited with the kill")


func test_ult_cleanse_before_tick() -> void:
	var battle := new_battle(status_snapshot())
	var hexer := battle.unit_by_id(&"P1")
	apply(battle.unit_by_id(&"E2"), hexer, "st_poison")
	hexer.asc.initialize_attribute_overrides({"energy": 10000.0})
	var controller := ScriptedController.new()
	await battle._ult_window(controller)  # P1 (odd slot) casts its ready ult at the BETWEEN window
	eq(controller.entries.size(), 1, "the purify ult fired between actions")
	var hp := hexer.stat("hp")
	hexer.asc.turn_start()
	eq(hexer.stat("hp"), hp, "the poison was cleansed before it could tick")


func test_break_effect_per_type() -> void:
	var battle := new_battle(status_snapshot())
	var guard := battle.unit_by_id(&"P2")
	var imp := battle.unit_by_id(&"E3")
	var dealt := listen(guard)
	var fired := []
	battle.trigger_activated.connect(func(unit_id, tag, event): fired.append([unit_id, tag, event]))
	await battle._activate(guard, ability(guard, "IceSlash"), imp)
	await battle._drain_triggers()
	check(names(dealt, "Event.Damage.Dealt.Break").has("Event.Damage.Dealt.Break.Ice"), "an Ice break sends Break.Ice")
	check(not names(dealt, "Event.Damage.Dealt.Break").has("Event.Damage.Dealt.Break.Fire"), "and no other type")
	eq(fired.filter(func(f): return f[1] == &"Fixture.Ability.BreakIce"), [[&"P2", &"Fixture.Ability.BreakIce",
		&"Event.Damage.Dealt.Break.Ice"]], "the breaker's Ice break passive fires")
	eq(fired.filter(func(f): return f[1] == &"Fixture.Ability.BreakFire"), [], "the Fire one doesn't")


func test_ability_used_type_events() -> void:
	var battle := new_battle(status_snapshot(["breaker"], "status_trial", "3", {1: ["overcharge_coil"]}))
	var breaker := battle.unit_by_id(&"P1")
	breaker.asc.initialize_attribute_overrides({"energy": 10000.0})
	var heard := listen(breaker)
	await battle._activate(breaker, ability(breaker, "Strike"), battle.unit_by_id(&"E1"))
	eq(names(heard, "Event.Ability.Used"), ["Event.Ability.Used"], "a plain action sends no typed event")
	heard.clear()
	await battle._interrupt(breaker, {"ability": &"Fixture.Ability.UltBreakout", "target": &""}, ScriptedController.new())
	eq(names(heard, "Event.Ability.Used") + names(heard, "Event.Battle"), ["Event.Ability.Used",
		"Event.Ability.Used.Ultimate", "Event.Battle.Interrupt"], "an out-of-turn ult: Used, Used.Ultimate, then Interrupt")
	eq(breaker.stat("energy"), 3000, "Overcharge refunded 20 and Interrupter added 10 after the ult emptied the bar")


func test_death_drops_statuses_revive_clean() -> void:
	var battle := new_battle(status_snapshot())
	var guard := battle.unit_by_id(&"P2")
	var toad := battle.unit_by_id(&"E2")
	apply(toad, guard, "st_poison")
	apply(toad, guard, "st_freeze")
	apply(toad, guard, "doom")
	battle._check_deaths()
	check(not guard.alive, "dead")
	check(not guard.asc.has_tag(&"Status.Debuff") and not guard.asc.has_tag_exact(&"State.Controlled"), "statuses dropped at death")
	apply(battle.unit_by_id(&"P1"), guard, "revive")
	battle._check_revives()
	check(guard.alive, "revived")
	check(not guard.asc.has_tag(&"Status.Debuff"), "comes back with none")
