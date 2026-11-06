## Spec economy-challenges: a ChallengeDefinition is stars on one encounter, and the replay reports the tier reached as a
## `completions` fact (never hashed). The fixtures' `fixture.challenge.boss_trial` (win, in at most 30 turns, nobody down)
## is on the boss encounter.
extends TestCase

const Statuses := preload("res://tests/combat/test_statuses.gd")
const PARTY: Array = ["guard_weak", "hexer", "breaker"]


func _snapshot(seed_text: String) -> Dictionary:
	var snap: Dictionary = Statuses.status_snapshot(PARTY, "boss", seed_text)
	snap["battleId"] = "challenge-seed-%s" % seed_text
	return snap


func _star(kind: ChallengeStar.Kind, value: int = 0) -> ChallengeStar:
	var star := ChallengeStar.new()
	star.kind = kind
	star.value = value
	return star


func _challenge(id: String, stars: Array) -> ChallengeDefinition:
	var challenge := ChallengeDefinition.new()
	challenge.id = StringName(id)
	challenge.encounter_id = &"fixture.encounter.boss"
	for star in stars:
		challenge.stars.append(star)
	return challenge


## A finished battle on the boss encounter, played by the scripted party, with its replay request.
func _played(seed_text: String) -> Array:
	var snap := _snapshot(seed_text)
	var battle := new_battle(snap)
	var controller := ScriptedController.new()
	await battle.run(controller)
	var request := {"snapshot": snap, "actionLog": ActionRecorder.build_log(controller.entries, battle.outcome, battle.final_hash)}
	return [battle, request]


func test_the_content_index_finds_a_challenge_by_encounter() -> void:
	var content := fixtures()
	check(content.challenges.has(&"fixture.challenge.boss_trial"), "the fixture challenge is indexed")
	eq(content.challenges_for("fixture.encounter.boss").size(), 1, "one challenge on the boss encounter")
	eq(content.challenges_for("fixture.encounter.duel").size(), 0, "none on the duel")
	eq(content.problems, PackedStringArray(), "no duplicate or id-less challenge")


func test_stars_count_in_a_row_from_the_first() -> void:
	var played := await _played("7")
	var battle: Battle = played[0]
	eq(battle.outcome, "Victory", "the fixture party wins the boss encounter (else this test needs another seed)")
	var win := _star(ChallengeStar.Kind.WIN)
	var impossible := _star(ChallengeStar.Kind.TURNS_AT_MOST, 0)
	var generous := _star(ChallengeStar.Kind.TURNS_AT_MOST, 100000)
	eq(_challenge("a", [win]).tier_for(battle), 1, "a win alone is tier 1")
	eq(_challenge("b", [win, generous]).tier_for(battle), 2, "a met second star is tier 2")
	eq(_challenge("c", [win, impossible, generous]).tier_for(battle), 1, "a failed star stops the count: star 3 does not skip it")
	eq(_challenge("d", [impossible, win]).tier_for(battle), 0, "a failed first star is tier 0")
	eq(_challenge("e", []).tier_for(battle), 0, "no stars, no tier")
	var surviving := _challenge("f", [win, _star(ChallengeStar.Kind.PARTY_ALIVE)])
	var everyone_alive := battle.units().filter(func(unit: BattleUnit) -> bool: return unit.side == BattleUnit.Side.PARTY and not unit.alive).is_empty()
	eq(surviving.tier_for(battle), 2 if everyone_alive else 1, "PARTY_ALIVE follows the units' final state")


func test_a_lost_battle_reaches_no_tier() -> void:
	var snap := _snapshot("7")
	for member in snap["party"]:
		member["hp"] = 100  # one hit point: the party loses
	var battle := new_battle(snap)
	await battle.run(ScriptedController.new())
	eq(battle.outcome, "Defeat", "the party lost")
	eq(fixtures().challenges[&"fixture.challenge.boss_trial"].tier_for(battle), 0, "a loss reaches no star, not even the WIN one")


func test_the_replay_reports_the_tier_as_a_completion_fact() -> void:
	var played := await _played("7")
	var battle: Battle = played[0]
	var result := await replay(played[1])
	eq(result.get("verdict"), "Verified", "the replay verifies")
	var expected := fixtures().challenges[&"fixture.challenge.boss_trial"].tier_for(battle) as int
	check(expected >= 1, "the won battle reaches at least tier 1")
	eq(result["facts"]["completions"], [ReplayRunner.completion_fact("fixture.challenge.boss_trial", expected)],
		"one completion with the tier the battle reached")
	eq(result["facts"]["bossIds"], ["fixture.enemy.chief"], "the boss is still reported as a boss, separately")


func test_completions_do_not_change_the_hash_and_other_encounters_have_none() -> void:
	var request: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN + "squad-seed-42.json"))
	var result := await replay(request)
	check(not (result["facts"] as Dictionary).has("completions"), "an encounter with no challenge has no completions key")
	var played := await _played("7")
	var battle: Battle = played[0]
	eq((await replay(played[1]))["finalStateHash"], battle.final_hash, "the hash is the one the battle produced")


func test_a_rejected_replay_reports_no_completions() -> void:
	var played := await _played("7")
	var tampered := copy(played[1])
	tampered["actionLog"]["claimedFinalHash"] = "0".repeat(64)
	var result := await replay(tampered)
	eq(result.get("verdict"), "Rejected", "the hash does not match")
	check(not result.has("facts"), "no facts, so no completions, on a rejection")


func test_the_validator_checks_challenges() -> void:
	var good := fixtures().overlay([])
	var codes := func(index: ContentIndex) -> Array:
		return ContentValidator.validate(index, {"tags": false}).filter(func(issue: ValidationIssue) -> bool: return issue.code in ["bad_challenge", "dangling_ref"] and issue.path.contains("challenge")).map(func(issue: ValidationIssue) -> String: return issue.code)
	eq(codes.call(good), [], "the fixture challenge is valid")
	var bad := _challenge("boss/anything", [])
	bad.encounter_id = &"fixture.encounter.nowhere"
	var spaced := _challenge("has space", [_star(ChallengeStar.Kind.TURNS_AT_MOST, 0), null])
	var overlay := fixtures().overlay([bad, spaced])
	var found: Array = ContentValidator.validate(overlay, {"tags": false}).filter(func(issue: ValidationIssue) -> bool: return issue.code in ["bad_challenge", "dangling_ref"]).map(func(issue: ValidationIssue) -> String: return issue.message)
	check(found.any(func(m: String) -> bool: return m.contains("reserved boss/ prefix")), "the boss/ prefix is refused: %s" % [found])
	check(found.any(func(m: String) -> bool: return m.contains("unknown encounter")), "an unknown encounter is refused")
	check(found.any(func(m: String) -> bool: return m.contains("has no stars")), "a challenge with no stars is refused")
	check(found.any(func(m: String) -> bool: return m.contains("no ':' and no whitespace")), "a whitespace id is refused")
	check(found.any(func(m: String) -> bool: return m.contains("allows 0 turns")), "a 0-turn limit is refused")
	check(found.any(func(m: String) -> bool: return m.contains("star 2 of")), "an empty star is refused")
