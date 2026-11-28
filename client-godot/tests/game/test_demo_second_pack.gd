## Content test for spec second-pack 2.2 and 2.3 (step 1): Vlad and the Bloodbinder are there, tagged, and their mechanics do what
## their descriptions say: by direction, never by the tuned number. Skipped without the content.
extends TestCase

const DEMO: String = "res://content/demo/"

static var _demo: ContentIndex


static func _content_index() -> ContentIndex:
	if _demo == null:
		_demo = ContentIndex.new("res://content/")
	return _demo


func _ready_to_test() -> bool:
	if ResourceLoader.exists(DEMO + "characters/bloodbinder.tres"):
		return true
	print("    skipped: no second-pack content under ", DEMO)
	return false


## Vlad (P1) and the Bloodbinder (P2) against two slimes made sturdy.
func _battle() -> Battle:
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	var error := battle.setup({"schemaVersion": 2, "battleId": "demo-second-pack", "seed": "5",
		"encounterId": "demo.encounter.slime_pair", "party": [
			{"slot": 1, "unitDefId": "demo.character.vampire", "level": 1, "skills": [], "equipmentIds": [], "items": [], "useSlots": []},
			{"slot": 2, "unitDefId": "demo.character.bloodbinder", "level": 1, "skills": [], "equipmentIds": [], "items": [],
				"useSlots": []}]}, _content_index())
	check(error == "", "demo battle setup: " + error)
	for unit in battle.units():
		if not unit.is_party():
			_set_stat(unit, "max_hp", 1000000)
			_set_stat(unit, "hp", 1000000)
	battle._started = true
	return battle


static func _set_stat(unit: BattleUnit, attribute_name: String, value: int) -> void:
	unit.asc.initialize_attribute_overrides({attribute_name: float(value)} as Dictionary[String, float])


func _act(battle: Battle, actor: StringName, ability: StringName, target: StringName = &"") -> bool:
	var unit := battle.unit_by_id(actor)
	var done: bool = await battle._activate(unit, unit.ability_by_tag(ability), battle.unit_by_id(target) if target != &"" else null)
	await battle._drain_triggers()
	return done


func _start(battle: Battle) -> void:
	for unit in battle.units():
		unit.asc.send_gameplay_event(Battle.EVENT_BATTLE_START, {"source": unit, "target": unit})
	await battle._drain_triggers()


func test_the_two_characters_are_in_the_blood_moon_set_stat() -> void:
	if not _ready_to_test():
		return
	for id in [&"demo.character.vampire", &"demo.character.bloodbinder"]:
		var character: CharacterDefinition = _content_index().characters.get(id)
		check(character != null, "%s exists" % id)
		if character != null:
			check(character.tags.has(&"Card.Set.Bloodmoon"), "%s is a Blood Moon card" % id)
			eq(character.growth_bands.size(), 3, "%s grows in three bands" % id)
	eq((_content_index().characters[&"demo.character.vampire"] as CharacterDefinition).display_name, "Vlad", "shown as Vlad (D23)")


func test_vlad_pays_hp_and_heals_by_hitting() -> void:
	if not _ready_to_test():
		return
	var battle := _battle()
	await _start(battle)
	var vlad := battle.unit_by_id(&"P1")
	eq(vlad.stat("lifesteal"), 2000, "innate 20% lifesteal")
	var lance := vlad.ability_by_tag(&"Ability.Bloodlance")
	eq(CostReader.cost_of(lance, vlad.asc).get("hp", 0), Fixed.pct(vlad.stat(BattleUnit.MAX_HP), 1200), "costs 12% max HP")
	var before := vlad.stat(BattleUnit.HP)
	await _act(battle, &"P1", &"Ability.Bloodlance", &"E1")
	var paid := Fixed.pct(vlad.stat(BattleUnit.MAX_HP), 1200)
	check(vlad.stat(BattleUnit.HP) > before - paid, "the hit's lifesteal gave some of the cost back")
	_set_stat(vlad, "hp", paid)
	check(not vlad.asc.can_activate_ability(lance), "never a cost that would take its last HP")


func test_thirst_hits_harder_when_low() -> void:
	if not _ready_to_test():
		return
	var battle := _battle()
	await _start(battle)
	var vlad := battle.unit_by_id(&"P1")
	check(vlad.stat("missing_hp_dmg") > 0, "Thirst gives a missing-HP damage rate")
	eq(ExecCalcRestore.missing_bonus(vlad.asc, "missing_hp_dmg"), 0, "nothing at full HP")
	_set_stat(vlad, "hp", vlad.stat(BattleUnit.MAX_HP) / 2)
	check(ExecCalcRestore.missing_bonus(vlad.asc, "missing_hp_dmg") > 0, "a bonus at half HP")


func test_the_bloodbinders_ult_casts_itself_when_the_pool_fills() -> void:
	if not _ready_to_test():
		return
	var battle := _battle()
	await _start(battle)
	var binder := battle.unit_by_id(&"P2")
	eq(binder.ultimate_abilities().size(), 0, "no ult to press: it casts itself (D29)")
	var before := binder.stat("energy")
	await _act(battle, &"P1", &"Ability.Bloodlance", &"E1")  # an ally's HP cost fills the Pool
	check(binder.stat("energy") > before, "an ally's HP cost fills the ult bar")
	var fired := []
	battle.trigger_activated.connect(func(unit_id, tag, _event): fired.append("%s %s" % [unit_id, tag]))
	_set_stat(binder, "energy", binder.stat("max_energy"))
	await battle._drain_triggers()
	check(fired.has("P2 Ability.Ult.Crimsoncommunion"), "a full bar casts Crimson Communion: %s" % [fired])
	check(binder.stat("energy") < binder.stat("max_energy"), "and empties the bar")
	eq(battle.unit_by_id(&"P1").stat("lifesteal"), 2000 + 1000, "the party gets its lifesteal")


## Spec second-pack 2.7: Auto never casts an HP-cost move that would leave the caster under the danger line, unless the
## move's lifesteal would bring it back; then it falls back to another move.
func test_auto_refuses_an_hp_cost_it_cannot_survive() -> void:
	if not _ready_to_test():
		return
	var battle := _battle()
	await _start(battle)
	var vlad := battle.unit_by_id(&"P1")
	var lance := vlad.ability_by_tag(&"Ability.Bloodlance")
	var max_hp := vlad.stat(BattleUnit.MAX_HP)
	check(AutoPolicy.hp_cost_survivable(battle, vlad, lance, 2500), "at full HP the cost is fine")
	_set_stat(vlad, "hp", Fixed.pct(max_hp, 1300))
	check(vlad.asc.can_activate_ability(lance), "the cost is still payable")
	check(not AutoPolicy.hp_cost_survivable(battle, vlad, lance, 2500),
		"at 13% HP, 12% leaves 1%, and the hit's lifesteal cannot bring it back to 25%")
	var pick := AutoPolicy.new().choose(battle, vlad)
	check(pick.get("ability", &"") != &"Ability.Bloodlance", "Auto falls back to another move: %s" % [pick])
	_set_stat(vlad, "hp", Fixed.pct(max_hp, 3000))
	check(AutoPolicy.hp_cost_survivable(battle, vlad, lance, 2500),
		"at 30% HP, 12% leaves 18%, and the hit's lifesteal brings it back above 25%")
	check(AutoPolicy.hp_cost_survivable(battle, vlad, lance, 0), "no danger line: any payable cost")


## Spec second-pack 2.7: the Bloodbinder's HP-cost heal goes through Auto's heal choice with its HP as the cost.
func test_auto_heals_with_transfusion_paying_hp() -> void:
	if not _ready_to_test():
		return
	var battle := _battle()
	await _start(battle)
	var binder := battle.unit_by_id(&"P2")
	var transfusion := binder.ability_by_tag(&"Ability.Transfusion")
	check(transfusion != null, "the Bloodbinder has Transfusion")
	if transfusion == null:
		return
	eq(AutoPolicy.heal_cost(transfusion, binder), 1000, "its cost is 10% (of its max HP), on the same scale as an SP share")
	var vlad := battle.unit_by_id(&"P1")
	_set_stat(vlad, "hp", vlad.stat(BattleUnit.MAX_HP) / 4)
	var policy := AutoPolicy.new()
	var pick := policy.choose(battle, binder)
	eq(pick.get("ability"), &"Ability.Transfusion", "a hurt ally gets Transfusion (%s)" % policy.last_reason)
	eq(pick.get("target"), &"P1", "on the hurt ally")


## Review fix: a hit a shield soaks is still a hit: Damage.Taken is sent with the amount soaked, and HP is untouched.
func test_a_shielded_hit_is_still_a_hit() -> void:
	if not _ready_to_test():
		return
	var battle := _battle()
	await _start(battle)
	var vlad := battle.unit_by_id(&"P1")
	_set_stat(vlad, "shield", 500000)
	var heard := preload("res://tests/combat/test_statuses.gd").listen(vlad)
	var slime := battle.unit_by_id(&"E1")
	var attack: BattleAbility = slime.action_abilities()[0]
	var hp_before := vlad.stat(BattleUnit.HP)
	await battle._activate(slime, attack, vlad)
	await battle._drain_triggers()
	eq(vlad.stat(BattleUnit.HP), hp_before, "the shield took it all")
	check(vlad.stat("shield") < 500000, "the shield went down")
	var taken := heard.filter(func(entry) -> bool: return String(entry[0]) == String(Battle.EVENT_DAMAGE_TAKEN))
	check(not taken.is_empty(), "Event.Damage.Taken was still sent: %s" % [heard.map(func(entry): return entry[0])])


func test_blood_rite_gives_the_party_lifesteal() -> void:
	if not _ready_to_test():
		return
	var battle := _battle()
	await _start(battle)
	check(await _act(battle, &"P2", &"Ability.Bloodrite"), "Blood Rite casts")
	eq(battle.unit_by_id(&"P1").stat("lifesteal"), 2000 + 1200, "+12% on top of Vlad's own")
	eq(battle.unit_by_id(&"P2").stat("lifesteal"), 1000 + 1200, "and on the Bloodbinder's")


## The Vampire Hunter (P1) and the Werewolf (P2) against two sturdy slimes.
func _hunt() -> Battle:
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	var error := battle.setup({"schemaVersion": 2, "battleId": "demo-second-pack-hunt", "seed": "5",
		"encounterId": "demo.encounter.slime_pair", "party": [
			{"slot": 1, "unitDefId": "demo.character.vampire_hunter", "level": 1, "skills": [], "equipmentIds": [], "items": [],
				"useSlots": []},
			{"slot": 2, "unitDefId": "demo.character.werewolf", "level": 1, "skills": [], "equipmentIds": [], "items": [],
				"useSlots": []}]}, _content_index())
	check(error == "", "demo battle setup: " + error)
	for unit in battle.units():
		if not unit.is_party():
			_set_stat(unit, "max_hp", 1000000)
			_set_stat(unit, "hp", 1000000)
	battle._started = true
	return battle


func _stacks(unit: BattleUnit, tag: String) -> int:
	for status in unit.statuses():
		if status["tag"] == tag:
			return int(status["stacks"])
	return 0


func test_focus_builds_on_misses_and_a_crit_spends_it_and_silvers() -> void:
	if not _ready_to_test():
		return
	var battle := _hunt()
	await _start(battle)
	var hunter := battle.unit_by_id(&"P1")
	_set_stat(hunter, "crit_rate", -10000)  # no crit, even with Focus
	await _act(battle, &"P1", &"Ability.Silverbolt", &"E1")
	await _act(battle, &"P1", &"Ability.Silverbolt", &"E1")
	eq(_stacks(hunter, "Status.Focus"), 2, "two hits without a crit: 2 Focus")
	check(hunter.stat("crit_dmg") > 6000, "Focus raises crit damage")
	_set_stat(hunter, "crit_rate", 0)
	_set_stat(hunter, "energy", hunter.stat("max_energy"))
	await _act(battle, &"P1", &"Ability.Ult.Dawnbreak", &"E1")  # always a crit
	eq(_stacks(hunter, "Status.Focus"), 0, "a crit spends every Focus")
	check(battle.unit_by_id(&"E1").asc.has_tag(&"Status.Debuff.Silvered"), "the crit Silvers its target")
	check(battle.unit_by_id(&"E1").stat("heal_taken") < 10000, "a Silvered enemy heals less")
	check(not battle.unit_by_id(&"E2").asc.has_tag(&"Status.Debuff.Silvered"), "only the target")


## Spec second-pack 2.4 (D11): Focus is no buff, so a dispel leaves it.
func test_focus_survives_a_dispel() -> void:
	if not _ready_to_test():
		return
	var battle := _hunt()
	await _start(battle)
	var hunter := battle.unit_by_id(&"P1")
	_set_stat(hunter, "crit_rate", -10000)
	await _act(battle, &"P1", &"Ability.Silverbolt", &"E1")
	await _act(battle, &"P1", &"Ability.Silverbolt", &"E1")
	eq(_stacks(hunter, "Status.Focus"), 2, "two Focus")
	var dispel := GameplayEffectSpec.new(load(DEMO + "effects/dispel.tres"), GameplayEffectContext.new(battle.unit_by_id(&"E1"), hunter), 1)
	battle.unit_by_id(&"E1").asc.apply_effect_spec_to_target(dispel, hunter.asc)
	eq(_stacks(hunter, "Status.Focus"), 2, "a dispel leaves Focus")


## Spec second-pack 2.4 (D12): Silvered halves the heal a drained hit gives its target (the drained hit reads heal_taken).
func test_silvered_halves_a_drained_hits_heal() -> void:
	if not _ready_to_test():
		return
	var healed: Array[int] = []
	for silvered in [false, true]:
		var battle := _hunt()
		await _start(battle)
		var hunter := battle.unit_by_id(&"P1")
		var slime := battle.unit_by_id(&"E1")
		_set_stat(hunter, "crit_rate", -10000)
		slime.asc.add_tag(&"Drain.Physical")
		_set_stat(slime, "hp", 500000)
		if silvered:
			var spec := GameplayEffectSpec.new(load(DEMO + "effects/bm_silvered.tres"), GameplayEffectContext.new(hunter, hunter), 1)
			hunter.asc.apply_effect_spec_to_target(spec, slime.asc)
			check(slime.asc.has_tag(&"Status.Debuff.Silvered"), "Silvered")
		var before := slime.stat(BattleUnit.HP)
		await _act(battle, &"P1", &"Ability.Silverbolt", &"E1")
		healed.append(slime.stat(BattleUnit.HP) - before)
	check(healed[0] > 0, "a drained hit heals its target (%d)" % healed[0])
	eq(healed[1], healed[0] / 2, "Silvered halves it")


## Spec second-pack 2.5: Stake of Dawn's One More comes at most once a turn, however many crit kills.
func test_stake_of_dawn_gives_one_more_once_a_turn() -> void:
	if not _ready_to_test():
		return
	var battle := _holding([], ["stake_of_dawn"])
	await _start(battle)
	var vlad := battle.unit_by_id(&"P2")
	_set_stat(vlad, "crit_rate", 10000)
	for target in [&"E1", &"E2"]:
		_set_stat(battle.unit_by_id(target), "hp", 100)
		await _act(battle, &"P2", &"Ability.Fang", target)
		await battle._settle_deaths()
		await battle._drain_triggers()
	eq(battle.one_more_queue.count(vlad), 1, "two crit kills in one turn: one One More")


## Spec second-pack 2.3: Martyr's Grace: the Bloodbinder's heals grow with its missing HP.
func test_martyrs_grace_scales_with_missing_hp() -> void:
	if not _ready_to_test():
		return
	var battle := _battle()
	await _start(battle)
	var binder := battle.unit_by_id(&"P2")
	var most := binder.stat(BattleUnit.MAX_HP)
	eq(ExecCalcRestore.missing_bonus(binder.asc, "missing_hp_heal"), 0, "nothing at full HP")
	_set_stat(binder, "hp", most / 2)
	var half := ExecCalcRestore.missing_bonus(binder.asc, "missing_hp_heal")
	check(half > 0, "a bonus at half HP (%d)" % half)
	_set_stat(binder, "hp", most / 10)
	check(ExecCalcRestore.missing_bonus(binder.asc, "missing_hp_heal") > half, "and more at 10% HP")


## Spec second-pack B3 (D29): the HUD shows a Bloodbinder's ult as AUTO (it casts itself); a pressable ult is not AUTO.
func test_the_hud_shows_the_bloodbinders_ult_as_auto() -> void:
	if not _ready_to_test():
		return
	var battle := _battle()
	await _start(battle)
	var panel: Node = load("res://presentation/demo/ui/battle_party_panel.tscn").instantiate()
	var binder_row: Dictionary = panel._row(battle.unit_by_id(&"P2"), false)
	var vlad_row: Dictionary = panel._row(battle.unit_by_id(&"P1"), false)
	check(binder_row["show_ult"], "the Bloodbinder's row shows the ult button")
	eq(binder_row["ult_state"], "auto", "as AUTO")
	check(vlad_row["ult_state"] != "auto", "Vlad's ult is pressed, not AUTO")
	var row: Node = load("res://presentation/demo/ui/member_row.tscn").instantiate()
	eq(row.auto_text, "AUTO", "the button reads AUTO")
	row.free()
	panel.free()


func test_the_werewolf_claws_only_in_wolf_form() -> void:
	if not _ready_to_test():
		return
	var battle := _hunt()
	await _start(battle)
	var fired := []
	battle.trigger_activated.connect(func(unit_id, tag, _event): fired.append("%s %s" % [unit_id, tag]))
	await _act(battle, &"P2", &"Ability.Wolfrend", &"E2")
	check(not fired.has("P2 Ability.Passive.Clawbasic"), "no claw at full HP: %s" % [fired])
	var wolf := battle.unit_by_id(&"P2")
	_set_stat(wolf, "hp", wolf.stat(BattleUnit.MAX_HP) / 3)
	battle._update_health_state(wolf, false)
	check(wolf.asc.has_tag(&"State.WolfForm"), "under half HP it is in Wolf Form")
	eq(wolf.stat("lifesteal"), 1000, "Wolf Form: +10% lifesteal")
	var e2_before := battle.unit_by_id(&"E2").stat(BattleUnit.HP)
	await _act(battle, &"P2", &"Ability.Wolfrend", &"E2")
	check(fired.has("P2 Ability.Passive.Clawbasic"), "a claw after its basic: %s" % [fired])
	check(battle.unit_by_id(&"E2").stat(BattleUnit.HP) < e2_before, "on the action's target")
	_set_stat(wolf, "hp", wolf.stat(BattleUnit.MAX_HP))
	battle._update_health_state(wolf, false)
	check(not wolf.asc.has_tag(&"State.WolfForm"), "healed above half: Wolf Form ends")
	eq(wolf.stat("lifesteal"), 0, "and its lifesteal")


func test_howl_turns_only_the_werewolf_and_buffs_the_party() -> void:
	if not _ready_to_test():
		return
	var battle := _hunt()
	await _start(battle)
	var atk := battle.unit_by_id(&"P1").stat("atk")
	check(await _act(battle, &"P2", &"Ability.Howl"), "Howl casts")
	check(battle.unit_by_id(&"P1").stat("atk") > atk, "the party +ATK")
	check(battle.unit_by_id(&"P2").asc.has_tag(&"Status.WolfForm"), "the Werewolf in Wolf Form")
	check(not battle.unit_by_id(&"P1").asc.has_tag(&"Status.WolfForm"), "the Hunter never turns")
	eq(battle.unit_by_id(&"P2").stat("lifesteal"), 1000, "one +10% lifesteal")


func test_moonfall_frenzy_claws_random_enemies_then_wolf_form() -> void:
	if not _ready_to_test():
		return
	var battle := _hunt()
	await _start(battle)
	var wolf := battle.unit_by_id(&"P2")
	var hp := {}
	for id in [&"E1", &"E2"]:
		hp[id] = battle.unit_by_id(id).stat(BattleUnit.HP)
	_set_stat(wolf, "energy", wolf.stat("max_energy"))
	check(await _act(battle, &"P2", &"Ability.Ult.Moonfallfrenzy"), "the ult casts")
	var hit := [&"E1", &"E2"].filter(func(id): return battle.unit_by_id(id).stat(BattleUnit.HP) < hp[id])
	check(not hit.is_empty(), "the claws hit")
	check(wolf.asc.has_tag(&"Status.WolfForm"), "then Wolf Form")


## The Bloodletter (P1) and Vlad (P2) against two sturdy slimes.
func _letting() -> Battle:
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	var error := battle.setup({"schemaVersion": 2, "battleId": "demo-second-pack-letting", "seed": "5",
		"encounterId": "demo.encounter.slime_pair", "party": [
			{"slot": 1, "unitDefId": "demo.character.bloodletter", "level": 1, "skills": [], "equipmentIds": [], "items": [],
				"useSlots": []},
			{"slot": 2, "unitDefId": "demo.character.vampire", "level": 1, "skills": [], "equipmentIds": [], "items": [],
				"useSlots": []}]}, _content_index())
	check(error == "", "demo battle setup: " + error)
	for unit in battle.units():
		if not unit.is_party():
			_set_stat(unit, "max_hp", 1000000)
			_set_stat(unit, "hp", 1000000)
	battle._started = true
	return battle


func test_open_vein_bleeds_and_siphon_detonates_for_a_party_heal() -> void:
	if not _ready_to_test():
		return
	var battle := _letting()
	await _start(battle)
	var enemy := battle.unit_by_id(&"E1")
	check(await _act(battle, &"P1", &"Ability.Openvein", &"E1"), "Open Vein casts")
	eq(_stacks(enemy, "Status.Debuff.Bleed"), 3, "3 Bleed stacks")
	var vlad := battle.unit_by_id(&"P2")
	_set_stat(vlad, "hp", vlad.stat(BattleUnit.MAX_HP) / 2)
	var vlad_hp := vlad.stat(BattleUnit.HP)
	var enemy_hp := enemy.stat(BattleUnit.HP)
	var fired := []
	battle.trigger_activated.connect(func(unit_id, tag, _event): fired.append("%s %s" % [unit_id, tag]))
	_set_stat(battle.unit_by_id(&"P1"), "mp", 10000)
	check(await _act(battle, &"P1", &"Ability.Siphon", &"E1"), "Siphon casts")
	check(enemy.stat(BattleUnit.HP) < enemy_hp, "the detonation hurts")
	eq(_stacks(enemy, "Status.Debuff.Bleed"), 0, "and clears the Bleed")
	check(fired.has("P1 Ability.Passive.Siphonshare"), "the party heal fires: %s" % [fired])
	check(vlad.stat(BattleUnit.HP) > vlad_hp, "an ally heals")


func test_bleed_ticks_heal_the_most_hurt_ally() -> void:
	if not _ready_to_test():
		return
	var battle := _letting()
	await _start(battle)
	await _act(battle, &"P1", &"Ability.Openvein", &"E1")
	var vlad := battle.unit_by_id(&"P2")
	_set_stat(vlad, "hp", vlad.stat(BattleUnit.MAX_HP) / 3)
	var before := vlad.stat(BattleUnit.HP)
	var enemy := battle.unit_by_id(&"E1")
	enemy.asc.turn_start()  # the Bleed ticks
	await battle._drain_triggers()
	check(vlad.stat(BattleUnit.HP) > before, "a tick heals the most hurt ally (Vlad)")


func test_crimson_letting_makes_hits_on_bleeding_enemies_heal() -> void:
	if not _ready_to_test():
		return
	var battle := _letting()
	await _start(battle)
	var letter := battle.unit_by_id(&"P1")
	_set_stat(letter, "energy", letter.stat("max_energy"))
	check(await _act(battle, &"P1", &"Ability.Ult.Crimsonletting"), "the ult casts")
	for id in [&"E1", &"E2"]:
		eq(_stacks(battle.unit_by_id(id), "Status.Debuff.Bleed"), 2, "%s: 2 Bleed stacks" % id)
	check(letter.stat("bleed_lifesteal") > 0 and battle.unit_by_id(&"P2").stat("bleed_lifesteal") > 0, "the party's Letting")
	_set_stat(letter, "hp", letter.stat(BattleUnit.MAX_HP) / 2)
	var before := letter.stat(BattleUnit.HP)
	await _act(battle, &"P1", &"Ability.Lancet", &"E1")
	check(letter.stat(BattleUnit.HP) > before, "a hit on a Bleeding enemy heals")


func test_bleed_holds_five_stacks_from_one_source() -> void:
	if not _ready_to_test():
		return
	var battle := _letting()
	await _start(battle)
	await _act(battle, &"P1", &"Ability.Openvein", &"E1")
	_set_stat(battle.unit_by_id(&"P1"), "mp", 10000)
	await _act(battle, &"P1", &"Ability.Openvein", &"E1")
	eq(_stacks(battle.unit_by_id(&"E1"), "Status.Debuff.Bleed"), 5, "the rules' cap of 5")


# --- The Blood Moon items (2.5) ---------------------------------------------------------------------------------------

## The Werewolf (P1) holding `items` and Vlad (P2) holding `second`, against two sturdy slimes.
func _holding(items: Array, second: Array = []) -> Battle:
	var ids := func(names: Array) -> Array:
		return names.map(func(name: String) -> String: return "demo.item." + name)
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	var error := battle.setup({"schemaVersion": 2, "battleId": "demo-second-pack-items", "seed": "5",
		"encounterId": "demo.encounter.slime_pair", "party": [
			{"slot": 1, "unitDefId": "demo.character.werewolf", "level": 1, "skills": [], "equipmentIds": [],
				"items": ids.call(items), "useSlots": []},
			{"slot": 2, "unitDefId": "demo.character.vampire", "level": 1, "skills": [], "equipmentIds": [],
				"items": ids.call(second), "useSlots": []}]}, _content_index())
	check(error == "", "demo battle setup: " + error)
	for unit in battle.units():
		if not unit.is_party():
			_set_stat(unit, "max_hp", 1000000)
			_set_stat(unit, "hp", 1000000)
	battle._started = true
	return battle


func _in_wolf_form(battle: Battle) -> void:
	var wolf := battle.unit_by_id(&"P1")
	_set_stat(wolf, "hp", wolf.stat(BattleUnit.MAX_HP) / 3)
	battle._update_health_state(wolf, false)


func test_the_fifty_three_items_are_blood_moon_cards() -> void:
	if not _ready_to_test():
		return
	var count := 0
	for table in [_content_index().items, _content_index().equipment]:
		for id in table:
			if table[id].tags.has(&"Card.Set.Bloodmoon"):
				count += 1
				var pools: Array = table[id].tags.filter(func(tag): return String(tag).begins_with("Pool."))
				check(not (pools.has(&"Pool.Treasure") and pools.has(&"Pool.Boss")), "%s: never Treasure and Boss" % id)
	eq(count, 53, "53 Blood Moon items and pieces")


func test_twin_blades_repeat_a_follow_up_once() -> void:
	if not _ready_to_test():
		return
	var plain := _holding([])
	await _start(plain)
	_in_wolf_form(plain)
	var plain_before := plain.unit_by_id(&"E2").stat(BattleUnit.HP)
	await _act(plain, &"P1", &"Ability.Wolfrend", &"E2")
	var plain_loss := plain_before - plain.unit_by_id(&"E2").stat(BattleUnit.HP)
	var twin := _holding(["twin_blades"])
	await _start(twin)
	_in_wolf_form(twin)
	var fired := []
	twin.trigger_activated.connect(func(unit_id, tag, _event): fired.append(String(tag)))
	var before := twin.unit_by_id(&"E2").stat(BattleUnit.HP)
	await _act(twin, &"P1", &"Ability.Wolfrend", &"E2")
	eq(fired.count("Ability.Passive.Itwinblades"), 1, "one echo of the claw: %s" % [fired])
	check(before - twin.unit_by_id(&"E2").stat(BattleUnit.HP) > plain_loss, "the claw hit twice")
	eq(twin.chain_cap_hits, 0, "no chain")


func test_thorned_rose_never_feeds_itself_through_lifesteal() -> void:
	if not _ready_to_test():
		return
	var battle := _holding([], ["thorned_rose"])
	await _start(battle)
	var vlad := battle.unit_by_id(&"P2")
	_set_stat(vlad, "hp", vlad.stat(BattleUnit.MAX_HP) / 2)
	var fired := []
	battle.trigger_activated.connect(func(unit_id, tag, _event): fired.append(String(tag)))
	await _act(battle, &"P2", &"Ability.Fang", &"E1")  # the lifesteal heal: one rose, whose own lifesteal feeds none
	eq(fired.count("Ability.Passive.Ithornedrose"), 1, "one rose: %s" % [fired])
	eq(battle.chain_cap_hits, 0, "no chain to the cap")


func test_transfusion_kit_shares_a_heal_once() -> void:
	if not _ready_to_test():
		return
	var battle := _holding([], ["transfusion_kit"])
	await _start(battle)
	var wolf := battle.unit_by_id(&"P1")
	_set_stat(wolf, "hp", wolf.stat(BattleUnit.MAX_HP) / 2)
	_set_stat(battle.unit_by_id(&"P2"), "hp", battle.unit_by_id(&"P2").stat(BattleUnit.MAX_HP) * 9 / 10)
	var fired := []
	battle.trigger_activated.connect(func(unit_id, tag, _event): fired.append(String(tag)))
	var wolf_hp := wolf.stat(BattleUnit.HP)
	await _act(battle, &"P2", &"Ability.Fang", &"E1")  # the lifesteal is a heal Vlad gives himself
	eq(fired.count("Ability.Passive.Itransfusionkit"), 1, "the kit shares the heal once: %s" % [fired])
	check(wolf.stat(BattleUnit.HP) > wolf_hp, "the most hurt ally healed")
	eq(battle.chain_cap_hits, 0, "no chain")


func test_nights_embrace_saves_once() -> void:
	if not _ready_to_test():
		return
	var battle := _holding([], ["nights_embrace"])
	await _start(battle)
	var vlad := battle.unit_by_id(&"P2")
	_set_stat(vlad, "hp", 0)
	await battle._settle_deaths()
	check(vlad.alive and vlad.stat(BattleUnit.HP) > 0, "survives a killing blow")
	check(vlad.asc.has_tag(&"State.EmbraceSaved"), "spent for the battle")
	eq(vlad.stat("lifesteal"), (2000 + 1000) * 2, "lifesteal doubled")


func test_stake_of_dawn_gives_one_more_for_a_crit_kill() -> void:
	if not _ready_to_test():
		return
	var battle := _holding([], ["stake_of_dawn"])
	await _start(battle)
	var vlad := battle.unit_by_id(&"P2")
	_set_stat(vlad, "crit_rate", 10000)
	_set_stat(battle.unit_by_id(&"E1"), "hp", 100)
	await _act(battle, &"P2", &"Ability.Fang", &"E1")
	await battle._settle_deaths()
	await battle._drain_triggers()
	check(battle.one_more_queue.has(vlad), "a crit that kills: a One More")
	check(vlad.asc.has_tag(Battle.ONE_MORE_GRANT_TAG), "flagged for this turn")


func test_low_hp_items_wake_under_their_line() -> void:
	if not _ready_to_test():
		return
	var battle := _holding([], ["full_moon_charm", "moonstone_pendant"])
	await _start(battle)
	var vlad := battle.unit_by_id(&"P2")
	var crit := vlad.stat("crit_rate")
	_set_stat(vlad, "hp", vlad.stat(BattleUnit.MAX_HP) * 55 / 100)
	battle._update_health_state(vlad, false)
	check(vlad.asc.has_tag(Battle.HEALTH_LOW_TAG), "55% is under the 60% line of the Pendant")
	eq(vlad.stat("crit_rate"), crit + 1500, "the Charm wakes: +15% crit rate")


func test_velvet_fangs_turn_overheal_into_a_shield() -> void:
	if not _ready_to_test():
		return
	var battle := _holding([], ["velvet_fangs"])
	await _start(battle)
	var vlad := battle.unit_by_id(&"P2")
	await _act(battle, &"P2", &"Ability.Fang", &"E1")
	check(vlad.stat("shield") > 0, "lifesteal at full HP became a shield")
	check(vlad.stat("shield") <= Fixed.pct(vlad.stat(BattleUnit.MAX_HP), 1500), "at most 15% of max HP")


func test_burst_vein_detonates_a_bleeding_target_on_a_crit() -> void:
	if not _ready_to_test():
		return
	var battle := _holding([], ["burst_vein"])
	await _start(battle)
	var vlad := battle.unit_by_id(&"P2")
	var enemy := battle.unit_by_id(&"E1")
	enemy.asc.apply_gameplay_effect(load(DEMO + "effects/bm_bleed.tres"), vlad.asc)
	enemy.asc.apply_gameplay_effect(load(DEMO + "effects/bm_bleed.tres"), vlad.asc)
	_set_stat(vlad, "crit_rate", 10000)
	_set_stat(vlad, "bleed_chance", 0)
	var fired := []
	battle.trigger_activated.connect(func(unit_id, tag, _event): fired.append(String(tag)))
	await _act(battle, &"P2", &"Ability.Fang", &"E1")
	check(fired.has("Ability.Passive.Iburstvein"), "the crit detonates: %s" % [fired])
	eq(_stacks(enemy, "Status.Debuff.Bleed"), 0, "the Bleed is spent")
	check(fired.has("Ability.Passive.Iburstshare"), "and heals the party")


func test_every_item_holds_without_errors_through_a_fight() -> void:
	if not _ready_to_test():
		return
	var names: Array = []
	for id in _content_index().items:
		if _content_index().items[id].tags.has(&"Card.Set.Bloodmoon"):
			names.append(String(id).trim_prefix("demo.item."))
	names.sort()
	var battle := _holding(names.slice(0, names.size() / 2), names.slice(names.size() / 2))
	await _start(battle)
	for round in 3:
		await _act(battle, &"P1", &"Ability.Wolfrend", &"E1")
		await _act(battle, &"P2", &"Ability.Bloodlance", &"E2")
		await battle._settle_deaths()
	eq(battle.chain_cap_hits, 0, "every item at once: no trigger chain reaches the cap")
