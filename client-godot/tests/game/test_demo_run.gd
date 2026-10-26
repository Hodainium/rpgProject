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


## Spec playable-demo 4: each floor draws from its own seed stream (`floor/<n>/…`). A chapter's two floors share the
## chapter, so if the second reused the first's stream they would come out identical: for the same seed, the Cellar's
## floors 1 and 2 (and the Crypt's 3 and 4) differ in layout, rooms, encounters, enemies or pickups.
func test_demo_floors_differ_per_seed() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	for seed_value in range(1, 21):
		for first in [0, 2]:
			var a := SeedReport.floor_of(content, seed_value, first, null, DESCENT)
			var b := SeedReport.floor_of(content, seed_value, first + 1, null, DESCENT)
			var where := "seed %d floors %d and %d" % [seed_value, first + 1, first + 2]
			eq([a["error"], b["error"]], ["", ""], where + " generate")
			if a["error"] != "" or b["error"] != "":
				continue
			eq(a["chapter"], b["chapter"], where + " share a chapter")
			check(_floor_signature(a["map"]) != _floor_signature(b["map"]), where + " differ")


## A floor's shape and contents (cells, roles, rooms, encounters, enemies, pickups); never stats, so depth scaling
## alone can't make two floors differ.
func _floor_signature(map: FloorMap) -> String:
	var lines := PackedStringArray()
	for index in map.sorted_indices():
		var cell: Dictionary = map.cells[index]
		lines.append("%d %s %s %s %s" % [index, cell["role"], cell.get("room", ""), var_to_str(cell.get("content", {})),
			var_to_str(cell.get("pickups", []))])
	return "\n".join(lines)


## Spec playable-demo 4 and 3.6: the battle speed is presentation only. The same seed and the same (auto) choices
## give the same battle and run hash with animations skipped, at 1× and at 2×, played through GameMain with the demo
## views and the battle panel's own Skip and Speed buttons; at 1× and 2× the gate waits on the animations' execute
## keys while Engine.time_scale runs at that speed.
func test_demo_battle_speed_keeps_combat() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	var skipped := await _speed_run(0.0)
	var normal := await _speed_run(1.0)
	var fast := await _speed_run(2.0)
	eq(skipped["error"], "", "the skipped run fights")
	eq(normal["error"], "", "the 1× run fights")
	eq(fast["error"], "", "the 2× run fights")
	eq(normal["timeScale"], 1.0, "the 1× battle plays at time scale 1")
	eq(fast["timeScale"], 2.0, "the 2× battle plays at time scale 2")
	check(not normal["skipAll"] and not fast["skipAll"], "both wait on the animations")
	eq(normal["finalHash"], skipped["finalHash"], "1× fights the same battle as no animations")
	eq(fast["finalHash"], normal["finalHash"], "2× fights the same battle as 1×")
	eq(fast["runHash"], normal["runHash"], "and the run hash is the same")
	eq(skipped["runHash"], normal["runHash"], "with or without animations")


## Plays the first battle next to the start of the first seed that has one: `speed` 0 skips animations, else the
## battle panel's Skip is off and Speed is pressed until Engine.time_scale is `speed`. Never writes settings.
func _speed_run(speed: float) -> Dictionary:
	var result := {"error": "", "finalHash": "", "runHash": "", "timeScale": 0.0, "skipAll": true}
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = speed == 0.0
	host.add_child(game)
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)  # built-ins only: user://dev_commands/ is shared with parallel shards
	console.attach(game)
	console.auto_battle = true
	var cell := -1
	for seed_value in range(1, 31):
		result["error"] = game.start_run(_party(game.content), str(seed_value), DESCENT)
		if result["error"] != "":
			break
		cell = _next_battle(game.run)
		if cell >= 0:
			break
	if result["error"] == "" and cell < 0:
		result["error"] = "no seed in 1–30 has a battle next to the start"
	if result["error"] == "":
		var run := game.run
		# Runs before the panel's own battle_started handler, which then applies the speed the label shows.
		run.battle_started.connect(func(battle: Battle) -> void:
			if speed > 0.0:
				var skip := game.find_child("Skip", true, false) as BaseButton
				var faster := game.find_child("Speed", true, false) as Button
				if skip != null:
					skip.button_pressed = false
				for press in 3:
					if faster == null or faster.text == "%d×" % int(speed):
						break
					faster.pressed.emit()
			battle.turn_started.connect(func(_unit, _turn) -> void:
				result["timeScale"] = Engine.time_scale
				result["skipAll"] = game.gate.skip_all, CONNECT_ONE_SHOT))
		result["error"] = run.enter_room(cell)
		if result["error"] == "":
			await run.battle_finished
			var battles := run.run_log.filter(func(entry: Dictionary) -> bool: return entry["type"] == "battle")
			result["finalHash"] = battles[-1]["finalHash"] if not battles.is_empty() else ""
			result["runHash"] = run.state.run_hash()
	game.queue_free()
	await host.get_tree().process_frame
	Engine.time_scale = 1.0
	return result


## A normal battle room the run can enter from where it stands, or -1.
func _next_battle(run: RunController) -> int:
	for index in run.state.map.sorted_indices():
		var data: Dictionary = run.state.map.cells[index]
		if run.can_enter(index) and data["role"] != FloorMap.ROLE_BOSS and data["content"]["kind"] == "encounter":
			return index
	return -1


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
			eq(record["floorReached"], content.runs[DESCENT].floors.size(), "seed %d: a won run cleared every floor" % record["seed"])


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


## Spec playable-demo 3.11 (D29, D30): the healing events, the Old Tutor and the Waystation rest stop do what their
## text says (direction only: HP up, the fallen up, a level or XP more, coins as named).
func test_demo_c6_events() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	# Healing Spring: drinking heals; bathing needs 10 coins, takes them and heals more than drinking.
	var run := _start(content)
	_hurt(run)
	var hurt_hp := _party_hp(run)
	_open(run, &"demo.event.healing_spring")
	check(not run.choice_enabled(1), "bathing needs 10 coins")
	eq(run.choose(0), "", "drink")
	var drunk_hp := _party_hp(run)
	check(drunk_hp > hurt_hp, "drinking heals")
	run.free()
	run = _start(content)
	_hurt(run)
	run.add_coins(10)
	_open(run, &"demo.event.healing_spring")
	eq(run.choose(1), "", "bathe")
	eq(run.state.coins, 0, "10 coins paid")
	check(_party_hp(run) > drunk_hp, "bathing heals more than drinking")
	run.free()
	# Wandering Medic: needs 15 coins; full heal and the fallen get up.
	run = _start(content)
	_hurt(run, true)
	_open(run, &"demo.event.wandering_medic")
	check(not run.choice_enabled(0), "the medic needs 15 coins")
	run.add_coins(15)
	eq(run.choose(0), "", "pay the medic")
	eq(run.state.coins, 0, "15 coins paid")
	check(run.state.party.all(func(member: Dictionary) -> bool: return member["alive"]), "the fallen get up")
	var stats := run.party_stats()
	for slot in stats:
		eq(stats[slot][BattleUnit.HP], stats[slot][BattleUnit.MAX_HP], "member %d fully healed" % slot)
	run.free()
	# Old Tutor: the lesson gives everyone a level; the purse gives XP and 10 coins.
	run = _start(content)
	var levels := _levels(run)
	_open(run, &"demo.event.old_tutor")
	eq(run.choose(0), "", "take the lesson")
	for index in levels.size():
		eq(run.state.party[index]["level"], levels[index] + 1, "member %d gains a level" % run.state.party[index]["slot"])
	run.free()
	run = _start(content)
	var xp_before: Array = run.state.party.map(func(member: Dictionary) -> int: return int(member.get("xp", 0)))
	_open(run, &"demo.event.old_tutor")
	eq(run.choose(1), "", "take the purse")
	eq(run.state.coins, 10, "10 coins")
	for index in xp_before.size():
		check(int(run.state.party[index].get("xp", 0)) > xp_before[index], "member %d gains XP" % run.state.party[index]["slot"])
	run.free()
	# Waystation (The Descent's rest stop): rest heals HP and MP and raises the fallen; train gives a level; move on
	# changes nothing.
	run = _start(content)
	eq(run.structure.rest_event.id, &"demo.event.waystation", "the Waystation is the rest stop between floors")
	_hurt(run, true)
	hurt_hp = _party_hp(run)
	var hurt_mp := _party_mp(run)
	_open(run, &"demo.event.waystation")
	eq(run.choose(0), "", "rest")
	check(_party_hp(run) > hurt_hp, "resting heals")
	check(_party_mp(run) > hurt_mp, "resting restores MP")
	check(run.state.party.all(func(member: Dictionary) -> bool: return member["alive"]), "the fallen get up")
	run.free()
	run = _start(content)
	levels = _levels(run)
	_open(run, &"demo.event.waystation")
	eq(run.choose(1), "", "train")
	eq(_levels(run), levels.map(func(level: int) -> int: return level + 1), "everyone gains a level")
	run.free()
	run = _start(content)
	_hurt(run)
	var hp_before := _party_hp(run)
	_open(run, &"demo.event.waystation")
	eq(run.choose(2), "", "move on")
	eq(_party_hp(run), hp_before, "moving on heals nobody")
	eq(_levels(run), levels, "and trains nobody")
	run.free()


## Every member down to 10% HP and no MP; with `one_down`, the last member has fallen.
func _hurt(run: RunController, one_down: bool = false) -> void:
	var stats := run.party_stats()
	for member in run.state.party:
		member["hp"] = int(stats[member["slot"]][BattleUnit.MAX_HP]) / 10
		if member["mp"] != null:
			member["mp"] = 0
	if one_down:
		var last: Dictionary = run.state.party[run.state.party.size() - 1]
		last["hp"] = 0
		last["alive"] = false
	check(_party_hp(run) < _party_max_hp(run), "the party is hurt before the event")
	if one_down:
		check(run.party_stats().size() == run.state.party.size() and not run.state.party.all(
			func(member: Dictionary) -> bool: return member["alive"]), "a member is down before the event")


func _party_max_hp(run: RunController) -> int:
	var total := 0
	var stats := run.party_stats()
	for slot in stats:
		total += int(stats[slot].get(BattleUnit.MAX_HP, 0))
	return total


func _levels(run: RunController) -> Array:
	return run.state.party.map(func(member: Dictionary) -> int: return int(member["level"]))


func _party_mp(run: RunController) -> int:
	var total := 0
	var stats := run.party_stats()
	for slot in stats:
		total += int(stats[slot].get(BattleUnit.MP, 0))
	return total


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
