## Spec economy-challenges: a ChallengeDefinition is independent stars on one encounter, each star a list of data-defined
## conditions (`ChallengeCondition` resources: turns, units, event counts, AllOf / AnyOf / Not). The replay reports one
## `completions` fact per earned star under "<challenge>.<star>" (never hashed). The fixtures' `fixture.challenge.boss_trial`
## (stars win; fast = in at most 30 turns; flawless = nobody down) is on the boss encounter.
extends TestCase

const Statuses := preload("res://tests/combat/test_statuses.gd")
const PARTY: Array = ["guard_weak", "hexer", "breaker"]


func _snapshot(seed_text: String) -> Dictionary:
	var snap: Dictionary = Statuses.status_snapshot(PARTY, "boss", seed_text)
	snap["battleId"] = "challenge-seed-%s" % seed_text
	return snap


func _star(star_id: String, conditions: Array = []) -> ChallengeStar:
	var star := ChallengeStar.new()
	star.id = StringName(star_id)
	for condition in conditions:
		star.conditions.append(condition)
	return star


func _turns(compare: int, turns: int) -> ChallengeTurnsCondition:
	var condition := ChallengeTurnsCondition.new()
	condition.compare = compare
	condition.turns = turns
	return condition


func _units(side: int, quantifier: int, alive: int = ChallengeUnitsCondition.AliveFilter.ANY_STATE) -> ChallengeUnitsCondition:
	var condition := ChallengeUnitsCondition.new()
	condition.side = side
	condition.quantifier = quantifier
	condition.alive = alive
	return condition


func _event(side: int, tag: String, compare: int, count: int) -> ChallengeEventCondition:
	var condition := ChallengeEventCondition.new()
	condition.side = side
	condition.event_tag = StringName(tag)
	condition.compare = compare
	condition.count = count
	return condition


func _challenge(id: String, stars: Array) -> ChallengeDefinition:
	var challenge := ChallengeDefinition.new()
	challenge.id = StringName(id)
	challenge.encounter_id = &"fixture.encounter.boss"
	for star in stars:
		challenge.stars.append(star)
	return challenge


## A finished battle on the boss encounter, played by the scripted party, with its replay request and the event tally.
func _played(seed_text: String) -> Array:
	var snap := _snapshot(seed_text)
	var battle := new_battle(snap)
	var tally := ChallengeTally.new()
	tally.attach(battle)
	var controller := ScriptedController.new()
	await battle.run(controller)
	var request := {"snapshot": snap, "actionLog": ActionRecorder.build_log(controller.entries, battle.outcome, battle.final_hash)}
	return [battle, request, tally]


func test_the_content_index_finds_a_challenge_by_encounter() -> void:
	var content := fixtures()
	check(content.challenges.has(&"fixture.challenge.boss_trial"), "the fixture challenge is indexed")
	eq(content.challenges_for("fixture.encounter.boss").size(), 1, "one challenge on the boss encounter")
	eq(content.challenges_for("fixture.encounter.duel").size(), 0, "none on the duel")
	eq(content.problems, PackedStringArray(), "no duplicate or id-less challenge")


func test_each_star_is_earned_on_its_own_in_any_order() -> void:
	var played := await _played("7")
	var battle: Battle = played[0]
	eq(battle.outcome, "Victory", "the fixture party wins the boss encounter (else this test needs another seed)")
	var never := _turns(ChallengeCondition.Compare.LESS_OR_EQUAL, 0)  # fewer than one turn: impossible once the battle ran
	var any_time := _turns(ChallengeCondition.Compare.LESS_OR_EQUAL, 100000)
	var names := func(challenge: ChallengeDefinition) -> Array:
		return challenge.stars_reached(battle).map(func(star: ChallengeStar) -> String: return str(star.id))
	eq(names.call(_challenge("a", [_star("win")])), ["win"], "a star with no conditions is just a win")
	eq(names.call(_challenge("b", [_star("win"), _star("never", [never]), _star("fast", [any_time])])), ["win", "fast"],
		"a failed star does not hold back the one after it: star 3 without star 2")
	eq(names.call(_challenge("c", [_star("never", [never]), _star("win")])), ["win"], "a failed first star does not hold back the rest")
	eq(names.call(_challenge("d", [_star("fast", [any_time]), _star("win")])), ["fast", "win"], "order does not matter: display order is kept")
	eq(names.call(_challenge("e", [])), [], "no stars, none earned")
	eq(names.call(_challenge("f", [_star("both", [any_time, never])])), [], "every condition of a star must hold")
	eq(_challenge("g", []).reward_id(_star("fast")), "g.fast", "the reward id is the challenge id, a dot and the star id")


func test_a_lost_battle_earns_no_star() -> void:
	var snap := _snapshot("7")
	for member in snap["party"]:
		member["hp"] = 100  # one hit point: the party loses
	var battle := new_battle(snap)
	await battle.run(ScriptedController.new())
	eq(battle.outcome, "Defeat", "the party lost")
	eq(fixtures().challenges[&"fixture.challenge.boss_trial"].stars_reached(battle).size(), 0, "a loss earns no star, not even a no-condition one")


func test_turn_and_unit_conditions_read_the_final_state() -> void:
	var played := await _played("7")
	var battle: Battle = played[0]
	var turns := battle.turn
	check(_turns(ChallengeCondition.Compare.LESS_OR_EQUAL, turns).met(battle, null), "turns <= the battle's own count")
	check(not _turns(ChallengeCondition.Compare.LESS_OR_EQUAL, turns - 1).met(battle, null), "turns <= one fewer")
	check(_turns(ChallengeCondition.Compare.GREATER_OR_EQUAL, turns).met(battle, null), "turns >= the count")
	check(_turns(ChallengeCondition.Compare.EQUAL, turns).met(battle, null), "turns == the count")
	var party_alive := battle.units().filter(func(u: BattleUnit) -> bool: return u.side == BattleUnit.Side.PARTY and not u.alive).is_empty()
	var all_alive := _units(ChallengeCondition.Side.PARTY, ChallengeUnitsCondition.Quantifier.ALL, ChallengeUnitsCondition.AliveFilter.ALIVE)
	eq(all_alive.met(battle, null), party_alive, "'every party unit alive' follows the units' final state")
	var enemies_dead := _units(ChallengeCondition.Side.ENEMY, ChallengeUnitsCondition.Quantifier.ALL, ChallengeUnitsCondition.AliveFilter.DEAD)
	check(enemies_dead.met(battle, null), "a won battle ends with every enemy dead")
	var none_enemy_alive := _units(ChallengeCondition.Side.ENEMY, ChallengeUnitsCondition.Quantifier.NONE, ChallengeUnitsCondition.AliveFilter.ALIVE)
	check(none_enemy_alive.met(battle, null), "NONE of the enemies alive")
	var any_party_dead := _units(ChallengeCondition.Side.PARTY, ChallengeUnitsCondition.Quantifier.ANY, ChallengeUnitsCondition.AliveFilter.DEAD)
	eq(any_party_dead.met(battle, null), not party_alive, "ANY party unit dead")


func test_attribute_conditions_compare_the_current_value_or_a_percentage() -> void:
	var played := await _played("7")
	var battle: Battle = played[0]
	var healthy := _units(ChallengeCondition.Side.PARTY, ChallengeUnitsCondition.Quantifier.ANY, ChallengeUnitsCondition.AliveFilter.ALIVE)
	healthy.attribute = "hp"
	healthy.attribute_compare = ChallengeCondition.Compare.GREATER_OR_EQUAL
	healthy.attribute_value_x100 = 1
	check(healthy.met(battle, null), "some survivor has hp >= 1 (x100)")
	var intact := _units(ChallengeCondition.Side.PARTY, ChallengeUnitsCondition.Quantifier.ANY)
	intact.attribute = "hp"
	intact.percent_of_attribute = "max_hp"
	intact.attribute_compare = ChallengeCondition.Compare.GREATER_OR_EQUAL
	intact.attribute_value_x100 = 10001  # more than 100.01%: no one
	check(not intact.met(battle, null), "no unit is above 100% of its max hp")
	intact.attribute_value_x100 = 0
	check(intact.met(battle, null), "every unit is at least 0%")
	var missing := _units(ChallengeCondition.Side.PARTY, ChallengeUnitsCondition.Quantifier.ANY)
	missing.attribute = "no_such_attribute"
	check(not missing.met(battle, null), "an attribute the unit lacks never passes")


func test_a_tag_query_selects_the_units_a_condition_counts() -> void:
	var played := await _played("7")
	var battle: Battle = played[0]
	var marked := battle.units().filter(func(u: BattleUnit) -> bool: return u.side == BattleUnit.Side.PARTY)[0] as BattleUnit
	marked.asc.add_tag(&"Fixture.Challenge.Marked")
	var query := GameplayTagQuery.new()
	query.require_all_tags = [&"Fixture.Challenge.Marked"]
	var any_marked := _units(ChallengeCondition.Side.PARTY, ChallengeUnitsCondition.Quantifier.ANY)
	any_marked.tag_query = query
	check(any_marked.met(battle, null), "ANY party unit carries the tag")
	var all_marked := _units(ChallengeCondition.Side.PARTY, ChallengeUnitsCondition.Quantifier.ALL)
	all_marked.tag_query = query
	check(not all_marked.met(battle, null), "but not ALL of them")
	var enemy_marked := _units(ChallengeCondition.Side.ENEMY, ChallengeUnitsCondition.Quantifier.ANY)
	enemy_marked.tag_query = query
	check(not enemy_marked.met(battle, null), "and no enemy does")
	var excluded := GameplayTagQuery.new()
	excluded.ignore_tags = [&"Fixture.Challenge.Marked"]
	var none_unmarked := _units(ChallengeCondition.Side.PARTY, ChallengeUnitsCondition.Quantifier.NONE)
	none_unmarked.tag_query = excluded
	check(not none_unmarked.met(battle, null), "NONE of the units without the tag: the others have none")


func test_event_conditions_count_what_the_battle_delivered() -> void:
	var played := await _played("7")
	var battle: Battle = played[0]
	var tally: ChallengeTally = played[2]
	var turn_starts := tally.count(ChallengeCondition.Side.PARTY, Battle.EVENT_TURN_START)
	check(turn_starts > 0, "the party received turn-start events")
	check(_event(ChallengeCondition.Side.PARTY, str(Battle.EVENT_TURN_START), ChallengeCondition.Compare.EQUAL, turn_starts).met(battle, tally), "== the tally")
	check(not _event(ChallengeCondition.Side.PARTY, str(Battle.EVENT_TURN_START), ChallengeCondition.Compare.GREATER_OR_EQUAL, turn_starts + 1).met(battle, tally), ">= one more")
	var parent := str(Battle.EVENT_TURN_START).get_base_dir() if false else str(Battle.EVENT_TURN_START).rsplit(".", true, 1)[0]
	eq(tally.count(ChallengeCondition.Side.PARTY, StringName(parent)) >= turn_starts, true, "a parent tag counts its children")
	check(_event(ChallengeCondition.Side.PARTY, "Event.Nothing.Like.This", ChallengeCondition.Compare.EQUAL, 0).met(battle, tally), "an event that never happened counts 0")
	check(_event(ChallengeCondition.Side.PARTY, "Event.Nothing.Like.This", ChallengeCondition.Compare.EQUAL, 0).met(battle, null), "no tally counts as 0 events")
	check(not _event(ChallengeCondition.Side.PARTY, str(Battle.EVENT_TURN_START), ChallengeCondition.Compare.GREATER_OR_EQUAL, 1).met(battle, null), "and fails a minimum")


func test_composites_combine_conditions() -> void:
	var played := await _played("7")
	var battle: Battle = played[0]
	var yes := _turns(ChallengeCondition.Compare.LESS_OR_EQUAL, 100000)
	var no := _turns(ChallengeCondition.Compare.GREATER_OR_EQUAL, 100000)
	var all_of := ChallengeAllOf.new()
	all_of.conditions.append(yes)
	all_of.conditions.append(no)
	check(not all_of.met(battle, null), "AllOf with one false")
	var any_of := ChallengeAnyOf.new()
	any_of.conditions.append(no)
	any_of.conditions.append(yes)
	check(any_of.met(battle, null), "AnyOf with one true")
	var inverse := ChallengeNot.new()
	inverse.condition = no
	check(inverse.met(battle, null), "Not of a false condition")
	var nested := ChallengeAllOf.new()
	nested.conditions.append(any_of)
	nested.conditions.append(inverse)
	check(nested.met(battle, null), "nested composites")
	check(ChallengeAllOf.new().met(battle, null), "an empty AllOf is true")
	check(not ChallengeAnyOf.new().met(battle, null), "an empty AnyOf is false")


func test_the_replay_reports_one_completion_per_earned_star() -> void:
	var played := await _played("7")
	var battle: Battle = played[0]
	var result := await replay(played[1])
	eq(result.get("verdict"), "Verified", "the replay verifies")
	var challenge: ChallengeDefinition = fixtures().challenges[&"fixture.challenge.boss_trial"]
	var expected := []
	for star in challenge.stars_reached(battle):
		expected.append(ReplayRunner.completion_fact("fixture.challenge.boss_trial.%s" % star.id, 1))
	check(not expected.is_empty(), "the won battle earns at least the win star")
	eq(result["facts"]["completions"], expected, "one tier-1 completion per earned star, under its own reward id")
	eq(result["facts"]["bossIds"], ["fixture.enemy.chief"], "the boss is still reported as a boss, separately")


func test_the_replay_evaluates_event_conditions_with_its_own_tally() -> void:
	var played := await _played("7")
	var content := fixtures().overlay([_challenge("fixture.challenge.events", [
		_star("some", [_event(ChallengeCondition.Side.PARTY, str(Battle.EVENT_TURN_START), ChallengeCondition.Compare.GREATER_OR_EQUAL, 1)]),
		_star("absurd", [_event(ChallengeCondition.Side.PARTY, str(Battle.EVENT_TURN_START), ChallengeCondition.Compare.GREATER_OR_EQUAL, 1000000)]),
	])])
	var result := await ReplayRunner.new().run_on(played[1], content, host)
	var ids: Array = (result["facts"]["completions"] as Array).map(func(c: Dictionary) -> String: return c["challengeId"])
	check(ids.has("fixture.challenge.events.some"), "the replay counted events: the star that needs one is earned")
	check(not ids.has("fixture.challenge.events.absurd"), "and the impossible one is not")


func test_completions_do_not_change_the_hash_and_other_encounters_have_none() -> void:
	var request: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN + "squad-seed-42.json"))
	var result := await replay(request)
	check(not (result["facts"] as Dictionary).has("completions"), "an encounter with no challenge has no completions key")
	var played := await _played("7")
	var battle: Battle = played[0]
	eq((await replay(played[1]))["finalStateHash"], battle.final_hash, "the hash is the one the battle produced, tally or not")


func test_a_rejected_replay_reports_no_completions() -> void:
	var played := await _played("7")
	var tampered := copy(played[1])
	tampered["actionLog"]["claimedFinalHash"] = "0".repeat(64)
	var result := await replay(tampered)
	eq(result.get("verdict"), "Rejected", "the hash does not match")
	check(not result.has("facts"), "no facts, so no completions, on a rejection")


func test_the_validator_checks_challenges_and_their_conditions() -> void:
	var found := func(index: ContentIndex) -> Array:
		return ContentValidator.validate(index, {"tags": false}).filter(
			func(issue: ValidationIssue) -> bool: return issue.code in ["bad_challenge", "dangling_ref"]).map(
			func(issue: ValidationIssue) -> String: return issue.message)
	eq(found.call(fixtures().overlay([])), [], "the fixture challenge is valid")
	var empty_event := ChallengeEventCondition.new()  # no tag
	var no_test := ChallengeUnitsCondition.new()      # tests nothing
	var zero_turns := _turns(ChallengeCondition.Compare.LESS_OR_EQUAL, 0)
	var nested := ChallengeNot.new()                  # no condition
	var bad := _challenge("boss/anything", [])
	bad.encounter_id = &"fixture.encounter.nowhere"
	var spaced := _challenge("has space", [_star("one", [empty_event, no_test, zero_turns, nested, null]), _star("one"), _star("bad/id"), null])
	var messages: Array = found.call(fixtures().overlay([bad, spaced]))
	for expected in ["reserved boss/ prefix", "unknown encounter", "has no stars", "no ':' and no whitespace", "event_tag is empty",
			"tests nothing", "turns must be 1 or more", "not has no condition", "empty condition", "repeats the star id", "needs an id", "star 4 of"]:
		check(messages.any(func(m: String) -> bool: return m.contains(expected)), "'%s' is reported: %s" % [expected, messages])
