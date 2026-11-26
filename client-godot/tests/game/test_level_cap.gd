## Spec level-cap: growth bands (one stacking active effect each), level skills up to 50, the 49-threshold curve and its cap,
## XP per enemy level, the class card's next learns, no overflow at level 50 and the report's level blocks. Fixtures only.
extends TestCase

const CLIMBER := "fixture.character.climber"

var _runs: Array = []


func after_each() -> void:
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


static func _snapshot(level: int, character: String = CLIMBER) -> Dictionary:
	return {"schemaVersion": 2, "battleId": "level-cap", "seed": "13", "encounterId": "fixture.encounter.sp_trial",
		"party": [{"slot": 1, "unitDefId": character, "level": level, "skills": [], "equipmentIds": [], "items": [], "useSlots": []}]}


## {effect file name: stack count} of the unit's active growth effects.
func _growth(unit: BattleUnit) -> Dictionary:
	var found := {}
	for active: ActiveGameplayEffect in unit.asc._active_effects:
		var file := active.get_effect_def().resource_path.get_file().get_basename()
		if file.contains("growth"):
			check(not found.has(file), "one active effect per band (%s)" % file)
			found[file] = active.stack_count
	return found


func test_bands_taper_growth() -> void:
	eq(_growth(new_battle(_snapshot(1)).unit_by_id(&"P1")), {}, "level 1: no growth")
	var low := new_battle(_snapshot(15)).unit_by_id(&"P1")
	eq(_growth(low), {"lc_growth_1": 14}, "level 15: levels 2-15 in the first band")
	eq(low.stat("atk"), 84800, "400 ATK + 14 x 8%")
	var high := new_battle(_snapshot(20)).unit_by_id(&"P1")
	eq(_growth(high), {"lc_growth_1": 14, "lc_growth_2": 5}, "level 20: and levels 16-20 in the second")
	eq(high.stat("atk"), 92800, "400 ATK + 14 x 8% + 5 x 4%")
	var top := new_battle(_snapshot(50)).unit_by_id(&"P1")
	eq(_growth(top), {"lc_growth_1": 14, "lc_growth_2": 35}, "level 50: still two active effects")


## apply_stacks is one application per level, recalculated once: the same attributes, stacks and state.
func test_stacks_in_one_step_equal_one_by_one() -> void:
	var climber: CharacterDefinition = fixtures().characters[StringName(CLIMBER)]
	var built := new_battle(_snapshot(50)).unit_by_id(&"P1")
	var slow := new_battle(_snapshot(1)).unit_by_id(&"P1")
	for effect in climber.growth_at(50):
		slow.asc.apply_gameplay_effect(effect, slow.asc, slow.effect_level)
	eq(_growth(built), _growth(slow), "the same stack counts")
	for attribute_name in ["atk", "max_hp", "sp_gain"]:
		eq(built.stat(attribute_name), slow.stat(attribute_name), "%s the same" % attribute_name)
	for active: ActiveGameplayEffect in built.asc._active_effects:
		eq(active.stack_specs.size(), active.stack_count, "a spec per stack")
	eq(climber.growth_at(2000000000000).size(), CharacterDefinition.MAX_LEVEL - 1, "a forged level never loops for long")


func test_no_bands_keep_the_level_effect() -> void:
	var chanter: CharacterDefinition = fixtures().characters[&"fixture.character.chanter"]
	eq(chanter.growth_at(1).size(), 0, "level 1: nothing")
	eq(chanter.growth_at(4), [chanter.level_effect, chanter.level_effect, chanter.level_effect] as Array[GameplayEffect],
		"no bands: the level effect once per level")
	var gap: CharacterDefinition = fixtures().characters[StringName(CLIMBER)].duplicate()
	var late := GrowthBand.new()
	late.from_level = 10
	late.effect = chanter.level_effect
	var bands: Array[GrowthBand] = [late]
	gap.growth_bands = bands
	eq(gap.growth_at(11).size(), 2, "levels below the first band grow nothing")


func test_a_banded_battle_replays() -> void:
	var request: Dictionary = await record(_snapshot(35))
	var verified: Dictionary = await ReplayRunner.new().run_on(JSON.parse_string(WireJson.stringify(request)), fixtures(), host)
	eq(verified.get("verdict"), "Verified", "growth and skills are rebuilt from the level: %s" % verified)
	request["snapshot"]["party"][0]["level"] = 50
	var other: Dictionary = await ReplayRunner.new().run_on(JSON.parse_string(WireJson.stringify(request)), fixtures(), host)
	eq(other.get("verdict"), "Rejected", "another level is another battle")


func test_level_skills_to_fifty() -> void:
	var expected := {11: &"", 12: &"LcGaleOne", 19: &"LcGaleOne", 20: &"LcGaleTwo", 49: &"LcGaleTwo", 50: &"LcGaleThree"}
	for level in expected:
		var unit := new_battle(_snapshot(level)).unit_by_id(&"P1")
		for rank in [&"LcGaleOne", &"LcGaleTwo", &"LcGaleThree"]:
			eq(unit.ability_by_tag(StringName("Fixture.Ability." + rank)) != null, rank == expected[level],
				"level %d: %s" % [level, rank])


## The proposed curve: cumulative(k) = 15 x k x (k + 3), so its first 14 thresholds are the ones before this slice.
static func _curve() -> Array[int]:
	var curve: Array[int] = []
	for k in range(1, 50):
		curve.append(15 * k * (k + 3))
	return curve


func _leveled(per_level: int = 0) -> RunController:
	var run := start_run(host, "5", [CLIMBER])
	_runs.append(run)
	var leveled: RunStructure = run.structure.duplicate()
	leveled.xp_to_level = _curve()
	leveled.xp_per_enemy = 20
	leveled.xp_per_boss = 120
	leveled.xp_per_enemy_level = per_level
	run.structure = leveled
	return run


func test_the_curve_caps_at_fifty() -> void:
	var run := _leveled()
	run.gain_xp(13920, null)
	eq(run.state.member(1)["level"], 30, "13920 XP: level 30")
	run.gain_xp(38220 - 13920 - 1, null)
	eq(run.state.member(1)["level"], 49, "one XP short of the last threshold")
	run.gain_xp(1, null)
	eq(run.state.member(1)["level"], 50, "the cap")
	run.gain_xp(99999, null)
	eq(run.state.member(1)["level"], 50, "XP past it gives no level")
	eq(run.state.member(1)["xp"], 38220 + 99999, "and is kept")
	run.gain_levels(5, null)
	eq(run.state.member(1)["level"], 50, "free levels stop there too")


func test_xp_per_enemy_level() -> void:
	var two := [{"slot": 1, "unitDefId": "fixture.enemy.keeper", "variantId": null},
		{"slot": 2, "unitDefId": "fixture.enemy.keeper", "variantId": null}]
	var run := _leveled()
	eq(run.xp_for(two, &"fixture.encounter.sp_trial"), 40, "0: 20 per enemy, as before")
	var scaled := _leveled(3)
	var rules: ScalingRules = scaled.chapter().scaling
	var depth_level := rules.level_for_depth(0) if rules != null else 1
	eq(scaled.xp_for(two, &"fixture.encounter.sp_trial"), 40 + 3 * (depth_level + depth_level + 1),
		"and 3 per level: slot 2 is one level up")
	var elite := EnemyVariant.new()
	elite.level_bonus = 2
	eq(Battle.enemy_level(4, elite, null), 6, "a variant's bonus")
	eq(Battle.enemy_level(0, null, null), 1, "never below 1")


func test_the_class_card_shows_the_next_learns() -> void:
	var climber: CharacterDefinition = fixtures().characters[StringName(CLIMBER)]
	eq(ClassPickModel.learns(climber).map(func(row: Array) -> int: return row[0]), [12, 20, 50], "the first three")
	eq(ClassPickModel.learns(climber, 12).map(func(row: Array) -> int: return row[0]), [20, 50], "above a level")
	eq(ClassPickModel.learns(climber, 50), [], "nothing left")
	var shuffled: CharacterDefinition = climber.duplicate()
	var rows: Array[LevelSkill] = [climber.level_skills[2], climber.level_skills[0], climber.level_skills[1]]
	shuffled.level_skills = rows
	eq(ClassPickModel.learns(shuffled).map(func(row: Array) -> int: return row[0]), [12, 20, 50], "by level, whatever the table's order")


func test_no_overflow_at_fifty() -> void:
	var strong := _snapshot(50)
	strong["party"][0]["items"] = []
	for count in 200:
		strong["party"][0]["items"].append("fixture.item.ip_copy")
	var unit := new_battle(strong).unit_by_id(&"P1")
	for attribute_name in StateHasher._attribute_names(unit.asc):
		var value: float = unit.asc.get_attribute(attribute_name).current_value
		check(Fixed.is_whole(value) and absf(value) < 1000000000.0, "%s stays a small whole number (%s)" % [attribute_name, value])


func test_report_level_blocks() -> void:
	var runs: Array[Dictionary] = []
	runs.append({"runnerError": "", "stop": "", "status": RunState.WON, "levels": [{"floor": 1, "level": 1, "xp": 0},
		{"floor": 2, "level": 5, "xp": 420}, {"floor": 0, "level": 9, "xp": 1500}]})
	runs.append({"runnerError": "", "stop": "", "status": RunState.LOST, "levels": [{"floor": 1, "level": 1, "xp": 0},
		{"floor": 2, "level": 4, "xp": 400}, {"floor": 0, "level": 5, "xp": 500}]})
	runs.append({"runnerError": "boom", "stop": "", "status": RunState.LOST, "levels": [{"floor": 1, "level": 99, "xp": 0}]})
	var blocks := PlayReport.level_blocks(runs)
	eq(blocks["levelByFloor"]["02"], {"runs": 2, "p10": 4, "median": 4, "p90": 5, "max": 5}, "the level when floor 2 starts")
	eq(blocks["xpByFloor"]["01"]["median"], 400, "XP earned on floor 1")
	eq(blocks["xpByFloor"]["02"], {"runs": 1, "p10": 1080, "median": 1080, "p90": 1080, "max": 1080}, "an unfinished floor does not count")
	eq(blocks["endLevel"]["won"]["median"], 9, "the won run's end level")
	eq(blocks["endLevel"]["all"]["runs"], 2, "a stopped run counts nowhere")
	check(not PlayReport.level_text({"levelByFloor": blocks["levelByFloor"], "xpByFloor": blocks["xpByFloor"],
		"endLevel": blocks["endLevel"]}).is_empty(), "as text")
