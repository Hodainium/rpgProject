## Spec playable-demo 6: the demo run "The Descent" on res://content/ (direction only, never tuned numbers, so your
## tuning can't fail it). Skipped when the run isn't built yet (game/tools/build_demo_run.tscn).
extends TestCase

const CONTENT: String = "res://content/"
const DESCENT: StringName = &"demo.run.descent"

var _demo_index: ContentIndex


func _demo() -> ContentIndex:
	if _demo_index == null:
		_demo_index = ContentIndex.new(CONTENT)
	return _demo_index if _demo_index.runs.has(DESCENT) else null


func _party(content: ContentIndex) -> Array:
	var ids: Array = []
	for id in content.characters:
		if content.characters[id].selectable:
			ids.append(String(id))
	ids.sort()
	return ids.slice(0, 2)


func _start(content: ContentIndex, seed_text: String = "1") -> RunController:
	var run := RunController.new()
	host.add_child(run)
	eq(run.start_run(content, _party(content), seed_text), "", "a run of the default run starts")
	return run


## Spec playable-demo 3.8: ten floors, two per chapter up to the Hollow, then a choice of routes at floor 9 and the
## route's end at floor 10. Every floor ends in its chapter's boss; a chapter's two floors meet different bosses; item
## rooms only where the chapter has them (none in the Hollow, the Cathedral and the Coven; four treasure rooms in the
## Vault; three altars in the Void).
func test_demo_run_full_descent() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	eq(RunController.pick_run(content)["run"].id, DESCENT, "The Descent is the default run")
	var structure: RunStructure = content.runs[DESCENT]
	eq(structure.floors.size(), 10, "ten floors")
	var order := ["cellar", "cellar", "crypt", "crypt", "forge", "forge", "hollow", "hollow"]
	for index in order.size():
		eq(structure.floors[index].chapters.map(func(chapter): return chapter.id), [StringName("demo.chapter." + order[index])],
			"floor %d is the %s" % [index + 1, order[index]])
	eq(structure.floors[8].pick, FloorSlot.Pick.CHOICE, "floor 9 is a choice")
	eq(structure.floors[8].chapters.map(func(chapter): return chapter.id), [&"demo.chapter.cathedral", &"demo.chapter.coven"], "light or dark")
	eq(structure.floors[9].pick, FloorSlot.Pick.ROUTE, "floor 10 follows the route")
	var specials := {"cellar": {"Room.Type.Treasure": 1, "Room.Type.Shop": 1}, "crypt": {"Room.Type.Treasure": 1, "Room.Type.Shop": 1},
		"forge": {"Room.Type.Treasure": 1, "Room.Type.Shop": 1}, "hollow": {}, "cathedral": {}, "coven": {},
		"vault": {"Room.Type.Treasure": 4, "Room.Type.Shop": 1}, "void": {"Room.Type.Altar": 3}}
	for route in [&"demo.chapter.cathedral", &"demo.chapter.coven"]:
		for seed_value in range(1, 13):
			var bosses := {}
			for floor_index in 10:
				var result := SeedReport.floor_of(content, seed_value, floor_index, null, DESCENT, route)
				var where := "%s seed %d floor %d" % [route, seed_value, floor_index + 1]
				eq(result["error"], "", where + " generates")
				if result["error"] != "":
					continue
				var name := String(result["chapter"]).trim_prefix("demo.chapter.")
				var chapter: ChapterDefinition = content.chapters[result["chapter"]]
				var map: FloorMap = result["map"]
				var counts := {}
				for index in map.sorted_indices():
					var cell: Dictionary = map.cells[index]
					if cell["role"] == FloorMap.ROLE_SPECIAL:
						counts[String(cell["special_tag"])] = int(counts.get(String(cell["special_tag"]), 0)) + 1
					if cell["role"] == FloorMap.ROLE_BOSS:
						var encounter: EncounterDefinition = content.encounters[cell["content"]["encounter"]]
						check(TagMatch.matches(chapter.boss_encounter_query, encounter.tags),
							where + ": the boss is the chapter's (%s)" % encounter.id)
						if chapter.boss_rotation:
							check(not bosses.has(encounter.id) or bosses[encounter.id] != name, where + ": a new boss in the chapter")
							bosses[encounter.id] = name
				eq(counts, specials[name], where + " (%s): special rooms" % name)
	var crypt: Dictionary = SeedReport.many(content, 1, 30, 2)["encounters"]
	for id in ["demo.encounter.crypt_guard", "demo.encounter.wisp_choir", "demo.encounter.ember_watch",
			"demo.encounter.bound_dead"]:
		check(crypt.has(id), "%s appears on the Crypt in 30 seeds" % id)


## The auto policy plays whole runs to an end (won or lost; never a runner error, a dead end or the step cap), and a
## run that beats the Golem takes the stairs.
func test_demo_run_completes() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	var report := await PlayReport.many(content, host, 1, 10, {"check": true})
	eq(report["stopped"], 0, "every run ends")
	eq(report["violations"], [], "every battle replays Verified and breaks no invariant")
	for record in report["runs"]:
		check(record["status"] in [RunState.WON, RunState.LOST], "seed %d ends won or lost" % record["seed"])
		if record["status"] == RunState.WON:
			eq(record["floorReached"], 2, "seed %d: a won run cleared both floors" % record["seed"])


func test_demo_events() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	# Cursed chest: an item arrives and the party loses HP.
	var run := _start(content)
	var hp_before := _party_hp(run)
	var held_before := _held(run)
	_open(run, &"demo.event.cursed_chest")
	eq(run.choose(0), "", "open the chest")
	check(_held(run) > held_before, "the chest gives an item")
	check(_party_hp(run) < hp_before, "the chains take HP")
	run.free()
	# Wounded knight: paying needs 15 coins and gives the helm; challenging starts the duel.
	run = _start(content)
	_open(run, &"demo.event.wounded_knight")
	check(not run.choice_enabled(0), "paying needs 15 coins")
	run.add_coins(15)
	eq(run.choose(0), "", "pay")
	eq(run.state.coins, 0, "15 coins paid")
	check(run.state.armor.has(&"demo.equipment.warden_helm"), "the helm goes to the armor inventory (D9: never worn on its own)")
	eq(run.state.event.get("page"), 1, "the thank-you page")
	run.free()
	run = _start(content)
	_open(run, &"demo.event.wounded_knight")
	eq(run.choose(1), "", "challenge him")
	eq(run.pending_battle.get("encounter"), &"demo.encounter.knight_duel", "the duel starts")
	run.free()
	# Librarian: read, then take one of two books.
	run = _start(content)
	held_before = _held(run)
	_open(run, &"demo.event.librarian")
	eq(run.choose(0), "", "look at the books")
	eq(run.state.event.get("page"), 1, "the books page")
	eq(run.choose(1), "", "take the Hourglass")
	eq(_held(run), held_before + 1, "one book is taken")
	run.free()


func _open(run: RunController, event_id: StringName) -> void:
	run.state.event = {"cell": run.state.current_cell, "event": event_id, "page": 0}


func _held(run: RunController) -> int:
	var count := 0
	for member in run.state.party:
		count += member["items"].size() + member["use_slots"].size()
	return count


func _party_hp(run: RunController) -> int:
	var total := 0
	var stats := run.party_stats()
	for slot in stats:
		total += int(stats[slot].get(BattleUnit.HP, 0))
	return total


## Puts a battle against `encounter_id` in the run's current room (bypasses the map so the test picks the fight).
func _inject(run: RunController, encounter_id: StringName) -> void:
	var encounter: EncounterDefinition = run.content.encounters[encounter_id]
	var generator := FloorGenerator.new(run.content, run.structure, run.state.run_seed, run.state.floor_index)
	var enemies: Array = generator.resolve_enemies(encounter, null, false, null, RunSeeds.rng(1, "test"))
	run.state.map.cells[run.state.current_cell]["content"]["enemies"] = enemies
	run.pending_battle = {"cell": run.state.current_cell, "encounter": encounter.id, "enemies": enemies, "label": "/test"}


## Spec playable-demo 3.7: the Wisp choir drains Ice, Bound dead's first Toad lashes with Entangle (its row delay
## fires), and beating the wounded knight drops his helm into the armor inventory.
func test_demo_encounter_features() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	var run := _start(content)
	_inject(run, &"demo.encounter.wisp_choir")
	var battle := Battle.new()
	host.add_child(battle)
	eq(battle.setup(run.battle_snapshot(), content), "", "the Wisp choir builds")
	for unit in battle.units():
		if not unit.is_party():
			check(unit.asc.has_tag_exact(&"Drain.Ice"), "%s drains Ice (the encounter's grant)" % unit.unit_id)
	battle.free()
	_inject(run, &"demo.encounter.bound_dead")
	battle = Battle.new()
	host.add_child(battle)
	eq(battle.setup(run.battle_snapshot(), content), "", "Bound dead builds")
	var lasher := battle.unit_by_id(&"E1")
	check(lasher.ability_by_tag(&"Ability.Entanglelash") != null, "the first Toad has Entangle Lash")
	check(battle.unit_by_id(&"E3").ability_by_tag(&"Ability.Entanglelash") == null, "the other Toad does not")
	check(lasher.brain_override is PatternBrain, "and its slot's PatternBrain")
	var delays := [0]
	battle.action_delayed.connect(func(_unit, percent): if percent > 0: delays[0] += 1)
	# The party usually kills it first, so its turn is taken directly: the pattern opens with Entangle Lash.
	var action: Dictionary = await battle._take_action(lasher, ScriptedController.new())
	eq(action.get("ability"), &"Ability.Entanglelash", "its pattern opens with Entangle Lash")
	check(delays[0] > 0, "Entangle Lash's row delay pushes the target's turn back")
	battle.free()
	run.free()
	var duel := _start(content)
	_inject(duel, &"demo.encounter.knight_duel")
	await duel.fight(_KillFirst.new())
	check(duel.state.armor.has(&"demo.equipment.warden_helm"), "the duel's reward helm is in the armor inventory")
	duel.free()


class _KillFirst extends ScriptedController:
	var _done := false

	func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
		if not _done:
			_done = true
			return {"dev": &"Dev.Kill", "effect": RunController.dev_effect("dev_kill"), "targets": "enemies"}
		return super(battle, unit)


## Spec playable-demo 3.8: the Void's altars offer only corrupted items, each costing a Void Scar; the Collector
## mirrors the build and the Nameless does not.
func test_demo_endings() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	var priced := 0
	for seed_value in range(1, 11):
		var result := SeedReport.floor_of(content, seed_value, 9, null, DESCENT, &"demo.chapter.coven")
		eq(result["chapter"], &"demo.chapter.void", "seed %d: the dark route ends in the Void" % seed_value)
		var map: FloorMap = result["map"]
		for index in map.sorted_indices():
			for pickup in map.cells[index]["pickups"]:
				if not pickup.has("priceItem"):
					continue
				priced += 1
				eq(pickup["priceItem"], &"demo.item.void_scar", "an altar costs a Void Scar")
				var entry: Resource = content.items.get(pickup["item"], content.equipment.get(pickup["item"]))
				check(entry != null and (entry.tags.has(&"Item.Corrupted") or entry.id == &"demo.item.stale_bread"),
					"an altar offers a corrupted item (%s)" % pickup["item"])
	eq(priced, 60, "3 altars × 2 pedestals × 10 seeds")
	check(content.units[&"demo.enemy.collector"].mirror_party_items, "the Collector mirrors the build")
	check(content.units[&"demo.enemy.collector"].per_item_effect != null, "and grows per piece held")
	check(not content.units[&"demo.enemy.nameless"].mirror_party_items, "the Nameless does not")
	var corrupted := content.items.values().filter(func(item) -> bool: return item.tags.has(&"Item.Corrupted")).size() \
		+ content.equipment.values().filter(func(piece) -> bool: return piece.tags.has(&"Item.Corrupted")).size()
	eq(corrupted, 15, "fifteen corrupted items")


## Spec playable-demo 3.9 (D22): Immune.<Status> refuses that status, Immune.Debuff refuses every debuff, through each
## debuff effect's application_query; Vein Cloak makes its wearer immune to Bleed.
func test_demo_status_immunity() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	var run := _start(content)
	_inject(run, &"demo.encounter.slime_pair")
	var battle := Battle.new()
	host.add_child(battle)
	eq(battle.setup(run.battle_snapshot(), content), "", "a battle builds")
	var bleed: GameplayEffect = load("res://content/demo/effects/bleed.tres")
	var poison: GameplayEffect = load("res://content/demo/effects/poison.tres")
	var first := battle.unit_by_id(&"E1")
	var second := battle.unit_by_id(&"E2")
	first.asc.add_tag(&"Immune.Bleed")
	for unit in [first, second]:
		unit.asc.apply_gameplay_effect(bleed, unit.asc, 1)
		unit.asc.apply_gameplay_effect(poison, unit.asc, 1)
	var tags := func(unit: BattleUnit) -> Array: return unit.statuses().map(func(status): return status["tag"])
	check(not tags.call(first).has("Status.Debuff.Bleed"), "Immune.Bleed refuses Bleed")
	check(tags.call(first).has("Status.Debuff.Poison"), "but not Poison")
	check(tags.call(second).has("Status.Debuff.Bleed"), "a unit without the tag bleeds")
	second.asc.add_tag(&"Immune.Debuff")
	second.asc.apply_gameplay_effect(load("res://content/demo/effects/weaken.tres"), second.asc, 1)
	check(not tags.call(second).has("Status.Debuff.Weaken"), "Immune.Debuff refuses every debuff")
	battle.free()
	run.free()
	var cloak: EquipmentDefinition = content.equipment[&"demo.equipment.vein_cloak"]
	check(cloak.grants.effects.any(func(effect) -> bool: return effect.granted_tags.has(&"Immune.Bleed")),
		"Vein Cloak grants Immune.Bleed")
