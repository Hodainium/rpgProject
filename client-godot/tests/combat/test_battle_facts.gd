## Spec settlement-outbox 3.1: the replay runner emits BattleFacts (encounter, bosses, party), computed in Godot and
## never hashed; a rejected replay has none.
extends TestCase


func test_a_boss_battle_reports_its_boss_and_party() -> void:
	var request: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN + "boss-seed-5.json"))
	var result := await replay(request)
	eq(result.get("verdict"), "Verified", "verdict")
	var facts: Dictionary = result.get("facts", {})
	eq(facts.get("encounterId"), "fixture.encounter.lich_court", "encounter")
	eq(facts.get("bossIds"), ["fixture.enemy.lich"], "the Enemy.Boss enemy")
	check(not (facts.get("partyCharacterIds", []) as Array).is_empty(), "party ids")


func test_an_ordinary_battle_has_no_bosses() -> void:
	var request: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN + "squad-seed-42.json"))
	var result := await replay(request)
	eq(result["facts"]["bossIds"], [], "no boss")
	eq(result["facts"]["encounterId"], "fixture.encounter.squad", "encounter")


func test_party_ids_are_distinct_and_facts_do_not_change_the_hash() -> void:
	var request: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN + "run-v2-seed-7.json"))
	var result := await replay(request)
	var ids: Array = result["facts"]["partyCharacterIds"]
	var seen := {}
	for id in ids:
		check(not seen.has(id), "%s listed once" % id)
		seen[id] = true
	var committed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN + "run-v2-seed-7.result.json"))
	eq(result["finalStateHash"], committed["finalStateHash"], "hash unchanged")


func test_a_rejected_replay_has_no_facts() -> void:
	var request: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN + "squad-seed-42-tampered-target.json"))
	var result := await replay(request)
	eq(result.get("verdict"), "Rejected", "verdict")
	check(not result.has("facts"), "no facts on a rejection")


## A lost battle verifies as a Defeat and must not read as a boss kill: bossIds names the bosses BEATEN.
func test_a_lost_boss_battle_names_no_boss() -> void:
	var snap: Dictionary = preload("res://tests/combat/test_bosses.gd").boss_snapshot("5")
	for member in snap["party"]:
		member["hp"] = 100  # one hit point: the lich court wins
	var request: Dictionary = await record(snap)
	var result := await replay(request)
	eq(result.get("verdict"), "Verified", "a lost battle still verifies")
	eq(result.get("outcome"), "Defeat", "the party lost")
	eq(result["facts"]["bossIds"], [], "no boss beaten")
	eq(result["facts"]["encounterId"], "fixture.encounter.lich_court", "the encounter is still named")


## Two Enemy.Boss slots of the same definition and a second boss: each boss id is listed once, in unit order, and only
## once the party has won (a duplicate would pay a completion mark twice).
func test_bosses_are_listed_once_each() -> void:
	var content := ContentIndex.new(FIXTURES)
	var court: EncounterDefinition = content.encounters[&"fixture.encounter.lich_court"]
	var boss_slot: EncounterSlot = court.slots[0]
	var twins := court.duplicate() as EncounterDefinition
	twins.id = &"fixture.encounter.twin_liches"
	twins.slots = [boss_slot, boss_slot.duplicate() as EncounterSlot, (content.encounters[&"fixture.encounter.boss"] as EncounterDefinition).slots[0]]
	content.encounters[twins.id] = twins
	var snap: Dictionary = preload("res://tests/combat/test_bosses.gd").boss_snapshot("5")
	snap["encounterId"] = "fixture.encounter.twin_liches"
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	eq(battle.setup(snap, content), "", "the twin court sets up")
	var enemies := battle.units().filter(func(unit: BattleUnit) -> bool: return unit.side == BattleUnit.Side.ENEMY)
	eq(enemies.size(), 3, "three enemies fight")
	var runner := ReplayRunner.new()
	battle.outcome = "Victory"
	var facts: Dictionary = runner._facts(battle, str(snap["encounterId"]))
	var bosses: Array = facts["bossIds"]
	bosses.sort()
	eq(bosses, ["fixture.enemy.chief", "fixture.enemy.lich"], "each boss once")
	battle.outcome = "Defeat"
	eq(runner._facts(battle, "x")["bossIds"], [], "none after a defeat")


## Spec economy-challenges 3.1: a replay that completes a challenge reports `completions` as {challengeId, tier} entries, the
## same JSON the C# `CompletionFact` golden pins. Nothing in the game defines a challenge yet, so a runner subclass stands in
## for the future challenge definition and overrides the `_completions` seam.
class _TrialRunner extends ReplayRunner:
	func _completions(_battle: Battle, _encounter_id: String) -> Array:
		return [ReplayRunner.completion_fact("event.spring.trial-3", 3)]


func _won_boss_battle() -> Battle:
	var snap: Dictionary = preload("res://tests/combat/test_bosses.gd").boss_snapshot("5")
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	eq(battle.setup(snap, ContentIndex.new(FIXTURES)), "", "the court sets up")
	battle.outcome = "Victory"
	return battle


func test_a_battle_with_no_challenge_reports_no_completions_key() -> void:
	var request: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN + "boss-seed-5.json"))
	var result := await replay(request)
	check(not (result["facts"] as Dictionary).has("completions"), "no key at all, so every fact written before stays byte-identical")
	eq((result["facts"] as Dictionary).keys(), ["encounterId", "bossIds", "partyCharacterIds"], "the slice 4 shape")


func test_completions_use_the_wire_shape_the_server_reads() -> void:
	if skip_in_export():
		return
	var facts: Dictionary = _TrialRunner.new()._facts(_won_boss_battle(), "fixture.encounter.lich_court")
	var golden: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		ProjectSettings.globalize_path("res://").path_join("../tests/Rpg.Contracts.Tests/golden/battle-facts-completions.json")))
	eq(WireJson.stringify(facts["completions"]), WireJson.stringify(golden["completions"]),
		"the C# golden for BattleFacts.Completions, byte for byte")
	eq(facts.keys(), ["encounterId", "bossIds", "partyCharacterIds", "completions"], "added after the slice 4 keys")
	var tier: Variant = (facts["completions"] as Array)[0]["tier"]
	check(typeof(tier) == TYPE_INT, "a tier is a whole number")
	check(WireJson.stringify(facts).contains("\"tier\":3"), "and is written as an integer: " + WireJson.stringify(facts))


func test_a_lost_battle_reports_no_completions() -> void:
	var battle := _won_boss_battle()
	battle.outcome = "Defeat"
	var facts: Dictionary = _TrialRunner.new()._facts(battle, "x")
	check(not facts.has("completions"), "a challenge is completed by winning")
