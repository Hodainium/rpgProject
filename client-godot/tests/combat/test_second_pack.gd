## Spec second-pack 2.1: the kernel hooks B1 (HP cost events), B2 (heal events), B3 (meters), B5 (HP threshold states), B6
## (Bleed on hit) and B7 (lifesteal), on fixtures only: the blood mage and the leecher (FixtureBloodAttributeSet) against the
## two keepers of the SP trial, with the fixture battle rules.
extends TestCase

const Statuses := preload("res://tests/combat/test_statuses.gd")


## bloodmage (P1) and leecher (P2), or the bleeder in slot 2 (lifesteal, Bleed chance and tracked low-HP states from a
## battle-start passive), against the SP trial (E1, E2 keepers).
static func blood_snapshot(second: String, name: String, seed_text: String) -> Dictionary:
	var snap: Dictionary = Statuses.status_snapshot(["bloodmage", second], "sp_trial", seed_text)
	snap["battleId"] = "%s-seed-%s" % [name, seed_text]
	return snap


# --- The goldens (test_golden) -------------------------------------------------------------------------------------------

## B1, B2, B3: HP costs fill the Blood Pool, the Pool fires its heal, heal events.
static func meter_golden() -> Dictionary:
	return blood_snapshot("leecher", "meter", "31")


## B5, B6, B7: low-HP states on the leecher's line, Bleed on hit and lifesteal.
static func bleed_golden() -> Dictionary:
	return blood_snapshot("bleeder", "bleed", "37")


## B1 with the step-3 hooks: the blood mage's HP costs beside the binder (RANDOM rows, LOWEST_ALLY, a One More, a subject query).
static func hpcost_golden() -> Dictionary:
	var snap: Dictionary = Statuses.status_snapshot(["bloodmage", "binder"], "sp_trial", "41")
	snap["battleId"] = "hpcost-seed-41"
	return snap


## B5: the bleeder's tracked low-HP states crossing the lines (and back after its lifesteal). It starts at 600 of 1100 HP, just
## above the 50% line, so the first hits cross it (hp right after level: the PartyMemberSnapshot field order).
static func health_golden() -> Dictionary:
	var snap := blood_snapshot("bleeder", "health", "43")
	var party: Array = []
	for member in snap["party"]:
		var copy := {"slot": member["slot"], "unitDefId": member["unitDefId"], "level": member["level"]}
		if member["unitDefId"] == "fixture.character.bleeder":
			copy["hp"] = 60000
		for key in ["skills", "equipmentIds", "items", "useSlots"]:
			copy[key] = member[key]
		party.append(copy)
	snap["party"] = party
	return snap


## Focus and Silvered on the sharpshot (fixture passives on Event.Damage.Dealt and Event.Damage.Dealt.Critical).
static func crit_golden() -> Dictionary:
	var snap: Dictionary = Statuses.status_snapshot(["sharpshot", "leecher"], "sp_trial", "47")
	snap["battleId"] = "crit-seed-47"
	return snap


func _started(snap: Dictionary) -> Battle:
	var battle := new_battle(snap)
	battle._started = true  # the hooks announce only inside a running battle
	return battle


## Takes exactly `amount` (×100) HP off `unit` as `source` (an instant effect built here: no defence, no roll).
static func _hurt(source: BattleUnit, unit: BattleUnit, amount: int) -> void:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INSTANT
	var modifier := GameplayEffectModifier.new()
	modifier.attribute_name = BattleUnit.HP
	modifier.magnitude_calculation = GameplayEffectModifier.MagnitudeCalculationType.SET_BY_CALLER
	modifier.set_by_caller_tag = ExecutionRow.EVENT_AMOUNT_TAG
	effect.modifiers.append(modifier)
	var spec := GameplayEffectSpec.new(effect, GameplayEffectContext.new(source, source), 1)
	spec.set_set_by_caller_magnitude(ExecutionRow.EVENT_AMOUNT_TAG, float(-amount))
	source.asc.apply_effect_spec_to_target(spec, unit.asc)


func _use(battle: Battle, unit_id: String, name: String, target_id: String = "") -> bool:
	var unit := battle.unit_by_id(StringName(unit_id))
	return await battle._activate(unit, Statuses.ability(unit, name),
		battle.unit_by_id(StringName(target_id)) if target_id != "" else null)


# --- B1 HP costs --------------------------------------------------------------------------------------------------------

func test_an_hp_cost_lowers_hp_and_is_announced() -> void:
	var battle := _started(blood_snapshot("leecher", "cost", "3"))
	var mage := battle.unit_by_id(&"P1")
	var heard := Statuses.listen(mage)
	var ally := Statuses.listen(battle.unit_by_id(&"P2"))
	var lance := Statuses.ability(mage, "BpLance")
	eq(CostReader.cost_of(lance, mage.asc), {"hp": 15000}, "CostReader reports the HP cost")
	await _use(battle, "P1", "BpLance", "E1")
	eq(mage.stat(BattleUnit.HP), 100000 - 15000, "paid")
	eq(Statuses.names(heard, "Event.Cost"), ["Event.Cost.Hp"], "to the caster")
	eq(heard.filter(func(e): return e[0] == "Event.Cost.Hp")[0][1]["amount"], 15000, "with the amount paid")
	eq(Statuses.names(ally, "Event.Ally.Cost"), ["Event.Ally.Cost.Hp"], "and its ally")
	eq(Statuses.names(heard, "Event.Damage.Taken"), [], "an HP cost is never damage taken")


func test_an_hp_cost_never_takes_the_last_hp() -> void:
	var battle := _started(blood_snapshot("leecher", "cost", "3"))
	var mage := battle.unit_by_id(&"P1")
	_hurt(battle.unit_by_id(&"E1"), mage, 100000 - 15000)
	eq(mage.stat(BattleUnit.HP), 15000, "left with exactly the cost")
	check(not mage.asc.can_activate_ability(Statuses.ability(mage, "BpLance")), "a cost at the caster's HP is refused")
	Statuses.apply(battle.unit_by_id(&"E1"), mage, "heal")
	check(mage.asc.can_activate_ability(Statuses.ability(mage, "BpLance")), "above it, it is allowed again")


# --- B2 heal events ---------------------------------------------------------------------------------------------------------

func test_a_heal_is_announced_without_overheal() -> void:
	var battle := _started(blood_snapshot("leecher", "heal", "3"))
	var mage := battle.unit_by_id(&"P1")
	var leecher := battle.unit_by_id(&"P2")
	_hurt(battle.unit_by_id(&"E1"), leecher, 5000)
	var given := Statuses.listen(mage)
	var received := Statuses.listen(leecher)
	Statuses.apply(mage, leecher, "heal")
	var payload: Dictionary = received.filter(func(e): return e[0] == "Event.Heal.Received")[0][1]
	eq(payload["amount"], 5000, "the HP restored, never past max HP")
	eq([payload["source"], payload["target"]], [mage, leecher], "source and target")
	eq(Statuses.names(given, "Event.Heal.Given"), ["Event.Heal.Given"], "the healer hears it")
	eq(Statuses.names(given, "Event.Ally.Heal.Received"), ["Event.Ally.Heal.Received"], "and so does the healed one's ally")
	received.clear()
	Statuses.apply(mage, leecher, "heal")
	eq(Statuses.names(received, "Event.Heal"), [], "a heal at full HP restores nothing and says nothing")


func test_no_heal_event_before_the_battle_starts() -> void:
	var battle := new_battle(blood_snapshot("leecher", "heal", "3"))
	var leecher := battle.unit_by_id(&"P2")
	_hurt(battle.unit_by_id(&"E1"), leecher, 5000)
	var received := Statuses.listen(leecher)
	Statuses.apply(battle.unit_by_id(&"P1"), leecher, "heal")
	eq(Statuses.names(received, "Event.Heal"), [], "setup and carry-over changes are no heals")


# --- B3 meters ----------------------------------------------------------------------------------------------------------

func test_the_pool_fills_from_hits_and_costs_and_fires_once_full() -> void:
	var battle := _started(blood_snapshot("leecher", "meter", "3"))
	var mage := battle.unit_by_id(&"P1")
	var leecher := battle.unit_by_id(&"P2")
	var fired := []
	battle.trigger_activated.connect(func(unit_id, tag, event): fired.append("%s %s %s" % [unit_id, String(tag).trim_prefix("Fixture.Ability."), event]))
	await _use(battle, "P1", "BpLance", "E1")  # the cost: 150 into the Pool
	await battle._drain_triggers()
	eq(mage.stat("meter"), 15000, "the HP cost filled the Pool")
	_hurt(battle.unit_by_id(&"E1"), leecher, 10000)  # an ally hit: 100 more
	battle.resolve_execution(battle.unit_by_id(&"E1"), Statuses.ability(battle.unit_by_id(&"E1"), "Claw"),
		Statuses.ability(battle.unit_by_id(&"E1"), "Claw").executions[0],
		{"primary": leecher, "targets": [leecher] as Array[BattleUnit]})
	await battle._drain_triggers()
	check(fired.has("P1 BpSurge Event.Meter.Full"), "the Pool fired at 30%% of max HP (300): %s" % [fired])
	check(mage.stat("meter") < 30000, "and the threshold came off: %d" % mage.stat("meter"))


func test_a_meter_fires_at_most_three_times_per_check() -> void:
	var battle := _started(blood_snapshot("leecher", "meter", "3"))
	var mage := battle.unit_by_id(&"P1")
	var fill := GameplayEffectSpec.new(load(Statuses.EFFECTS + "bp_meter_fill.tres"), GameplayEffectContext.new(mage, mage), 1)
	fill.set_set_by_caller_magnitude(ExecutionRow.EVENT_AMOUNT_TAG, 30000.0 * 5)
	mage.asc.apply_effect_spec(fill)
	var surges := []
	battle.trigger_activated.connect(func(unit_id, tag, _event): if String(tag).ends_with("BpSurge"): surges.append(unit_id))
	check(battle._queue_meters(), "five thresholds' worth queues")
	await battle._drain_queue()
	eq(surges.size(), 3, "three fires per check")
	eq(mage.stat("meter"), 30000 * 2, "two thresholds left for the next check")


func test_a_meter_heal_never_fills_a_meter() -> void:
	var battle := _started(blood_snapshot("leecher", "meter", "3"))
	var leecher := battle.unit_by_id(&"P2")
	_hurt(battle.unit_by_id(&"E1"), leecher, 5000)
	var received := Statuses.listen(leecher)
	var given := Statuses.listen(battle.unit_by_id(&"P1"))
	Statuses.apply(battle.unit_by_id(&"P1"), leecher, "heal", 0, [Battle.HIT_METER])
	eq(Statuses.names(received, "Event.Heal"), [], "a Hit.Meter heal sends no Received event")
	eq(Statuses.names(given, "Event.Heal"), [], "nor the healer's Given: a meter heal sends nothing")


func test_the_meter_starts_at_zero_and_is_never_carried() -> void:
	var snap := blood_snapshot("leecher", "meter", "3")
	snap["party"][0]["meter"] = 99999  # an unknown field: never read
	var battle := new_battle(blood_snapshot("leecher", "meter", "3"))
	eq(battle.unit_by_id(&"P1").stat("meter"), 0, "every battle starts with an empty meter")


# --- B5 HP threshold states ------------------------------------------------------------------------------------------------

func test_states_follow_hp_and_announce_each_crossing_once() -> void:
	var battle := _started(blood_snapshot("leecher", "health", "3"))
	var mage := battle.unit_by_id(&"P1")
	var heard := Statuses.listen(mage)
	var ally := Statuses.listen(battle.unit_by_id(&"P2"))
	_hurt(battle.unit_by_id(&"E1"), mage, 60000)  # 1000 -> 400: under 50%
	check(mage.asc.has_tag_exact(Battle.HEALTH_LOW_TAG), "low")
	check(not mage.asc.has_tag_exact(Battle.HEALTH_CRITICAL_TAG), "not critical")
	_hurt(battle.unit_by_id(&"E1"), mage, 5000)  # still low: no second event
	_hurt(battle.unit_by_id(&"E1"), mage, 20000)  # 150: under 25%
	check(mage.asc.has_tag_exact(Battle.HEALTH_CRITICAL_TAG), "critical")
	eq(Statuses.names(heard, "Event.Health"), ["Event.Health.Low", "Event.Health.Critical"], "one event per crossing")
	eq(Statuses.names(ally, "Event.Ally.Health"), ["Event.Ally.Health.Low"], "and the ally hears the low one")
	_hurt(mage, mage, -80000)  # an exact heal back to 950
	check(not mage.asc.has_tag_exact(Battle.HEALTH_LOW_TAG), "healed above the line: no longer low")
	check(not mage.asc.has_tag_exact(Battle.HEALTH_CRITICAL_TAG), "nor critical")


func test_an_untracked_unit_never_carries_the_states() -> void:
	var battle := _started(blood_snapshot("leecher", "health", "3"))
	var leecher := battle.unit_by_id(&"P2")
	_hurt(battle.unit_by_id(&"E1"), leecher, 100000)
	check(not leecher.asc.has_tag_exact(Battle.HEALTH_LOW_TAG), "no tag without health_states or State.Health.Tracked")


func test_an_item_tracks_its_holder_and_moves_the_line() -> void:
	var battle := _started(blood_snapshot("leecher", "health", "3"))
	var leecher := battle.unit_by_id(&"P2")
	Statuses.apply(leecher, leecher, "bp_tracked")  # what a low-HP item grants its holder
	Statuses.apply(leecher, leecher, "bp_low_line")
	_hurt(battle.unit_by_id(&"E1"), leecher, 50000)  # 1100 -> 600: 54.5%, under the 60% line
	check(leecher.asc.has_tag_exact(Battle.HEALTH_LOW_TAG), "tracked by its item, and low under 60%")


# --- B6 Bleed on hit, B7 lifesteal --------------------------------------------------------------------------------------

func test_lifesteal_heals_a_share_of_each_hit() -> void:
	var battle := _started(blood_snapshot("leecher", "leech", "3"))
	var leecher := battle.unit_by_id(&"P2")
	Statuses.apply(leecher, leecher, "bp_lifesteal_stat")
	_hurt(battle.unit_by_id(&"E1"), leecher, 40000)
	var before := leecher.stat(BattleUnit.HP)
	var keeper := battle.unit_by_id(&"E1")
	var keeper_before := keeper.stat(BattleUnit.HP)
	await _use(battle, "P2", "ChantJab", "E1")
	var dealt := keeper_before - keeper.stat(BattleUnit.HP)
	eq(leecher.stat(BattleUnit.HP) - before, Fixed.pct(dealt, 5000), "50% of the damage dealt")


func test_no_lifesteal_or_bleed_without_the_stats() -> void:
	var battle := _started(blood_snapshot("leecher", "plain", "3"))
	var twin := _started(blood_snapshot("leecher", "plain", "3"))
	twin.rules = null  # the same battle with the hooks switched off
	var leecher := battle.unit_by_id(&"P2")
	_hurt(battle.unit_by_id(&"E1"), leecher, 40000)
	var before := leecher.stat(BattleUnit.HP)
	await _use(battle, "P2", "ChantJab", "E1")
	await _use(twin, "P2", "ChantJab", "E1")
	eq(leecher.stat(BattleUnit.HP), before, "no heal")
	eq(battle.rng.state, twin.rng.state, "and no extra roll: a unit without Bleed chance draws nothing")
	eq(Statuses.active(battle.unit_by_id(&"E1"), "bp_bleed"), null, "and no Bleed")


func test_bleed_rolls_once_per_hit_at_the_summed_chance() -> void:
	var battle := _started(blood_snapshot("leecher", "bleed", "3"))
	var twin := _started(blood_snapshot("leecher", "bleed", "3"))
	twin.rules = null
	for each in [battle, twin]:
		for item in 2:  # 50% + 50%: always lands, no roll
			Statuses.apply(each.unit_by_id(&"P2"), each.unit_by_id(&"P2"), "bp_bleed_stat")
	await _use(battle, "P2", "ChantJab", "E1")
	await _use(twin, "P2", "ChantJab", "E1")
	eq(battle.rng.state, twin.rng.state, "100% Bleed chance draws nothing extra")
	var bleed := Statuses.active(battle.unit_by_id(&"E1"), "bp_bleed")
	check(bleed != null, "a Bleed stack on the target")
	eq(bleed.spec.context.instigator, battle.unit_by_id(&"P2"), "as the hitter's own DoT")


func test_a_dot_tick_never_bleeds_or_heals() -> void:
	var battle := _started(blood_snapshot("leecher", "bleed", "3"))
	var leecher := battle.unit_by_id(&"P2")
	for effect in ["bp_bleed_stat", "bp_bleed_stat", "bp_lifesteal_stat"]:
		Statuses.apply(leecher, leecher, effect)
	var keeper := battle.unit_by_id(&"E1")
	_hurt(battle.unit_by_id(&"E1"), leecher, 40000)
	Statuses.apply(leecher, keeper, "bp_bleed")
	var hp := leecher.stat(BattleUnit.HP)
	keeper.asc.turn_start()
	eq(leecher.stat(BattleUnit.HP), hp, "a tick heals nobody")
	eq(Statuses.active(keeper, "bp_bleed").stack_count, 1, "and adds no stack")


# --- Review fixes (2026-11-26) ---------------------------------------------------------------------------------------------

func _fill_meter(unit: BattleUnit, amount: int) -> void:
	var fill := GameplayEffectSpec.new(load(Statuses.EFFECTS + "bp_meter_fill.tres"), GameplayEffectContext.new(unit, unit), 1)
	fill.set_set_by_caller_magnitude(ExecutionRow.EVENT_AMOUNT_TAG, float(amount))
	unit.asc.apply_effect_spec(fill)


func test_a_meter_that_cannot_fire_keeps_its_charge() -> void:
	var battle := _started(blood_snapshot("leecher", "meter", "3"))
	var mage := battle.unit_by_id(&"P1")
	_fill_meter(mage, 30000)
	var surge := Statuses.ability(mage, "BpSurge")
	surge.activation_query = GameplayTagQuery.new()
	surge.activation_query.ignore_tags.assign([&"State.Controlled"])
	mage.asc.add_tag(&"State.Controlled")
	check(not battle._queue_meters(), "a meter ability that cannot activate is not queued")
	eq(mage.stat("meter"), 30000, "and keeps its charge")
	mage.asc.clear_tag(&"State.Controlled")
	check(battle._queue_meters(), "free again, it queues")
	eq(mage.stat("meter"), 30000, "queueing takes nothing off")
	battle.triggers.clear()  # dropped (e.g. by the chain cap): nothing was spent
	eq(mage.stat("meter"), 30000, "a dropped entry costs nothing")


func test_a_killing_blow_announces_no_crossing() -> void:
	var battle := _started(blood_snapshot("leecher", "health", "3"))
	var mage := battle.unit_by_id(&"P1")
	var heard := Statuses.listen(mage)
	var ally := Statuses.listen(battle.unit_by_id(&"P2"))
	_hurt(battle.unit_by_id(&"E1"), mage, 100000)
	eq(Statuses.names(heard, "Event.Health"), [], "no Low or Critical for a unit at 0 HP")
	eq(Statuses.names(ally, "Event.Ally.Health"), [], "nor to its allies")


func test_tracking_from_battle_start_sets_the_state_at_once() -> void:
	var battle := _started(blood_snapshot("leecher", "health", "3"))
	var leecher := battle.unit_by_id(&"P2")
	_hurt(battle.unit_by_id(&"E1"), leecher, 70000)  # untracked: no tag yet
	check(not leecher.asc.has_tag_exact(Battle.HEALTH_LOW_TAG), "untracked")
	var heard := Statuses.listen(leecher)
	Statuses.apply(leecher, leecher, "bp_tracked")
	check(leecher.asc.has_tag_exact(Battle.HEALTH_LOW_TAG), "the Tracked tag arriving sets the state")
	eq(Statuses.names(heard, "Event.Health"), [], "unannounced, like a starting state")


func test_a_drained_hit_is_no_heal() -> void:
	var battle := _started(blood_snapshot("leecher", "heal", "3"))
	var keeper := battle.unit_by_id(&"E1")
	_hurt(battle.unit_by_id(&"P1"), keeper, 10000)
	var given := Statuses.listen(battle.unit_by_id(&"P1"))
	var received := Statuses.listen(keeper)
	Statuses.apply(battle.unit_by_id(&"P1"), keeper, "heal", 0, [Battle.HIT_DRAINED])
	eq(Statuses.names(given, "Event.Heal"), [], "the attacker heals nobody")
	eq(Statuses.names(received, "Event.Heal"), [], "and the drainer receives no heal event")


func test_a_meter_hits_lifesteal_is_a_meter_heal() -> void:
	var battle := _started(blood_snapshot("leecher", "leech", "3"))
	var leecher := battle.unit_by_id(&"P2")
	Statuses.apply(leecher, leecher, "bp_lifesteal_stat")
	_hurt(battle.unit_by_id(&"E1"), leecher, 40000)
	var heard := Statuses.listen(leecher)
	var before := leecher.stat(BattleUnit.HP)
	battle._after_hit(leecher, battle.unit_by_id(&"E1"), 10000, true)
	eq(leecher.stat(BattleUnit.HP) - before, 5000, "it still heals")
	eq(Statuses.names(heard, "Event.Heal"), [], "but sends no heal event")


func test_meters_never_fire_in_field_mode() -> void:
	var battle := Battle.new()
	host.add_child(battle)
	check(battle.setup_field(blood_snapshot("leecher", "field", "3"), fixtures()) == "", "field setup")
	var mage := battle.unit_by_id(&"P1")
	_fill_meter(mage, 30000)
	check(not battle._queue_meters(), "no meter in the field")
	battle.queue_free()


# --- Step 3: the item hooks (the binder, FixtureBlood2AttributeSet) -----------------------------------------------------

func _binder() -> Battle:
	var snap: Dictionary = Statuses.status_snapshot(["binder", "leecher"], "sp_trial", "41")
	snap["battleId"] = "binder-seed-41"
	return _started(snap)


static func _override(unit: BattleUnit, values: Dictionary) -> void:
	var typed: Dictionary[String, float] = {}
	for key in values:
		typed[key] = float(values[key])
	unit.asc.initialize_attribute_overrides(typed)


func _rows_hit(battle: Battle) -> Array:
	var hits := []
	battle.execution_resolved.connect(func(unit_id, row_id, ids): hits.append([String(unit_id), String(row_id), Array(ids)]))
	return hits


func test_a_random_row_draws_one_target_that_is_up_per_row() -> void:
	var battle := _binder()
	var hits := _rows_hit(battle)
	await _use(battle, "P1", "Bp2Flurry")
	var flurry := hits.filter(func(hit): return hit[0] == "P1" and String(hit[1]).begins_with("c"))
	eq(flurry.size(), 3, "three rows")
	check(flurry.all(func(hit): return hit[2].size() == 1), "each hits exactly one enemy: %s" % [flurry])
	hits.clear()
	_override(battle.unit_by_id(&"E2"), {"hp": 0})
	await _use(battle, "P1", "Bp2Flurry")
	flurry = hits.filter(func(hit): return hit[0] == "P1" and String(hit[1]).begins_with("c"))
	check(flurry.all(func(hit): return hit[2] == [&"E1"]), "never a unit at 0 HP: %s" % [flurry])


func test_a_follow_up_on_an_action_hits_what_the_action_aimed_at() -> void:
	var battle := _binder()
	var hits := _rows_hit(battle)
	await _use(battle, "P1", "ChantJab", "E2")
	await battle._drain_triggers()
	var claw := hits.filter(func(hit): return hit[1] == "claw")
	eq(claw.size(), 1, "the claw fires once: %s" % [hits])
	if claw.size() == 1:
		eq(claw[0][2], [&"E2"], "on the basic's target, not the first enemy")


func test_lowest_ally_picks_the_most_hurt_living_ally() -> void:
	var battle := _binder()
	var hurt := battle.unit_by_id(&"P2")
	_override(hurt, {"hp": hurt.stat(BattleUnit.MAX_HP) * 3 / 10})
	var before := hurt.stat(BattleUnit.HP)
	await _use(battle, "P1", "ChantJab", "E1")
	await battle._drain_triggers()
	check(hurt.stat(BattleUnit.HP) > before, "the heal went to the leecher at 30%")
	eq(Battle._hp_share(battle.unit_by_id(&"P1")), 10000, "the binder itself stayed full")


func test_a_subject_query_fires_only_on_a_matching_target() -> void:
	var battle := _binder()
	var fired := []
	battle.trigger_activated.connect(func(unit_id, tag, _event): fired.append(String(tag)))
	await _use(battle, "P1", "ChantJab", "E1")
	await battle._drain_triggers()
	check(not fired.has("Fixture.Ability.Bp2Finisher"), "no Bleed on the target: no finisher: %s" % [fired])
	var bleed: GameplayEffect = load("res://tests/fixtures/effects/bp_bleed.tres")
	battle.unit_by_id(&"E1").asc.apply_gameplay_effect(bleed, battle.unit_by_id(&"P1").asc)
	fired.clear()
	await _use(battle, "P1", "ChantJab", "E1")
	await battle._drain_triggers()
	check(fired.has("Fixture.Ability.Bp2Finisher"), "a Bleeding target: the finisher fires: %s" % [fired])


func test_an_effect_granting_one_more_queues_its_unit_once() -> void:
	var battle := _binder()
	var binder := battle.unit_by_id(&"P1")
	var grant: GameplayEffect = load("res://tests/fixtures/effects/bp2_one_more.tres")
	binder.asc.apply_gameplay_effect(grant, binder.asc)
	eq(battle.one_more_queue, [binder], "queued for a One More")
	binder.asc.apply_gameplay_effect(grant, binder.asc)
	eq(battle.one_more_queue.size(), 1, "never twice")


func test_bleed_stacks_are_capped_by_the_rules_plus_the_source() -> void:
	var battle := _binder()
	battle.rules = battle.rules.duplicate()
	battle.rules.bleed_stacks = 2
	var binder := battle.unit_by_id(&"P1")
	var enemy := battle.unit_by_id(&"E1")
	_override(binder, {"bleed_chance": 10000})
	for _i in 4:
		battle._after_hit(binder, enemy, 100)
	eq(_bleeds(enemy), 2, "the rules' cap")
	_override(binder, {"bleed_stacks": 100})
	battle._after_hit(binder, enemy, 100)
	battle._after_hit(binder, enemy, 100)
	eq(_bleeds(enemy), 3, "one more stack from the source's bleed_stacks")


func test_bleed_turns_lengthen_only_bleed() -> void:
	var battle := _binder()
	var binder := battle.unit_by_id(&"P1")
	_override(binder, {"bleed_turns": 100, "bleed_chance": 10000})
	var enemy := battle.unit_by_id(&"E1")
	battle._after_hit(binder, enemy, 100)
	var turns := -1
	for status in enemy.statuses():
		if status["tag"] == "Status.Debuff.Bleed":
			turns = int(status["turns"])
	eq(turns, 3, "2 turns + 1")


func test_bleed_lifesteal_heals_only_on_bleeding_targets() -> void:
	var battle := _binder()
	var binder := battle.unit_by_id(&"P1")
	_override(binder, {"bleed_lifesteal": 5000, "hp": 50000})
	battle._after_hit(binder, battle.unit_by_id(&"E1"), 10000)
	eq(binder.stat(BattleUnit.HP), 50000, "no Bleed on the target: no heal")
	var bleed: GameplayEffect = load("res://tests/fixtures/effects/bp_bleed.tres")
	battle.unit_by_id(&"E1").asc.apply_gameplay_effect(bleed, binder.asc)
	battle._after_hit(binder, battle.unit_by_id(&"E1"), 10000)
	eq(binder.stat(BattleUnit.HP), 55000, "half the damage back from a Bleeding target")


func test_lifesteal_past_full_hp_becomes_a_capped_shield() -> void:
	var battle := _binder()
	battle.rules = battle.rules.duplicate()
	var into_shield := GameplayEffect.new()
	into_shield.policy = GameplayEffect.DurationPolicy.INSTANT
	var modifier := GameplayEffectModifier.new()
	modifier.attribute_name = "shield"
	modifier.magnitude_calculation = GameplayEffectModifier.MagnitudeCalculationType.SET_BY_CALLER
	modifier.set_by_caller_tag = ExecutionRow.EVENT_AMOUNT_TAG
	into_shield.modifiers.append(modifier)
	battle.rules.overheal_effect = into_shield
	var binder := battle.unit_by_id(&"P1")
	_override(binder, {"lifesteal": 5000, "overheal_shield": 1000})
	battle._after_hit(binder, battle.unit_by_id(&"E1"), 8000)
	eq(binder.stat("shield"), 4000, "full HP: the whole 40 HP heal becomes shield")
	battle._after_hit(binder, battle.unit_by_id(&"E1"), 80000)
	eq(binder.stat("shield"), 10000, "capped at 10% of max HP")


static func _bleeds(unit: BattleUnit) -> int:
	var held := 0
	for status in unit.statuses():
		if status["tag"] == "Status.Debuff.Bleed":
			held += int(status["stacks"])
	return held


# --- Review fixes ----------------------------------------------------------------------------------------------------------

## A full meter whose ability is turned down (here a 0.01% trigger chance) rolls once per drain, not once per round up to the
## chain cap; it keeps its charge and tries again at the next drain.
func test_a_refused_meter_rolls_once_per_drain() -> void:
	var battle := _started(blood_snapshot("leecher", "meter", "3"))
	var mage := battle.unit_by_id(&"P1")
	var surge := Statuses.ability(mage, "BpSurge")
	surge.trigger_chance_x100 = 1
	_fill_meter(mage, 30000)
	var state_before := battle.rng.state
	await battle._drain_triggers()
	eq(battle.chain_cap_hits, 0, "no meter chain against the cap")
	eq(mage.stat("meter"), 30000, "the meter keeps its charge")
	var probe := RandomNumberGenerator.new()
	probe.state = state_before
	probe.randi_range(0, 9999)
	eq(battle.rng.state, probe.state, "exactly one roll in the drain")
	await battle._drain_triggers()
	probe.randi_range(0, 9999)
	eq(battle.rng.state, probe.state, "and one more at the next drain")


## Meters wait while a death-save window is open (_settle_deaths drains with _dying set), and fire at the outer drain.
func test_meters_wait_out_a_death_save_window() -> void:
	var battle := _started(blood_snapshot("leecher", "meter", "3"))
	var mage := battle.unit_by_id(&"P1")
	var surges := []
	battle.trigger_activated.connect(func(_id, tag, _event): if String(tag).ends_with("BpSurge"): surges.append(tag))
	_fill_meter(mage, 30000)
	battle._dying.append(battle.unit_by_id(&"P2"))
	await battle._drain_triggers()
	eq(surges.size(), 0, "nothing fires inside the window")
	battle._dying.clear()
	await battle._drain_triggers()
	eq(surges.size(), 1, "it fires once the window is closed")


class HalfHeal:
	extends GameplayExecutionCalculation

	func amount_for(amount: int, _source: AbilitySystemComponent, _target: AbilitySystemComponent) -> int:
		return amount / 2

	func execute(spec: GameplayEffectSpec, _target: AbilitySystemComponent) -> Dictionary:
		return {"hp": float(amount_for(int(spec.get_set_by_caller_magnitude(ExecutionRow.EVENT_AMOUNT_TAG)), null, null))}


## The overheal shield counts what the lifesteal heal really restores (its calc's amount_for: heal_taken in content).
func test_overheal_counts_what_the_heal_restores() -> void:
	var battle := _binder()
	battle.rules = battle.rules.duplicate()
	var into_shield := GameplayEffect.new()
	into_shield.policy = GameplayEffect.DurationPolicy.INSTANT
	var shield := GameplayEffectModifier.new()
	shield.attribute_name = "shield"
	shield.magnitude_calculation = GameplayEffectModifier.MagnitudeCalculationType.SET_BY_CALLER
	shield.set_by_caller_tag = ExecutionRow.EVENT_AMOUNT_TAG
	into_shield.modifiers.append(shield)
	battle.rules.overheal_effect = into_shield
	var halved := GameplayEffect.new()
	halved.policy = GameplayEffect.DurationPolicy.INSTANT
	halved.executions.append(HalfHeal.new())
	battle.rules.lifesteal_effect = halved
	var binder := battle.unit_by_id(&"P1")
	_override(binder, {"lifesteal": 5000, "overheal_shield": 10000})
	_override(binder, {"hp": binder.stat(BattleUnit.MAX_HP) - 3000})
	battle._after_hit(binder, battle.unit_by_id(&"E1"), 8000)  # 40 HP of lifesteal, 20 restored: still 10 short
	eq(binder.stat("shield"), 0, "a heal that does not reach full HP makes no shield")
	_override(binder, {"hp": binder.stat(BattleUnit.MAX_HP) - 3000})
	battle._after_hit(binder, battle.unit_by_id(&"E1"), 16000)  # 80 HP of lifesteal, 40 restored: 10 past full
	eq(binder.stat("shield"), 1000, "only what the heal restores past full becomes shield")


## The battle adds and removes only its own reference to the health-state tags, so another grant of the tag survives.
func test_health_states_leave_another_grant_alone() -> void:
	var battle := _started(blood_snapshot("leecher", "health", "3"))
	var mage := battle.unit_by_id(&"P1")
	mage.asc.add_tag(Battle.HEALTH_LOW_TAG)  # another source (an effect) grants the tag
	_hurt(battle.unit_by_id(&"E1"), mage, 1000)  # still above 50%: the battle's own state is off
	check(mage.asc.has_tag_exact(Battle.HEALTH_LOW_TAG), "the other grant is kept")
	_hurt(battle.unit_by_id(&"E1"), mage, 60000)  # under 50%: the battle's own reference on top
	check(battle._health_granted.size() > 0, "the battle holds its own reference while under the line")
	_override(mage, {"hp": mage.stat(BattleUnit.MAX_HP)})
	eq(battle._health_granted.size(), 0, "back above the line: the battle let its own reference go")
	check(mage.asc.has_tag_exact(Battle.HEALTH_LOW_TAG), "healed above the line: only the battle's own reference goes")


## Review fix: a Bleed refused at the stack cap still refreshes the stacks it would have joined (no stack added).
func test_bleed_at_the_cap_still_refreshes() -> void:
	var battle := _binder()
	battle.rules = battle.rules.duplicate()
	battle.rules.bleed_stacks = 2
	var binder := battle.unit_by_id(&"P1")
	var enemy := battle.unit_by_id(&"E1")
	_override(binder, {"bleed_chance": 10000})
	battle._after_hit(binder, enemy, 100)
	battle._after_hit(binder, enemy, 100)
	var full := 0
	for active_effect in enemy.asc._active_effects:
		if active_effect.get_effect_def() == battle.rules.bleed_effect:
			full = maxi(full, active_effect.spec.remaining_turns)
			active_effect.spec.remaining_turns = 1  # about to fall off
	battle._after_hit(binder, enemy, 100)
	eq(_bleeds(enemy), 2, "still at the cap")
	for active_effect in enemy.asc._active_effects:
		if active_effect.get_effect_def() == battle.rules.bleed_effect:
			eq(active_effect.spec.remaining_turns, full, "refreshed to a fresh Bleed's turns")


## Review fix (Auto): a RANDOM row lands on one target, so an all-enemies flurry is worth its rows once in total, not once per enemy.
func test_auto_scores_a_random_row_once() -> void:
	var battle := _binder()
	var binder := battle.unit_by_id(&"P1")
	var flurry := Statuses.ability(binder, "Bp2Flurry")
	var enemies := battle.units().filter(func(unit: BattleUnit) -> bool: return not unit.is_party() and unit.is_up())
	var one := AutoPolicy._value_on(binder, flurry, enemies[0], 1)
	eq(AutoPolicy.score_of(battle, binder, flurry, enemies[0]), AutoPolicy._value_on(binder, flurry, enemies[0], enemies.size())
		+ AutoPolicy._value_on(binder, flurry, enemies[1], enemies.size()), "each enemy counts its share")
	check(AutoPolicy.score_of(battle, binder, flurry, enemies[0]) <= one * 11 / 10,
		"the flurry is worth about its rows once, not once per enemy (%d vs one target %d)" % [
			AutoPolicy.score_of(battle, binder, flurry, enemies[0]), one])
