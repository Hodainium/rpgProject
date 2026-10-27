## Spec skill-points, content test on res://content/: the demo classes gain SP on basics, rank their innate skill at
## levels 5 and 9, learn passives at 3 and 7, and enemies reach secret skills by level (an Elite +2).
extends TestCase

const CONTENT: String = "res://content/"
const DESCENT: StringName = &"demo.run.descent"

static var _demo_index: ContentIndex


func _demo() -> ContentIndex:
	if _demo_index == null:
		_demo_index = ContentIndex.new(CONTENT)
	return _demo_index if _demo_index.runs.has(DESCENT) else null


func _battle(content: ContentIndex, character: String, level: int, enemies: Array, depth: int = 0) -> Battle:
	var snap := {"schemaVersion": 2, "battleId": "demo-sp", "seed": "3", "encounterId": "demo.encounter.golem",
		"party": [{"slot": 1, "unitDefId": character, "level": level, "skills": [], "equipmentIds": [], "items": [],
			"useSlots": []}], "enemies": enemies, "scalingId": "demo.scaling.descent", "depth": depth}
	var battle := Battle.new()
	host.add_child(battle)
	eq(battle.setup(snap, content), "", "the battle builds")
	return battle


func test_demo_ranks_and_passives() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	var golem := [{"slot": 1, "unitDefId": "demo.enemy.golem", "loadoutRef": null, "variantId": null}]
	var low := _battle(content, "demo.character.cleric", 1, golem)
	var cleric := low.unit_by_id(&"P1")
	check(cleric.ability_by_tag(&"Ability.Heal") != null, "level 1: Heal")
	eq(cleric.stat("sp_basic"), 1300, "the Cleric's 13 SP per basic")
	low.free()
	var high := _battle(content, "demo.character.cleric", 9, golem)
	cleric = high.unit_by_id(&"P1")
	check(cleric.ability_by_tag(&"Ability.Massheal") != null, "level 9: Mass Heal")
	check(cleric.ability_by_tag(&"Ability.Heal") == null and cleric.ability_by_tag(&"Ability.Greaterheal") == null,
		"the earlier ranks are replaced")
	check(cleric.ability_by_tag(&"Ability.Passive.Secondwind") != null and cleric.ability_by_tag(&"Ability.Passive.Grace") != null,
		"both passives")
	eq(cleric.stat("level"), 900, "the read-only level")
	high.free()
	var warrior := _battle(content, "demo.character.warrior", 3, golem)
	check(warrior.unit_by_id(&"P1").ability_by_tag(&"Ability.Iceblast") != null, "the Warrior learns Ice Blast at 3")
	warrior.free()
	var start := _battle(content, "demo.character.warrior", 1, golem)
	check(start.unit_by_id(&"P1").ability_by_tag(&"Ability.Iceblast") == null, "and doesn't start with it")
	start.free()


func test_demo_secret_skills() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	var plain := _battle(content, "demo.character.warrior", 1,
		[{"slot": 1, "unitDefId": "demo.enemy.golem", "loadoutRef": null, "variantId": null}])
	check(plain.unit_by_id(&"E1").ability_by_tag(&"Ability.Tremor") == null, "a floor-1 Golem has no Tremor")
	plain.free()
	var elite := _battle(content, "demo.character.warrior", 1,
		[{"slot": 1, "unitDefId": "demo.enemy.golem", "loadoutRef": null, "variantId": "demo.variant.elite"}])
	eq(elite.unit_by_id(&"E1").level, 3, "an Elite is 2 levels up")
	check(elite.unit_by_id(&"E1").ability_by_tag(&"Ability.Tremor") != null, "and knows Tremor")
	elite.free()
	var deep := _battle(content, "demo.character.warrior", 1,
		[{"slot": 1, "unitDefId": "demo.enemy.golem", "loadoutRef": null, "variantId": null}], 4)
	eq(deep.unit_by_id(&"E1").level, 5, "floor 5: level 5")
	deep.free()


## The turn-limit traces: a Cryomancer with no SP for its skills against Void Wraiths (Drain Ice) used to Frost Jab
## forever, healing them. Auto now guards instead of feeding a drain.
func test_auto_never_feeds_a_drain() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	var wraiths := [{"slot": 1, "unitDefId": "demo.enemy.void_wraith", "loadoutRef": null, "variantId": null},
		{"slot": 2, "unitDefId": "demo.enemy.void_wraith", "loadoutRef": null, "variantId": null}]
	var battle := _battle(content, "demo.character.cryomancer", 1, wraiths)
	var cryo := battle.unit_by_id(&"P1")
	cryo.asc.initialize_attribute_overrides({"mp": 0.0})
	var pick := AutoPolicy.new(AutoPolicy.Options.new(), content).choose(battle, cryo)
	check(pick["ability"] != &"Ability.Frostjab", "no Frost Jab into a drain (picked %s)" % pick["ability"])
	eq(pick["ability"], &"Ability.Block", "it guards")
	battle.free()


## The stalled seed 956910: a "safe" move with no target (a revive with nobody down) must not end the search, or Auto
## hands back an empty pick and a headless run waits forever.
func test_auto_last_resort_skips_targetless_moves() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	var snap := {"schemaVersion": 2, "battleId": "demo-sp", "seed": "3", "encounterId": "demo.encounter.wraiths",
		"party": [{"slot": 1, "unitDefId": "demo.character.cryomancer", "level": 1, "skills": [], "equipmentIds": [],
			"items": [], "useSlots": [{"itemId": "demo.item.phoenix_feather", "ready": true}]}],
		"enemies": [{"slot": 1, "unitDefId": "demo.enemy.void_wraith", "loadoutRef": null, "variantId": null}],
		"scalingId": "demo.scaling.descent", "depth": 0}
	var battle := Battle.new()
	host.add_child(battle)
	eq(battle.setup(snap, content), "", "the battle builds")
	var cryo := battle.unit_by_id(&"P1")
	cryo.asc.initialize_attribute_overrides({"mp": 0.0})
	var options := AutoPolicy.Options.new()
	options.consumables = true
	var pick := AutoPolicy.new(options, content).choose(battle, cryo)
	check(not pick.is_empty() and pick["ability"] != &"", "Auto always returns a move")
	eq(pick["ability"], &"Ability.Block", "and guards rather than feed the drain")
	battle.free()
