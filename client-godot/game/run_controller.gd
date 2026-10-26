## Drives one run (spec game-skeleton, section 2). Holds no UI: screens call its methods and listen to its signals.
##
## Every change to run state goes through a method here, is logged in run_log, and draws only from the run's seeded
## streams (RunSeeds), so a seed plus the same choices always gives the same run. Event outcomes and item hooks
## (RunOutcome subclasses) call the public "outcome API" methods below.
class_name RunController
extends Node

signal run_started
signal floor_entered(floor_index: int)
signal room_entered(cell: int)
## A battle is ready: the screen shows the room, then calls fight() with its controller and gate.
signal battle_requested(snapshot: Dictionary)
signal battle_started(battle: Battle)
signal battle_finished(outcome: String)
signal event_page_shown(event_id: StringName, page: int)
signal pickups_shown(cell: int)
signal party_changed
signal room_cleared(cell: int)
signal run_ended(status: String)
## The run stopped on a runner error (broken content; not a loss). Its text also goes out as a Notification.
signal stopped(error: String)
## The console's `reveal` (spec dev-tools 3.2): the map view should show every room.
signal map_revealed

var content: ContentIndex
var structure: RunStructure
var state: RunState
var run_log: Array[Dictionary] = []
var warnings := PackedStringArray()
## Set when content is broken mid-run (a runner error). The run stops; it is not a loss.
var runner_error: String = ""
## Local mode: battles accept dev decisions (spec dev-tools 3.6). Slice 2 turns it off when connected.
var allow_dev: bool = true
## The battle waiting for fight(): {"cell", "encounter", "enemies", "label"}.
var pending_battle: Dictionary = {}
## The last battle's events (see _record_battle), for the dev report.
var battle_log: Array[Dictionary] = []
## The item whose run hook is running (null otherwise); an empty RemoveItem in a hook removes it.
var hook_item: ItemDefinition
## Spec playable-demo 3.1: what run_summary() can't read from the log (coins in and out, enemies beaten). Never hashed.
var _tally: Dictionary = {}

var _directive: String = ""
var _directive_page: int = 0
var _directive_encounter: EncounterDefinition


# --- Run and floors -------------------------------------------------------------------------------------------------

## Starts a run with 1-4 characters (ids of CharacterDefinitions) and a seed typed as a decimal string or seed code.
## `run_id` names the RunStructure; empty picks it as pick_run() does (spec playable-demo 2.2).
func start_run(content_index: ContentIndex, character_ids: Array, seed_text: String, run_id: StringName = &"") -> String:
	var error := _begin_run(content_index, character_ids, seed_text, run_id)
	if error != "":
		return error
	run_started.emit()
	_send(GameplayMessageRouter.RUN_STARTED, &"Verb.Start", &"", structure.id)
	return enter_floor(0)


## Plays one room or one hand-made floor (spec dev-tools 2.2) with a fresh party. Unsaved or in-memory content in the
## request is played as it is (through a ContentIndex overlay); the run is marked dev and sandbox.
func start_sandbox(content_index: ContentIndex, request: SandboxRequest) -> String:
	var extra: Array = []
	for resource in [request.room, request.encounter, request.event, request.layout]:
		if resource != null and resource.get("id") != &"":
			extra.append(resource)
	if request.room == null and request.layout == null:
		return _stop("a sandbox needs a room or a layout")
	if request.room != null and request.room.id == &"":
		return _stop("the room needs an id before it can be played")
	var error := _begin_run(content_index.overlay(extra), request.party, str(request.seed), &"", true)
	if error != "":
		return error
	state.sandbox = true
	state.dev = true
	run_log.append({"type": "sandbox", "room": String(request.room.id) if request.room != null else "",
		"layout": String(request.layout.id) if request.layout != null else "", "depth": request.depth,
		"chapter": String(request.chapter_id), "seed": str(request.seed)})
	run_started.emit()
	_send(GameplayMessageRouter.RUN_STARTED, &"Verb.Start", &"", structure.id, 0, [], {"sandbox": true})
	return enter_sandbox_floor(request)


## Replaces the current floor with a sandbox floor (the console's `room` / `layout` inside a running game, or a new
## sandbox run). Party and inventory are kept.
func enter_sandbox_floor(request: SandboxRequest) -> String:
	var chapter := _sandbox_chapter(request)
	if chapter == null:
		return _stop("the content has no chapter for the sandbox")
	_reset_floor(request.depth, chapter)
	var pools := _pools()
	var generator := FloorGenerator.new(content, structure, state.run_seed, request.depth)
	var result: Dictionary
	if request.layout != null:
		result = generator.from_layout(request.layout, chapter, pools)
	else:
		result = generator.single_room(request.room, chapter, pools, request.encounter, request.event)
	if result["error"] != "":
		return _stop("sandbox: %s" % result["error"])
	_install_floor(result["map"], pools, request.layout != null)
	if request.room != null and runner_error == "":
		_enter_cell(state.map.start)
	return runner_error


func _sandbox_chapter(request: SandboxRequest) -> ChapterDefinition:
	if request.chapter_id != &"":
		return content.chapters.get(request.chapter_id)
	var ids := content.chapters.keys()
	ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	if request.room != null:
		for id in ids:
			if TagMatch.matches(content.chapters[id].room_query, request.room.tags):
				return content.chapters[id]
	return content.chapters[ids[0]] if not ids.is_empty() else null


## The RunStructure to start (spec playable-demo 2.2): `run_id` when given; else the only run; else the one flagged
## default_run. `lenient` (sandboxes, which only need a run's slots and fallback item) falls back to the first id.
## {"run": RunStructure or null, "error": String}.
static func pick_run(content_index: ContentIndex, run_id: StringName = &"", lenient: bool = false) -> Dictionary:
	var ids := content_index.runs.keys()
	ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	if run_id != &"":
		if not content_index.runs.has(run_id):
			return {"run": null, "error": "unknown run '%s'" % run_id}
		return {"run": content_index.runs[run_id], "error": ""}
	if ids.is_empty():
		return {"run": null, "error": "the content root has no RunStructure"}
	if ids.size() == 1:
		return {"run": content_index.runs[ids[0]], "error": ""}
	for id in ids:
		if content_index.runs[id].default_run:
			return {"run": content_index.runs[id], "error": ""}
	if lenient:
		return {"run": content_index.runs[ids[0]], "error": ""}
	return {"run": null, "error": "several runs and none is default: %s" % ", ".join(ids)}


## Everything start_run does before the first floor: checks, run state, party from default loadouts, the start_run entry.
func _begin_run(content_index: ContentIndex, character_ids: Array, seed_text: String, run_id: StringName = &"",
		lenient: bool = false) -> String:
	content = content_index
	if not content.problems.is_empty():
		return _stop("content problems: " + "; ".join(content.problems))
	var picked := pick_run(content, run_id, lenient)
	if picked["error"] != "":
		return _stop(picked["error"])
	structure = picked["run"]
	if structure.floors.is_empty():
		return _stop("run structure %s has no floors" % structure.id)
	var seed_value := RunSeeds.parse(seed_text)
	if seed_value < 0:
		return _stop("the seed must be a whole number from 0 to 9223372036854775807 or a seed code, got '%s'" % seed_text)
	if character_ids.is_empty() or character_ids.size() > 4:
		return _stop("pick 1 to 4 characters")
	state = RunState.new()
	state.run_seed = seed_value
	state.run_id = "run-%d" % seed_value
	state.run_structure_id = structure.id
	run_log.clear()
	_tally = {"coinsEarned": 0, "coinsSpent": 0, "enemiesDefeated": 0}
	for index in character_ids.size():
		var character: CharacterDefinition = content.characters.get(StringName(str(character_ids[index])))
		if character == null:
			return _stop("unknown character '%s'" % character_ids[index])
		state.party.append(_new_member(index + 1, character))
	_refresh_party(true)
	if runner_error != "":
		return runner_error
	var start_entry := {"type": "start_run", "seed": str(seed_value), "party": character_ids.duplicate()}
	if content.runs.size() > 1:
		start_entry["run"] = String(structure.id)  # only when there is a choice, so one-run logs stay unchanged
	run_log.append(start_entry)
	return ""


## The character's loadout seeds its run state once (spec 3.1): learned skills, items, equipment.
func _new_member(slot: int, character: CharacterDefinition) -> Dictionary:
	var member := {
		"slot": slot, "character": character.id, "level": 1, "xp": 0, "hp": 0, "mp": null, "energy": null, "alive": true,
		"skills": [], "items": [], "use_slots": [], "equipment": {},
	}
	var loadout := character.default_loadout
	if loadout == null:
		return member
	var base_tags: Array[StringName] = []
	for scene in character.abilities:
		base_tags.append(SkillTags.tag_of(scene))
	for scene in loadout.skills:
		var tag := SkillTags.tag_of(scene)
		if base_tags.has(tag):
			continue
		if character.skill_scene(tag) == null:
			_warn("%s's loadout gives %s, which is not in its abilities or learnable_skills; skipped" % [character.id, tag])
		elif not member["skills"].has(tag):
			member["skills"].append(tag)
	for piece in loadout.equipment:
		if piece != null:
			member["equipment"][piece.slot] = piece.id
	for item in loadout.items:
		if item == null:
			continue
		if item.is_usable() and member["use_slots"].size() >= _use_capacity(member):
			_warn("%s's loadout has more usable items than use slots; %s skipped" % [character.id, item.id])
			continue
		_place_item(member, item)
	return member


## `choice`: the chapter picked at the stairs for a CHOICE slot (spec playable-demo 3.8).
func enter_floor(floor_index: int, choice: StringName = &"") -> String:
	var slot: FloorSlot = structure.floors[floor_index]
	var picked := slot.pick_chapter(state.run_seed, floor_index, chapter() if state.chapter_id != &"" else null, choice)
	if picked["error"] != "":
		return _stop("%s: %s" % [structure.id, picked["error"]])
	var chapter: ChapterDefinition = picked["chapter"]
	_reset_floor(floor_index, chapter)
	var pools := _pools()
	var generator := FloorGenerator.new(content, structure, state.run_seed, floor_index)
	var result: Dictionary
	if slot.layout != null:
		result = generator.from_layout(slot.layout, chapter, pools)
	else:
		result = generator.generate(chapter, slot.rooms_from_any_chapter, pools)
	if result["error"] != "":
		return _stop("floor %d: %s" % [floor_index, result["error"]])
	_install_floor(result["map"], pools, true)
	return runner_error


func _reset_floor(floor_index: int, chapter: ChapterDefinition) -> void:
	state.floor_index = floor_index
	state.chapter_id = chapter.id
	state.field_actions_on_floor = 0
	state.gifts_on_floor = 0
	state.boss_cleared = false
	state.event = {}
	pending_battle = {}


## The generated map becomes the current floor; the start cell is visited (and cleared, except a sandbox room, whose
## content plays when it is entered).
func _install_floor(map: FloorMap, pools: Dictionary, clear_start: bool) -> void:
	state.seen_items.assign(pools["seen"])
	state.map = map
	state.current_cell = state.map.start
	state.map.cells[state.map.start]["visited"] = true
	state.map.cells[state.map.start]["cleared"] = clear_start
	print("RunController: seed %d, floor %d (%s), %d rooms, %d generation attempt(s)"
		% [state.run_seed, state.floor_index, state.chapter_id, state.map.cells.size(), state.map.attempts])
	_run_hooks("on_floor_start")
	floor_entered.emit(state.floor_index)
	_send(GameplayMessageRouter.RUN_FLOOR_ENTERED, &"Verb.Enter", &"", state.chapter_id, state.floor_index + 1)


## After the boss: the next floor, or the run is won after the last one (that happens in _clear_room).
## `chapter_id`: the route picked at the stairs when the next floor is a CHOICE (next_floor_choices()).
func next_floor(chapter_id: StringName = &"") -> String:
	if not _active() or not state.boss_cleared or state.floor_index + 1 >= structure.floors.size() or state.sandbox \
			or not state.event.is_empty():
		return "the next floor is not open"
	var choices := next_floor_choices()
	var entry := {"type": "next_floor", "floor": state.floor_index}
	if choices.size() > 1:
		if not choices.any(func(chapter: ChapterDefinition) -> bool: return chapter.id == chapter_id):
			return "pick the next floor: %s" % ", ".join(choices.map(func(chapter: ChapterDefinition) -> String:
				return String(chapter.id)))
		entry["chapter"] = String(chapter_id)  # only on a choice, so older logs are unchanged
	run_log.append(entry)
	# Spec playable-demo 3.11 (D29): the rest stop opens first; the next floor starts when it ends.
	if structure.rest_event != null:
		state.event = {"cell": -1, "event": structure.rest_event.id, "page": 0, "rest_to": state.floor_index + 1,
			"chapter": String(chapter_id)}
		event_page_shown.emit(structure.rest_event.id, 0)
		return ""
	return enter_floor(state.floor_index + 1, chapter_id)


## Spec playable-demo 3.8: the chapters the player picks between at the stairs ([] unless the next floor is a CHOICE).
func next_floor_choices() -> Array[ChapterDefinition]:
	var result: Array[ChapterDefinition] = []
	if state == null or state.floor_index + 1 >= structure.floors.size():
		return result
	var slot: FloorSlot = structure.floors[state.floor_index + 1]
	if slot.pick == FloorSlot.Pick.CHOICE:
		result.assign(slot.chapters)
	return result


func chapter() -> ChapterDefinition:
	return content.chapters.get(state.chapter_id)


func is_last_floor() -> bool:
	return state.floor_index + 1 >= structure.floors.size()


## Spec playable-demo 3.1: the run so far for the end screen and the play report. Read-only; counted from run_log,
## plus coins and enemies beaten (tallied as they happen). {} before a run starts.
func run_summary() -> Dictionary:
	if state == null:
		return {}
	var counts := {"battle_won": 0, "battle_lost": 0, "take": 0, "armor": 0, "choose": 0, "field": 0, "next_floor": 0}
	for entry in run_log:
		match str(entry["type"]):
			"battle":
				counts["battle_won" if entry["outcome"] == Battle.VICTORY else "battle_lost"] += 1
			"take", "buy":
				counts["armor" if entry.get("kind", "") == FloorGenerator.EQUIPMENT_KIND else "take"] += 1
			"choose", "field", "next_floor":
				counts[entry["type"]] += 1
	var room := current_room() if state.map != null and state.current_cell >= 0 else null
	return {
		"status": state.status, "run": String(state.run_structure_id), "seed": RunSeeds.display(state.run_seed),
		"floorReached": state.floor_index + 1, "floors": structure.floors.size() if structure != null else 0,
		"floorsCleared": counts["next_floor"] + (1 if state.boss_cleared else 0),
		"battlesWon": counts["battle_won"], "battlesLost": counts["battle_lost"],
		"enemiesDefeated": _tally.get("enemiesDefeated", 0), "itemsTaken": counts["take"], "armorTaken": counts["armor"],
		"eventChoices": counts["choose"], "fieldActions": counts["field"], "coins": state.coins,
		"coinsEarned": _tally.get("coinsEarned", 0), "coinsSpent": _tally.get("coinsSpent", 0),
		"endedIn": {"floor": state.floor_index + 1, "room": String(room.id) if room != null else "",
			"encounter": _tally.get("lastEncounter", "") if state.status == RunState.LOST else ""},
	}


# --- Map ------------------------------------------------------------------------------------------------------------

## Isaac rules: any room next to a visited one; revisiting is allowed; nothing while a battle or event is open.
func can_enter(index: int) -> bool:
	if not _active() or not pending_battle.is_empty() or not state.event.is_empty():
		return false
	if not state.map.cells.has(index) or index == state.current_cell:
		return false
	for neighbour in state.map.neighbours(index):
		if state.map.cells[neighbour]["visited"]:
			return true
	return false


func enter_room(index: int) -> String:
	if not can_enter(index):
		return "can't enter that room now"
	run_log.append({"type": "enter_room", "floor": state.floor_index, "cell": index})
	_enter_cell(index)
	return ""


## Moves into a cell and plays what it holds (battle, event, pickups), or clears it.
func _enter_cell(index: int) -> void:
	state.current_cell = index
	var data: Dictionary = state.map.cells[index]
	data["visited"] = true
	room_entered.emit(index)
	if data["cleared"]:
		if not data["pickups"].is_empty():
			pickups_shown.emit(index)
		return
	var room_content: Dictionary = data["content"]
	match room_content["kind"]:
		"encounter":
			pending_battle = {"cell": index, "encounter": room_content["encounter"], "enemies": room_content["enemies"],
				"label": ""}
			battle_requested.emit(battle_snapshot())
		"event":
			state.event = {"cell": index, "event": room_content["event"], "page": 0}
			event_page_shown.emit(room_content["event"], 0)
		_:
			_clear_room(index, false)


func current_room() -> RoomDefinition:
	return content.rooms.get(state.map.cells[state.current_cell]["room"]) if state.map != null else null


# --- Battles --------------------------------------------------------------------------------------------------------

## The v2 BattleSnapshot for the pending battle (field order matches the C# records).
func battle_snapshot() -> Dictionary:
	var scaling: ScalingRules = chapter().scaling
	var snapshot := {
		"schemaVersion": 2,
		"battleId": "%s/f%d/c%d%s" % [state.run_id, state.floor_index, pending_battle["cell"], pending_battle["label"]],
		"seed": str(RunSeeds.derive(state.run_seed, "floor/%d/combat/%d%s" % [state.floor_index, pending_battle["cell"],
			pending_battle["label"]])),
		"encounterId": String(pending_battle["encounter"]),
		"party": party_capture(false),
		"enemies": pending_battle["enemies"],
	}
	if scaling != null:
		snapshot["scalingId"] = String(scaling.id)
		snapshot["depth"] = state.floor_index
	return snapshot


## Plays the pending battle with a controller (the player's ActionRecorder, or a scripted one in tests) and applies
## the result. The controller must expose `entries` (the recorded ActionLog entries).
func fight(controller: Object, gate: PresentationGate = null) -> String:
	if pending_battle.is_empty():
		return "no battle is waiting"
	var snapshot := battle_snapshot()
	var battle := Battle.new()
	battle.name = "RunBattle"
	add_child(battle)
	var error := battle.setup(snapshot, content, gate)
	battle.allow_dev = allow_dev
	if error != "":
		battle.queue_free()
		return _stop("battle %s: %s" % [snapshot["battleId"], error])
	battle_started.emit(battle)
	_record_battle(battle)
	await battle.run(controller)
	if battle.runner_error != "":
		var message_text := battle.runner_error
		battle.queue_free()
		return _stop("battle %s: %s" % [snapshot["battleId"], message_text])
	var won := battle.outcome == Battle.VICTORY
	_tally["lastEncounter"] = String(pending_battle["encounter"])
	run_log.append({
		"type": "battle", "floor": state.floor_index, "cell": pending_battle["cell"], "battleId": snapshot["battleId"],
		"outcome": battle.outcome, "finalHash": battle.final_hash,
		"actionLog": ActionRecorder.build_log(controller.entries, battle.outcome, battle.final_hash),
	})
	_warn_all(battle.content_warnings)
	_read_back(battle)
	_apply_used_items(battle.used_items, won)
	battle.queue_free()
	var cell: int = pending_battle["cell"]
	pending_battle = {}
	battle_finished.emit(battle.outcome)
	if won:
		_tally["enemiesDefeated"] += snapshot["enemies"].size()
		_grant_rewards(content.encounters.get(StringName(_tally["lastEncounter"])))
		if not _active():
			return runner_error
		_award_xp(snapshot["enemies"])
		_roll_drops(snapshot["enemies"], cell)
		_clear_room(cell, true)
	else:
		_end(RunState.LOST)
	return ""


# --- Experience, levels and drops (spec playable-demo 3.11) -----------------------------------------------------------

## XP for a won battle: xp_per_enemy per enemy beaten (xp_per_boss for an Enemy.Boss), to every living member.
func _award_xp(enemies: Array) -> void:
	if structure == null or structure.xp_to_level.is_empty():
		return
	var total := 0
	for enemy in enemies:
		var definition: UnitDefinition = content.units.get(StringName(str(enemy.get("unitDefId", ""))))
		var boss := definition != null and definition.tags.has(&"Enemy.Boss")
		total += structure.xp_per_boss if boss else structure.xp_per_enemy
	gain_xp(total, null)


## Outcome API (GainXp): XP for every living member, or only `character`; level-ups follow at once.
func gain_xp(amount: int, character: CharacterDefinition) -> void:
	if structure == null or structure.xp_to_level.is_empty() or amount <= 0:
		return
	for member in state.party:
		if member["alive"] and (character == null or member["character"] == character.id):
			member["xp"] = int(member.get("xp", 0)) + amount
	_check_levels()


## Outcome API (GainLevel): free levels for every living member, or only `character`; XP rises to the new level's start.
func gain_levels(count: int, character: CharacterDefinition) -> void:
	if structure == null or structure.xp_to_level.is_empty() or count <= 0:
		return
	for member in state.party:
		if member["alive"] and (character == null or member["character"] == character.id):
			var target := mini(int(member["level"]) + count, structure.xp_to_level.size() + 1)
			member["xp"] = maxi(int(member.get("xp", 0)), structure.xp_to_level[target - 2] if target >= 2 else 0)
	_check_levels()


## Raises each member's level to what its XP has reached (levels never fall); several at once is fine.
func _check_levels() -> void:
	var curve: Array[int] = structure.xp_to_level
	for member in state.party:
		var level := 1
		for threshold in curve:
			if int(member.get("xp", 0)) >= threshold:
				level += 1
		if level > int(member["level"]):
			var character: UnitDefinition = content.units.get(member["character"])
			var shown := character.display_name if character != null else String(member["character"])
			member["level"] = level
			_notify("%s reaches level %d" % [shown, level])
			_send(GameplayMessageRouter.RUN_LEVEL_UP, &"Verb.LevelUp", &"", StringName("slot:%d" % member["slot"]), level,
				[], {"targetName": shown})
	party_changed.emit()


## Castlevania-style drops: one roll per beaten enemy that has a drop_item, on the stream floor/<n>/item_drop/<cell>
## (its own stream, so the coin roll never moves).
func _roll_drops(enemies: Array, cell: int) -> void:
	var stream := RunSeeds.rng(state.run_seed, "floor/%d/item_drop/%d" % [state.floor_index, cell])
	for enemy in enemies:
		var definition := content.units.get(StringName(str(enemy.get("unitDefId", "")))) as EnemyDefinition
		if definition == null or definition.drop_item == null or definition.drop_chance_x100 <= 0:
			continue
		if RunSeeds.roll(stream, definition.drop_chance_x100):
			_notify("%s dropped %s" % [definition.display_name, definition.drop_item.display_name])
			_send(GameplayMessageRouter.RUN_ITEM_DROPPED, &"Verb.Drop", definition.id, definition.drop_item.id, 0,
				definition.drop_item.tags, {"instigatorName": definition.display_name,
				"targetName": definition.drop_item.display_name})
			give_item(definition.drop_item, null, null)


## Spec playable-demo 3.7: the encounter's rewards after a won battle, in order. Event directives (go to page, start
## an encounter) mean nothing here and are dropped.
func _grant_rewards(encounter: EncounterDefinition) -> void:
	if encounter == null:
		return
	for outcome in encounter.rewards:
		if outcome != null:
			outcome.apply(self)
		if not _active():
			return
	_directive = ""


## What happened in the last battle, for the dev report (spec item-pass 3.1): hits with their hit tags, triggered
## passives, breaks, recoveries, One More actions and deaths, in order. Presentation-free; never part of the run hash.
func _record_battle(battle: Battle) -> void:
	battle_log.clear()
	battle.damage_dealt.connect(func(source, target, amount, hit_tags):
		battle_log.append({"event": "hit", "source": String(source), "target": String(target), "amount": amount,
			"hitTags": _strings(hit_tags)}))
	battle.trigger_activated.connect(func(unit, ability, event):
		battle_log.append({"event": "trigger", "unit": String(unit), "ability": String(ability), "on": String(event)}))
	battle.unit_broken.connect(func(unit, breaker):
		battle_log.append({"event": "break", "unit": String(unit), "by": String(breaker)}))
	battle.unit_recovered.connect(func(unit): battle_log.append({"event": "recover", "unit": String(unit)}))
	battle.one_more_started.connect(func(unit): battle_log.append({"event": "oneMore", "unit": String(unit)}))
	battle.unit_died.connect(func(unit): battle_log.append({"event": "death", "unit": String(unit)}))
	# Spec content-pass: skipped turns, missed status rolls, drained hits, boss phases, action delays, and every
	# unit's statuses when the battle ends.
	battle.turn_skipped.connect(func(unit): battle_log.append({"event": "skip", "unit": String(unit)}))
	battle.status_resisted.connect(func(source, target, effect):
		battle_log.append({"event": "statusResisted", "source": String(source), "target": String(target), "effect": effect}))
	battle.damage_drained.connect(func(source, target, amount):
		battle_log.append({"event": "drain", "source": String(source), "target": String(target), "amount": amount}))
	battle.phase_changed.connect(func(unit, phase): battle_log.append({"event": "phase", "unit": String(unit), "phase": phase}))
	battle.action_delayed.connect(func(unit, percent):
		battle_log.append({"event": "delay", "unit": String(unit), "percent": percent}))
	battle.battle_ended.connect(func(_outcome, _hash):
		var statuses := {}
		for unit in battle.units():
			statuses[String(unit.unit_id)] = unit.statuses()
		battle_log.append({"event": "end", "statuses": statuses}))


## The party's run state as BattleSnapshot party members (spec 3.5). `full` leaves HP/MP null (= full).
func party_capture(full: bool) -> Array:
	var members: Array = []
	for member in state.party:
		var gear: Array = member["equipment"].keys()
		gear.sort()
		var equipment_ids: Array = []
		for tag in gear:
			equipment_ids.append(String(member["equipment"][tag]))
		var use_slots: Array = []
		for use_slot in member["use_slots"]:
			use_slots.append({"itemId": String(use_slot["item"]), "ready": use_slot["cooldown"] == 0})
		var capture := {"slot": member["slot"], "unitDefId": String(member["character"]), "level": member["level"]}
		if not full:
			capture["hp"] = member["hp"]
			if member["mp"] != null:
				capture["mp"] = member["mp"]
		if member["energy"] != null:
			capture["energy"] = member["energy"]
		capture["skills"] = _strings(member["skills"])
		capture["equipmentIds"] = equipment_ids
		capture["items"] = _strings(member["items"])
		capture["useSlots"] = use_slots
		members.append(capture)
	return members


func _read_back(battle: Battle) -> void:
	for member in state.party:
		var unit := battle.unit_by_id(StringName("P%d" % member["slot"]))
		if unit == null:
			continue
		member["hp"] = unit.stat(BattleUnit.HP)
		member["mp"] = unit.stat(BattleUnit.MP) if unit.asc.has_attribute(BattleUnit.MP) else null
		member["energy"] = unit.stat(BattleUnit.ENERGY) if unit.asc.has_attribute(BattleUnit.ENERGY) else null
		member["alive"] = unit.alive
	party_changed.emit()


## Consumables are removed; cooldown items restart. After a won battle the other cooldowns count down by one.
func _apply_used_items(used: Array[Dictionary], won: bool) -> void:
	var used_keys := {}
	for entry in used:
		used_keys["%s/%s" % [entry["unit"], entry["item"]]] = true
	for member in state.party:
		for index in range(member["use_slots"].size() - 1, -1, -1):
			var use_slot: Dictionary = member["use_slots"][index]
			if used_keys.has("P%d/%s" % [member["slot"], use_slot["item"]]):
				var item: ItemDefinition = content.items[use_slot["item"]]
				if item.use_mode == ItemDefinition.UseMode.CONSUMABLE:
					member["use_slots"].remove_at(index)
				else:
					use_slot["cooldown"] = maxi(item.cooldown_battles, 0)
			elif won:
				use_slot["cooldown"] = maxi(use_slot["cooldown"] - 1, 0)


func _clear_room(index: int, after_battle: bool) -> void:
	var data: Dictionary = state.map.cells[index]
	data["cleared"] = true
	if after_battle:
		_drop_coins(index, data)
		_run_hooks("on_room_cleared")
	if data["role"] == FloorMap.ROLE_BOSS:
		state.boss_cleared = true
	room_cleared.emit(index)
	party_changed.emit()
	if not data["pickups"].is_empty():
		pickups_shown.emit(index)
	if state.boss_cleared and is_last_floor() and _active() and not state.sandbox:
		_end(RunState.WON)


func _drop_coins(index: int, data: Dictionary) -> void:
	var scaling: ScalingRules = chapter().scaling
	var amount := 0
	if scaling != null:
		var drop_rng := RunSeeds.rng(state.run_seed, "floor/%d/drop/%d" % [state.floor_index, index])
		if RunSeeds.roll(drop_rng, scaling.coin_drop_chance_x100):
			amount = drop_rng.randi_range(mini(scaling.coin_drop_min, scaling.coin_drop_max), scaling.coin_drop_max)
	for enemy in data["content"]["enemies"]:
		if enemy["variantId"] != null:
			var variant: EnemyVariant = content.variants.get(StringName(str(enemy["variantId"])))
			if variant != null:
				amount += variant.coin_bonus
	if amount > 0:
		add_coins(amount)


# --- Events ---------------------------------------------------------------------------------------------------------

func current_event() -> EventDefinition:
	return content.events.get(state.event.get("event", &"")) if not state.event.is_empty() else null


func current_page() -> EventPage:
	var event := current_event()
	if event == null or state.event["page"] >= event.pages.size():
		return null
	return event.pages[state.event["page"]]


func choice_enabled(choice_index: int) -> bool:
	var page := current_page()
	if page == null or choice_index < 0 or choice_index >= page.choices.size():
		return false
	for condition in page.choices[choice_index].conditions:
		if condition != null and not condition.holds(self):
			return false
	return true


## Picks a choice: its outcomes run in order. Ends the event unless an outcome went to a page or started a battle.
func choose(choice_index: int) -> String:
	if not _active() or not choice_enabled(choice_index):
		return "that choice isn't available"
	var cell: int = state.event["cell"]
	run_log.append({"type": "choose", "floor": state.floor_index, "cell": cell, "page": state.event["page"],
		"choice": choice_index})
	_send(GameplayMessageRouter.RUN_CHOICE, &"Verb.Choose", &"", StringName(str(state.event["event"])), choice_index,
		[], {"page": state.event["page"]})
	_directive = ""
	for outcome in current_page().choices[choice_index].outcomes:
		if outcome != null:
			outcome.apply(self)
		if not _active():
			return runner_error
	if state.event.has("rest_to") and _directive == "encounter":
		_directive = ""  # a rest stop has no room to fight in (validator: rest_event_encounter)
	match _directive:
		"page":
			state.event["page"] = _directive_page
			event_page_shown.emit(state.event["event"], _directive_page)
		"encounter":
			var room: RoomDefinition = content.rooms[state.map.cells[cell]["room"]]
			var event_rng := RunSeeds.rng(state.run_seed, "floor/%d/event/%d" % [state.floor_index, cell])
			var generator := FloorGenerator.new(content, structure, state.run_seed, state.floor_index)
			state.event = {}
			pending_battle = {"cell": cell, "encounter": _directive_encounter.id,
				"enemies": generator.resolve_enemies(_directive_encounter, room, false, chapter().scaling, event_rng),
				"label": "/event"}
			state.map.cells[cell]["content"]["enemies"] = pending_battle["enemies"]
			battle_requested.emit(battle_snapshot())
		_:
			if state.event.has("rest_to"):
				var rest: Dictionary = state.event
				state.event = {}
				return enter_floor(int(rest["rest_to"]), StringName(str(rest["chapter"])))
			state.event = {}
			_clear_room(cell, false)
	return ""


# --- Pickups and items ----------------------------------------------------------------------------------------------

## Takes a pedestal item or buys a shop item in the current room for the member in `slot`.
func take(placement: int, slot: int) -> String:
	if not _active() or not pending_battle.is_empty():
		return "not now"
	var data: Dictionary = state.map.cells[state.current_cell]
	if not data["cleared"]:
		return "clear the room first"
	for pickup in data["pickups"]:
		if pickup["placement"] != placement:
			continue
		if pickup["taken"]:
			return "already taken"
		if pickup["price"] > state.coins:
			return "not enough coins"
		if pickup.get("kind", "") == FloorGenerator.EQUIPMENT_KIND:
			# Spec item-pass 3.5: armor always goes into the armor inventory; nobody has to hold it.
			state.coins -= pickup["price"]
			_tally["coinsSpent"] += pickup["price"]
			pickup["taken"] = true
			var entry := {"type": "buy" if pickup["price"] > 0 or pickup.has("priceItem") else "take",
				"floor": state.floor_index, "cell": state.current_cell, "placement": placement,
				"kind": FloorGenerator.EQUIPMENT_KIND}
			var payer := slot if slot > 0 else int(state.party[0]["slot"])
			if pickup.has("priceItem"):
				entry["slot"] = payer  # who pays the curse; only on priced armor, so older logs are unchanged
			run_log.append(entry)
			var piece: EquipmentDefinition = content.equipment[pickup["item"]]
			_receive_equipment(piece)
			_send_taken(entry["type"], payer, piece, pickup)
			if pickup.has("priceItem"):
				_pay_with_item(payer, pickup["priceItem"])
			return ""
		var item: ItemDefinition = content.items[pickup["item"]]
		var problem := can_hold(slot, item)
		if problem != "":
			return problem
		state.coins -= pickup["price"]
		_tally["coinsSpent"] += pickup["price"]
		pickup["taken"] = true
		var paid_with_item: bool = pickup.has("priceItem")
		run_log.append({"type": "buy" if pickup["price"] > 0 or paid_with_item else "take", "floor": state.floor_index,
			"cell": state.current_cell, "placement": placement, "slot": slot})
		_receive_item(slot, item)
		_send_taken(run_log[-1]["type"], slot, item, pickup)
		if paid_with_item:
			_pay_with_item(slot, pickup["priceItem"])
		return ""
	return "no such pickup"


## "" when the member in `slot` can hold the item, else why not.
func can_hold(slot: int, item: ItemDefinition) -> String:
	var member := state.member(slot)
	if member.is_empty():
		return "no member in slot %d" % slot
	if not member["alive"]:
		return "%s is dead" % member["character"]
	if item.is_usable() and member["use_slots"].size() >= _use_capacity(member):
		return "%s has no free use slot" % member["character"]
	return ""


## For screens: each member's current and maximum hp/mp/energy (×100), read through GAS so item and equipment bonuses
## count. slot -> {attribute name -> value}; attributes the set doesn't have are left out.
func party_stats() -> Dictionary:
	var stats := {}
	if not _active():
		return stats
	var battle := _field_battle(0)
	if battle == null:
		return stats
	for member in state.party:
		var unit := battle.unit_by_id(StringName("P%d" % member["slot"]))
		if unit != null:
			stats[member["slot"]] = unit_stats(unit)
	battle.free()
	return stats


## A unit's current and maximum hp/mp/energy (×100), for screens.
static func unit_stats(unit: BattleUnit) -> Dictionary:
	var stats := {}
	for attribute_name in [BattleUnit.HP, BattleUnit.MAX_HP, BattleUnit.MP, BattleUnit.MAX_MP, BattleUnit.ENERGY,
			BattleUnit.MAX_ENERGY]:
		if unit.asc.has_attribute(attribute_name):
			stats[attribute_name] = unit.stat(attribute_name)
	return stats


func use_capacity(slot: int) -> int:
	return _use_capacity(state.member(slot))


func _use_capacity(member: Dictionary) -> int:
	var capacity := 1
	for item_id in member["items"]:
		capacity += content.items[item_id].extra_use_slots
	for use_slot in member["use_slots"]:
		capacity += content.items[use_slot["item"]].extra_use_slots
	return capacity


func _receive_item(slot: int, item: ItemDefinition) -> void:
	_place_item(state.member(slot), item)
	if not state.seen_items.has(item.id):
		state.seen_items.append(item.id)
	var outer := hook_item  # a hook that gives an item (Mystery Box) is still running after this one
	hook_item = item
	for outcome in item.on_pickup:
		if outcome != null:
			outcome.apply(self)
	hook_item = outer
	party_changed.emit()


## Spec playable-demo 3.8: a pickup's price item (a curse) goes to the taker, past any capacity; each copy counts.
func _pay_with_item(slot: int, item_id: StringName) -> void:
	var curse: ItemDefinition = content.items.get(item_id)
	if curse == null:
		_stop("unknown price item '%s'" % item_id)
		return
	_receive_item(slot, curse)
	_tally["itemPrices"] = int(_tally.get("itemPrices", 0)) + 1


func _place_item(member: Dictionary, item: ItemDefinition) -> void:
	if item.is_usable():
		member["use_slots"].append({"item": item.id, "cooldown": 0})
	else:
		member["items"].append(item.id)


# --- Armor (spec item-pass 3.5) --------------------------------------------------------------------------------------

## The run's equipment slots in display order: the run structure's list, or (when it lists none) every slot in use.
func equipment_slots() -> Array[StringName]:
	var slots: Array[StringName] = []
	if structure != null and not structure.equipment_slots.is_empty():
		slots.assign(structure.equipment_slots)
		return slots
	if state == null:
		return slots
	for piece_id in state.held_equipment():
		var piece: EquipmentDefinition = content.equipment.get(piece_id)
		if piece != null and not slots.has(piece.slot):
			slots.append(piece.slot)
	slots.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return slots


## Equips a piece from the armor inventory on the member in `slot` (alive or dead; gear applies when revived). The
## piece already in that equipment slot goes back to the inventory. Map only; logged.
func equip(slot: int, piece_id: StringName) -> String:
	if not _active() or not pending_battle.is_empty():
		return "not now"
	var member := state.member(slot)
	if member.is_empty():
		return "no member in slot %d" % slot
	if not state.armor.has(piece_id):
		return "%s is not in the armor inventory" % piece_id
	var piece: EquipmentDefinition = content.equipment.get(piece_id)
	if piece == null:
		return "unknown equipment %s" % piece_id
	run_log.append({"type": "equip", "floor": state.floor_index, "slot": slot, "equipment": String(piece_id)})
	state.armor.erase(piece_id)
	_wear(member, piece)
	return ""


## Takes the piece off the member's equipment slot `slot_tag` and puts it back in the armor inventory. Map only; logged.
func unequip(slot: int, slot_tag: StringName) -> String:
	if not _active() or not pending_battle.is_empty():
		return "not now"
	var member := state.member(slot)
	if member.is_empty():
		return "no member in slot %d" % slot
	if not member["equipment"].has(slot_tag):
		return "%s has nothing in %s" % [member["character"], slot_tag]
	run_log.append({"type": "unequip", "floor": state.floor_index, "slot": slot, "equipment_slot": String(slot_tag)})
	state.armor.append(member["equipment"][slot_tag])
	member["equipment"].erase(slot_tag)
	party_changed.emit()
	return ""


func _receive_equipment(piece: EquipmentDefinition) -> void:
	state.armor.append(piece.id)
	if not state.seen_items.has(piece.id):
		state.seen_items.append(piece.id)
	party_changed.emit()


## Puts the piece in its slot; whatever was there goes back to the armor inventory.
func _wear(member: Dictionary, piece: EquipmentDefinition) -> void:
	var replaced: Variant = member["equipment"].get(piece.slot)
	if replaced != null and replaced != piece.id:
		state.armor.append(replaced)
	member["equipment"][piece.slot] = piece.id
	party_changed.emit()


# --- Out-of-battle actions (field mode) -----------------------------------------------------------------------------

## For each living member, the abilities usable on the map right now: [{"slot", "ability", "item", "targets"}].
## "targets" lists the slots a SINGLE_* ability may aim at (empty for SELF / ALL_*).
func field_options() -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	if not _active() or not pending_battle.is_empty():
		return options
	var battle := _field_battle(0)
	if battle == null:
		return options
	for member in state.party:
		var unit := battle.unit_by_id(StringName("P%d" % member["slot"]))
		if unit == null or not unit.alive:
			continue
		for ability in unit.action_abilities():
			if ability.targets_enemies() or not unit.asc.can_activate_ability(ability):
				continue
			var targets: Array[int] = []
			if ability.needs_target():
				for candidate in battle.target_candidates(unit, ability):
					targets.append(candidate.slot)
				if targets.is_empty():
					continue
			options.append({"slot": member["slot"], "ability": ability.ability_tag,
				"item": unit.item_abilities.get(ability.ability_tag, &""), "targets": targets})
	battle.free()
	return options


## Uses a spell or a held item's ability on the map. Returns [] on success, else [reason, detail].
func use_field(slot: int, ability_tag: StringName, target_slot: int = 0) -> Array:
	if not _active() or not pending_battle.is_empty():
		return ["NotNow", "finish the battle first"]
	var seed_value := RunSeeds.derive(state.run_seed, "floor/%d/field/%d" % [state.floor_index, state.field_actions_on_floor])
	var battle := _field_battle(seed_value)
	if battle == null:
		return ["RunnerError", runner_error]
	var target := StringName("P%d" % target_slot) if target_slot > 0 else &""
	var problem: Array = await battle.perform(StringName("P%d" % slot), ability_tag, target)
	if not problem.is_empty():
		battle.free()
		return problem
	state.field_actions_on_floor += 1
	var used: Array[Dictionary] = battle.used_items
	run_log.append({"type": "field", "floor": state.floor_index, "slot": slot, "ability": String(ability_tag),
		"target": target_slot, "item": String(used[0]["item"]) if not used.is_empty() else null,
		"resultHash": battle.state_hash()})
	_warn_all(battle.content_warnings)
	_read_back(battle)
	_apply_used_items(used, false)
	battle.free()
	if not state.anyone_alive():
		_end(RunState.LOST)
	return []


## A field-mode Battle built from the party's run state (party only, State.Infield on every unit).
func _field_battle(seed_value: int, full: bool = false) -> Battle:
	var battle := Battle.new()
	battle.name = "FieldBattle"
	add_child(battle)
	var snapshot := {"schemaVersion": 2, "battleId": "%s/field" % state.run_id, "seed": str(seed_value),
		"encounterId": "", "party": party_capture(full)}
	var error := battle.setup_field(snapshot, content)
	if error != "":
		battle.free()
		_stop("field: " + error)
		return null
	return battle


## Reads full HP/MP (and ult charge) for every member through GAS (run start).
func _refresh_party(full: bool) -> void:
	var battle := _field_battle(0, full)
	if battle == null:
		return
	_read_back(battle)
	battle.free()


# --- Outcome API (called by RunOutcome subclasses) -------------------------------------------------------------------

func add_coins(amount: int) -> void:
	var before := state.coins
	state.coins = maxi(state.coins + amount, 0)
	if not _tally.is_empty():
		_tally["coinsEarned" if amount > 0 else "coinsSpent"] += absi(state.coins - before)
	party_changed.emit()


## Applies a GameplayEffect to party members through GAS (heals, damage, MP, ult charge; with include_dead, revives).
func apply_party_effect(effect: GameplayEffect, include_dead: bool) -> void:
	apply_member_effect(effect, [], include_dead)


## apply_party_effect for some members only (`slots` empty = everyone), through the same field context.
func apply_member_effect(effect: GameplayEffect, slots: Array, include_dead: bool) -> void:
	if effect == null:
		return
	var battle := _field_battle(0)
	if battle == null:
		return
	var ids: Array[StringName] = []
	for member in state.party:
		if (member["alive"] or include_dead) and (slots.is_empty() or slots.has(member["slot"])):
			ids.append(StringName("P%d" % member["slot"]))
	battle.apply_to_units(effect, ids)
	_read_back(battle)
	battle.free()
	if not state.anyone_alive():
		_end(RunState.LOST)


## Gives `item` (or one picked from `query`) to `character`, or to the first living member who can hold it.
func give_item(item: ItemDefinition, query: GameplayTagQuery, character: CharacterDefinition) -> void:
	if item == null:
		var gift_rng := RunSeeds.rng(state.run_seed, "floor/%d/gift/%d" % [state.floor_index, state.gifts_on_floor])
		state.gifts_on_floor += 1
		var generator := FloorGenerator.new(content, structure, state.run_seed, state.floor_index)
		item = generator.pick_item(null, query, gift_rng, _pools())
		if item == null:
			return
	var slot := 0
	if character != null:
		slot = state.member_slot(character.id)
	else:
		for member in state.party:
			if can_hold(member["slot"], item) == "":
				slot = member["slot"]
				break
	if slot == 0 or can_hold(slot, item) != "":
		_warn("nobody can hold %s; it is lost" % item.id)
		return
	_receive_item(slot, item)


func remove_item(item: ItemDefinition) -> void:
	if item == null:
		return
	for member in state.party:
		member["items"].erase(item.id)
		for index in range(member["use_slots"].size() - 1, -1, -1):
			if member["use_slots"][index]["item"] == item.id:
				member["use_slots"].remove_at(index)
	party_changed.emit()


## Spec playable-demo 3.7 (D9): armor from outcomes goes to the armor inventory; nothing is worn on its own.
func give_equipment(piece: EquipmentDefinition) -> void:
	if piece != null:
		_receive_equipment(piece)


func event_go_to_page(page: int) -> void:
	_directive = "page"
	_directive_page = page


func event_end() -> void:
	_directive = "end"


func event_start_encounter(encounter: EncounterDefinition) -> void:
	if encounter != null:
		_directive = "encounter"
		_directive_encounter = encounter


# --- Dev tools (spec dev-tools 3.2-3.4) ------------------------------------------------------------------------------
# Every cheat checks first, then logs itself with dev_log() (run marked dev, its own dev/<k> stream), then acts through
# the normal run code: units change through GAS (effects, items), the run through the methods above.

const DEV_CONTENT: String = "res://game/dev/content/"


## Logs a cheat and returns the RNG stream it may draw from ("dev/<k>"); no other stream is ever touched.
func dev_log(command: String, args: Array) -> RandomNumberGenerator:
	run_log.append({"type": "dev", "command": command, "args": args.map(func(arg) -> String: return str(arg))})
	var stream := RunSeeds.rng(state.run_seed, "dev/%d" % state.dev_commands)
	state.dev_commands += 1
	state.dev = true
	return stream


## A dev effect file (dev_kill, dev_heal, dev_revive).
static func dev_effect(name: String) -> GameplayEffect:
	var path := DEV_CONTENT + "effects/%s.tres" % name
	return load(path) if ResourceLoader.exists(path) else null


## The item to `slot` (0 = the first member who can hold it), as if picked up.
func dev_give(item: ItemDefinition, slot: int) -> String:
	if not _active():
		return "no run"
	slot = slot if slot > 0 else _first_holder(item)
	var problem := can_hold(slot, item) if slot > 0 else "nobody can hold %s" % item.id
	if problem != "":
		return problem
	dev_log("give", [item.id, slot])
	_receive_item(slot, item)
	return ""


func dev_remove(item: ItemDefinition) -> String:
	if not _active() or state.holder_of(item.id) == 0:
		return "nobody holds %s" % item.id
	dev_log("remove", [item.id])
	remove_item(item)
	return ""


func dev_equip(piece: EquipmentDefinition, slot: int) -> String:
	if not _active():
		return "no run"
	var member := state.member(slot if slot > 0 else state.party[0]["slot"])
	if member.is_empty():
		return "no member in slot %d" % slot
	dev_log("equip", [piece.id, member["slot"]])
	_wear(member, piece)  # the cheat wears it at once; whatever was in the slot goes to the armor inventory
	return ""


func dev_coins(amount: int) -> String:
	if not _active():
		return "no run"
	dev_log("coins", [amount])
	add_coins(amount)
	return ""


## heal / revive / effect out of battle: the effect on living (or dead) members through the field context.
func dev_apply(command: String, effect: GameplayEffect, slots: Array, include_dead: bool) -> String:
	if not _active():
		return "no run"
	if not pending_battle.is_empty():
		return "not during a battle"
	if effect == null:
		return "no effect"
	dev_log(command, [effect.resource_path] + slots)
	apply_member_effect(effect, slots, include_dead)
	return ""


## `count` dev stat items for `attribute` (negative = downs) to `slot` (0 = the first living member).
func dev_stat(attribute_name: String, count: int, slot: int) -> String:
	if not _active():
		return "no run"
	if count == 0:
		return "a count of 0 does nothing"
	var item: ItemDefinition = content.items.get(StringName("dev.%s.%s" % ["up" if count > 0 else "down", attribute_name]))
	if item == null:
		return "no dev stat item for '%s' (is the dev content loaded?)" % attribute_name
	slot = slot if slot > 0 else _first_holder(item)
	var problem := can_hold(slot, item) if slot > 0 else "nobody can hold %s" % item.id
	if problem != "":
		return problem
	dev_log("stat", [attribute_name, count, slot])
	for index in absi(count):
		_place_item(state.member(slot), item)
	party_changed.emit()
	return ""


func dev_win() -> String:
	if not _active():
		return "no run"
	dev_log("win", [])
	pending_battle = {}
	_end(RunState.WON)
	return ""


## Enters floor `floor_index` (0-based) of the run structure; party and inventory are kept.
## `chapter_id` picks a CHOICE floor's chapter, or a ROUTE floor's when the current chapter is on no route of it
## (spec playable-demo 3.8); empty = the slot's first chapter.
func dev_stage(floor_index: int, chapter_id: StringName = &"") -> String:
	if not _active():
		return "no run"
	if floor_index < 0 or floor_index >= structure.floors.size():
		return "floors are 0 to %d" % (structure.floors.size() - 1)
	var slot: FloorSlot = structure.floors[floor_index]
	if chapter_id == &"" and slot.pick != FloorSlot.Pick.RANDOM and not slot.chapters.is_empty():
		chapter_id = slot.chapters[0].id
	dev_log("stage", [floor_index] + ([String(chapter_id)] if chapter_id != &"" else []))
	state.sandbox = false
	return enter_floor(floor_index, chapter_id)


## Replaces the current floor with a sandbox floor (one room or one layout); party and inventory are kept.
func dev_sandbox(request: SandboxRequest) -> String:
	if not _active():
		return "no run"
	var extra: Array = []
	for resource in [request.room, request.layout, request.encounter]:
		if resource != null and not _indexed(resource):
			extra.append(resource)
	if not extra.is_empty():
		content = content.overlay(extra)
	dev_log("room" if request.room != null else "layout",
		[request.room.id if request.room != null else request.layout.id])
	state.sandbox = true
	return enter_sandbox_floor(request)


## Starts a battle with `encounter` in the current room (like an event's StartEncounter).
func dev_spawn(encounter: EncounterDefinition) -> String:
	if not _active() or not pending_battle.is_empty() or not state.event.is_empty():
		return "not now (finish the battle or event first)"
	var stream := dev_log("spawn", [encounter.id])
	if content.encounters.get(encounter.id) != encounter:
		content = content.overlay([encounter])
	var generator := FloorGenerator.new(content, structure, state.run_seed, state.floor_index)
	pending_battle = {"cell": state.current_cell, "encounter": encounter.id,
		"enemies": generator.resolve_enemies(encounter, current_room(), false, chapter().scaling, stream),
		"label": "/dev%d" % (state.dev_commands - 1)}
	state.map.cells[state.current_cell]["content"]["enemies"] = pending_battle["enemies"]
	battle_requested.emit(battle_snapshot())
	return ""


## Adds a pickup to the current room (price 0 = free pedestal); `item` (an item or a piece of equipment) null picks one
## from `pool_tag` on dev/<k>, items and equipment together as pedestals do.
func dev_spawn_item(item: Resource, pool_tag: StringName, price: int) -> String:
	if not _active():
		return "no run"
	var stream := dev_log("spawn item" if item != null else "spawn pool", [item.id if item != null else pool_tag, price])
	if item == null:
		var query := GameplayTagQuery.new()
		query.require_all_tags.assign([pool_tag])
		var generator := FloorGenerator.new(content, structure, state.run_seed, state.floor_index)
		item = generator.pick_pickup(null, null, query, stream, _pools())
		if item == null:
			return "no item in the pool %s" % pool_tag
	var data: Dictionary = state.map.cells[state.current_cell]
	var number: int = 1000 + data["pickups"].filter(func(pickup) -> bool: return pickup["placement"] >= 1000).size()
	data["pickups"].append(FloorGenerator.pickup_entry(number, item, maxi(price, 0)))
	state.seen_items.append(item.id)
	if data["cleared"]:
		pickups_shown.emit(state.current_cell)
	return ""


func dev_reveal() -> String:
	if not _active():
		return "no run"
	dev_log("reveal", [])
	state.revealed = true
	map_revealed.emit()
	return ""


## `goto`: moves into any room of the floor (no need to be next to a visited one); it then plays as if entered.
func dev_goto(index: int) -> String:
	if not _active():
		return "no run"
	if not pending_battle.is_empty() or not state.event.is_empty():
		return "not while a battle or an event is open"
	if not state.map.cells.has(index):
		return "no cell %d on this floor" % index
	if index == state.current_cell:
		return "already in cell %d" % index
	dev_log("goto", [index])
	_enter_cell(index)
	return ""


## `bossdone`: the floor's boss counts as beaten (its room cleared; no battle, rewards, drops or XP), so the stairs
## open; on the last floor the run is won.
func dev_boss_done() -> String:
	if not _active():
		return "no run"
	if not pending_battle.is_empty() or not state.event.is_empty():
		return "not while a battle or an event is open"
	if state.boss_cleared:
		return "the boss is already beaten"
	var boss := -1
	for index in state.map.sorted_indices():
		if state.map.cells[index]["role"] == FloorMap.ROLE_BOSS:
			boss = index
	if boss < 0:
		return "this floor has no boss room"
	dev_log("bossdone", [])
	state.map.cells[boss]["visited"] = true
	_clear_room(boss, false)
	return ""


## `xp`: XP (the GainXp path) or free levels (GainLevel) for every living member, or only `slot`'s character.
func dev_xp(amount: int, levels: bool, slot: int) -> String:
	if not _active():
		return "no run"
	if structure.xp_to_level.is_empty():
		return "run %s has no XP curve (xp_to_level)" % structure.id
	if amount <= 0:
		return "the amount must be above 0"
	var character: CharacterDefinition = null
	if slot > 0:
		var member := state.member(slot)
		if member.is_empty():
			return "no member in slot %d" % slot
		character = content.characters.get(member["character"])
	dev_log("level" if levels else "xp", [amount, slot])
	if levels:
		gain_levels(amount, character)
	else:
		gain_xp(amount, character)
	return ""


## kill / heal in battle: queued on the recorder, applied by the battle at the next party decision.
func dev_battle(command: String, effect: GameplayEffect, targets: String, recorder: ActionRecorder) -> String:
	if pending_battle.is_empty() or recorder == null:
		return "only in a battle"
	if effect == null:
		return "no effect"
	dev_log(command, [targets])
	recorder.submit_dev(StringName("Dev." + command.capitalize()), effect, targets)
	return ""


func _first_holder(item: ItemDefinition) -> int:
	for member in state.party:
		if can_hold(member["slot"], item) == "":
			return member["slot"]
	return 0


func _indexed(resource: Resource) -> bool:
	for table in [content.rooms, content.layouts, content.encounters]:
		if table.get(resource.get("id")) == resource:
			return true
	return false


# --- Helpers ---------------------------------------------------------------------------------------------------------

func _run_hooks(kind: String) -> void:
	for member in state.party:
		var held: Array = member["items"].duplicate()
		for use_slot in member["use_slots"]:
			held.append(use_slot["item"])
		for item_id in held:
			hook_item = content.items[item_id]
			for outcome in hook_item.get(kind):
				if outcome != null and _active():
					outcome.apply(self)
			hook_item = null


func _pools() -> Dictionary:
	return {"party": state.party_characters(), "held": state.held_items() + state.held_equipment(),
		"seen": state.seen_items.duplicate()}


func _active() -> bool:
	return state != null and state.status == RunState.ACTIVE and runner_error == ""


func _end(status: String) -> void:
	if state.status != RunState.ACTIVE:
		return
	state.status = status
	run_log.append({"type": "end", "status": status})
	run_ended.emit(status)
	_send(GameplayMessageRouter.RUN_ENDED, &"Verb.Win" if status == RunState.WON else &"Verb.Lose", &"", structure.id,
		0, [], {"status": status})


func _stop(error: String) -> String:
	if runner_error == "":
		runner_error = error
		push_error("RunController: " + error)
		_notify(error, [&"Notification.Error"])
		_send(GameplayMessageRouter.RUN_ENDED, &"Verb.Stop", &"", structure.id if structure != null else &"", 0, [],
			{"status": "Stopped", "error": error})
		stopped.emit(error)
	return runner_error


func _warn(text: String) -> void:
	warnings.append(text)
	print("RunController warning: ", text)
	_notify(text, [&"Notification.Warning"])


## Spec gameplay-messages: tells listeners (screens, sounds, the dev log) what happened. Built from state; nothing
## here is read back by the run, so run logs and hashes never depend on who listens.
func _send(channel: StringName, verb: StringName, instigator: StringName, target: StringName, amount: int = 0,
		tags: Array = [], data: Dictionary = {}) -> void:
	GameplayMessages.broadcast(channel, VerbMessage.make(verb, instigator, target, amount, tags, data))


func _notify(text: String, tags: Array = []) -> void:
	GameplayMessages.broadcast(GameplayMessageRouter.NOTIFICATION, NotificationMessage.make(text, tags))


## Message.Run.ItemTaken for a pickup or purchase (`kind` "take" or "buy") by the member in `slot`.
func _send_taken(kind: String, slot: int, item: Resource, pickup: Dictionary) -> void:
	var data := {"targetName": item.display_name}
	if pickup.has("priceItem"):
		data["priceItem"] = String(pickup["priceItem"])
	_send(GameplayMessageRouter.RUN_ITEM_TAKEN, &"Verb.Buy" if kind == "buy" else &"Verb.Take",
		StringName("slot:%d" % slot), item.id, int(pickup["price"]), item.tags, data)


func _warn_all(texts: PackedStringArray) -> void:
	for text in texts:
		_warn(text)


static func _strings(values: Array) -> Array:
	var result: Array = []
	for value in values:
		result.append(String(value))
	return result
