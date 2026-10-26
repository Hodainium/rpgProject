## Spec playable-demo 3.8 (H9 mirror, H10 per-item scaling): a boss that copies the passives of the party's held items
## and armor and grows once per piece held, rebuilt from the v2 snapshot alone. Fixtures only.
extends TestCase

const BattleV2 := preload("res://tests/combat/test_battle_v2.gd")


## The v2 golden party (the knight holds 3 items, 1 armor piece and 2 use slots) against the fixture mirror boss.
static func mirror_snapshot(seed_text: String = "9") -> Dictionary:
	var snap: Dictionary = BattleV2.v2_snapshot(seed_text)
	snap["battleId"] = "mirror-seed-%s" % seed_text
	snap["encounterId"] = "fixture.encounter.mirror_hall"
	snap["enemies"] = [{"slot": 1, "unitDefId": "fixture.enemy.mirror", "loadoutRef": null, "variantId": null}]
	snap["depth"] = 0
	return snap


## The same battle with the party holding nothing.
static func bare_snapshot() -> Dictionary:
	var snap := mirror_snapshot()
	var party: Array = []
	for member in snap["party"]:
		var bare: Dictionary = member.duplicate()
		bare["equipmentIds"] = []
		bare["items"] = []
		bare["useSlots"] = []
		party.append(bare)
	snap["party"] = party
	return snap


func _boost_stacks(unit: BattleUnit) -> int:
	var count := 0
	for active_effect in unit.asc._active_effects:
		if active_effect.get_effect_def().resource_path.ends_with("per_item_boost.tres"):
			count += 1
	return count


func test_mirror_copies_held_passives() -> void:
	var battle := new_battle(mirror_snapshot())
	var boss := battle.unit_by_id(&"E1")
	var knight := battle.unit_by_id(&"P1")
	var expected: Array = []
	for item_id in ["fixture.item.whetstone", "fixture.item.ember_charm"]:
		var item: ItemDefinition = fixtures().items[StringName(item_id)]
		if item.grants != null:
			for scene in item.grants.abilities:
				expected.append(SkillTags.tag_of(scene))
	for tag in expected:
		check(boss.ability_by_tag(tag) != null, "the boss copied %s" % tag)
		check(knight.ability_by_tag(tag) != null, "the knight still has %s" % tag)
	var feather: ItemDefinition = fixtures().items[&"fixture.item.feather"]
	check(boss.ability_by_tag(SkillTags.tag_of(feather.use_ability)) == null, "use abilities are never copied")
	var bare := new_battle(bare_snapshot())
	check(boss.stat("atk") > bare.unit_by_id(&"E1").stat("atk"), "the copied passives and per-item stacks raise its ATK")


func test_per_item_effect_once_per_piece() -> void:
	var battle := new_battle(mirror_snapshot())
	eq(_boost_stacks(battle.unit_by_id(&"E1")), 6, "3 items + 1 armor piece + 2 use slots = 6 stacks")
	var bare := new_battle(bare_snapshot())
	eq(_boost_stacks(bare.unit_by_id(&"E1")), 0, "nothing held: no stacks")


func test_mirror_record_replay() -> void:
	var request := await record(mirror_snapshot())
	var result := await replay(request)
	eq(result.get("verdict"), "Verified", "the mirror boss is rebuilt from the snapshot on replay")


func test_mirror_on_v1_snapshot() -> void:
	var battle := new_battle(snapshot("mirror_hall", [[1, "sweeper"]], "9"))
	eq(battle.runner_error, "", "a v1 snapshot (no items) builds the mirror boss plainly")
	eq(_boost_stacks(battle.unit_by_id(&"E1")), 0, "and without stacks")
