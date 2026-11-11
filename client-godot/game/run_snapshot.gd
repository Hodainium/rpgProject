## RunSnapshot v1 (spec server-authority 3.5): everything needed to continue a run, as a JSON-ready dictionary with
## `schemaVersion` 1: the RunState (party, inventory, armor, keys, chests, XP, pending gifts, the open event or rest
## stop), the floor map, the controller's pending battle, a floor waiting for its seed, the tallies the summary reads,
## and a compact copy of the run log (types only, so run_summary() and seq numbers continue). No RNG positions: every
## stream is derived fresh from a seed and a label.
##
## Requirements: restore(capture(run)) gives the same run_hash(), and a run loaded from any checkpoint and finished
## with the same actions reaches the same final hash as the uninterrupted run (test_resume_equivalence). Seeds travel
## as decimal strings (int64 isn't safe as a JSON number); JSON turns every number into a float and every StringName
## into a String, so restore() puts both back field by field.
class_name RunSnapshot
extends RefCounted

const SCHEMA_VERSION: int = 1
## The run_log fields run_summary() and the run-end screen read (the start entry's party); everything else stays on
## the server's log.
const LOG_FIELDS: Array[String] = ["type", "outcome", "kind", "status", "party"]


static func capture(run: RunController) -> Dictionary:
	var state := run.state
	var floor_seeds := {}
	for floor_index in state.floor_seeds:
		floor_seeds[str(floor_index)] = str(state.floor_seeds[floor_index])
	var party: Array = []
	for member in state.party:
		var equipment := {}
		for slot_tag in member["equipment"]:
			equipment[String(slot_tag)] = String(member["equipment"][slot_tag])
		party.append({"slot": member["slot"], "character": String(member["character"]), "level": member["level"],
			"xp": member.get("xp", 0), "hp": member["hp"], "mp": member["mp"], "energy": member["energy"],
			"alive": member["alive"], "skills": _strings(member["skills"]), "items": _strings(member["items"]),
			"useSlots": member["use_slots"].map(func(use_slot: Dictionary) -> Dictionary:
				return {"item": String(use_slot["item"]), "cooldown": use_slot["cooldown"]}),
			"equipment": equipment})
	var log: Array = []
	for entry in run.run_log:
		var compact := {}
		for field in LOG_FIELDS:
			if entry.has(field):
				compact[field] = entry[field]
		log.append(compact)
	return {
		"schemaVersion": SCHEMA_VERSION,
		"run": {
			"runId": state.run_id, "runSeed": str(state.run_seed), "floorSeeds": floor_seeds,
			"structure": String(state.run_structure_id), "party": party, "coins": state.coins,
			"seenItems": _strings(state.seen_items), "armor": _strings(state.armor), "floor": state.floor_index,
			"chapter": String(state.chapter_id), "currentCell": state.current_cell, "bossCleared": state.boss_cleared,
			"fieldActions": state.field_actions_on_floor, "gifts": state.gifts_on_floor,
			"event": _plain(state.event), "pendingGifts": _strings(state.pending_gifts), "status": state.status,
			"dev": state.dev, "sandbox": state.sandbox, "revealed": state.revealed, "revealEvents": state.reveal_events,
			"keys": state.keys, "goldenKey": state.golden_key,
			"chests": state.chests.map(func(chest: Dictionary) -> Dictionary:
				return {"chest": String(chest["chest"]), "serial": chest["serial"]}),
			"chestSerial": state.chest_serial, "devCommands": state.dev_commands,
		},
		"map": _map(state.map) if state.map != null else null,
		"pendingBattle": _plain(run.pending_battle) if not run.pending_battle.is_empty() else null,
		"waitingFloor": {"floor": run._waiting_floor["floor"], "choice": String(run._waiting_floor["choice"])}
			if not run._waiting_floor.is_empty() else null,
		"requestedFloors": run._requested_floors.duplicate(),
		"log": log,
		"tally": _plain(run._tally),
	}


## Loads `snapshot` (as captured, or parsed back from JSON) into `run`, a RunController that isn't playing yet.
## "" or the error. Emits nothing: the caller announces the run (run_started, floor_entered) once it is in place.
## `card_pool` (spec card-collection 2.5) is the run's item pool, which is never part of a snapshot: the server's own copy
## on a resume or a step, the local save's on a local continue; null = the run has none.
static func restore(run: RunController, content_index: ContentIndex, snapshot: Dictionary, card_pool: Variant = null) -> String:
	if int(snapshot.get("schemaVersion", 0)) != SCHEMA_VERSION:
		return "unknown snapshot schema %s" % snapshot.get("schemaVersion")
	var data: Dictionary = _ints(snapshot)
	var saved: Dictionary = data["run"]
	run.content = content_index
	if not content_index.problems.is_empty():
		return "content problems: " + "; ".join(content_index.problems)
	var picked := RunController.pick_run(content_index, StringName(saved["structure"]), true)
	if picked["error"] != "":
		return picked["error"]
	run.structure = picked["run"]
	var state := RunState.new()
	if card_pool != null:
		state.set_card_pool(card_pool)
	state.run_id = str(saved["runId"])
	state.run_seed = str(saved["runSeed"]).to_int()
	for floor_index in saved["floorSeeds"]:
		state.floor_seeds[str(floor_index).to_int()] = str(saved["floorSeeds"][floor_index]).to_int()
	state.run_structure_id = StringName(saved["structure"])
	for member in saved["party"]:
		var equipment := {}
		for slot_tag in member["equipment"]:
			equipment[StringName(slot_tag)] = StringName(member["equipment"][slot_tag])
		state.party.append({"slot": member["slot"], "character": StringName(member["character"]),
			"level": member["level"], "xp": member["xp"], "hp": member["hp"], "mp": member["mp"],
			"energy": member["energy"], "alive": member["alive"], "skills": _names(member["skills"]),
			"items": _names(member["items"]),
			"use_slots": member["useSlots"].map(func(use_slot: Dictionary) -> Dictionary:
				return {"item": StringName(use_slot["item"]), "cooldown": use_slot["cooldown"]}),
			"equipment": equipment})
	state.coins = saved["coins"]
	state.seen_items.assign(_names(saved["seenItems"]))
	state.armor.assign(_names(saved["armor"]))
	state.floor_index = saved["floor"]
	state.chapter_id = StringName(saved["chapter"])
	state.current_cell = saved["currentCell"]
	state.boss_cleared = saved["bossCleared"]
	state.field_actions_on_floor = saved["fieldActions"]
	state.gifts_on_floor = saved["gifts"]
	state.event = _event(saved["event"])
	state.pending_gifts.assign(_names(saved["pendingGifts"]))
	state.status = saved["status"]
	state.dev = saved["dev"]
	state.sandbox = saved["sandbox"]
	state.revealed = saved["revealed"]
	state.reveal_events = saved["revealEvents"]
	state.keys = saved["keys"]
	state.golden_key = saved["goldenKey"]
	for chest in saved["chests"]:
		state.chests.append({"chest": StringName(chest["chest"]), "serial": chest["serial"]})
	state.chest_serial = saved["chestSerial"]
	state.dev_commands = saved["devCommands"]
	state.map = _load_map(data["map"]) if data["map"] != null else null
	run.state = state
	run.pending_battle = {}
	if data["pendingBattle"] != null:
		var battle: Dictionary = data["pendingBattle"]
		run.pending_battle = {"cell": battle["cell"], "encounter": StringName(battle["encounter"]),
			"enemies": battle["enemies"], "label": str(battle["label"])}
	run._waiting_floor = {}
	if data["waitingFloor"] != null:
		run._waiting_floor = {"floor": data["waitingFloor"]["floor"], "choice": StringName(data["waitingFloor"]["choice"])}
	run._requested_floors.assign(data["requestedFloors"])
	run.run_log.clear()
	for entry in data["log"]:
		run.run_log.append(entry)
	run._tally = data["tally"]
	run.runner_error = ""
	run.allow_dev = not state.seeds().server_mode()
	run._committed = run.run_log.size()
	return ""



const TOP_KEYS: Array[String] = ["schemaVersion", "run", "map", "pendingBattle", "waitingFloor", "requestedFloors", "log", "tally"]
const RUN_KEYS: Array[String] = ["runId", "runSeed", "floorSeeds", "structure", "party", "coins", "seenItems", "armor", "floor",
	"chapter", "currentCell", "bossCleared", "fieldActions", "gifts", "event", "pendingGifts", "status", "dev", "sandbox", "revealed",
	"revealEvents", "keys", "goldenKey", "chests", "chestSerial", "devCommands"]
const MEMBER_KEYS: Array[String] = ["slot", "character", "level", "xp", "hp", "mp", "energy", "alive", "skills", "items", "useSlots",
	"equipment"]
const CELL_KEYS: Array[String] = ["index", "cell", "role", "special_tag", "room", "doors", "content", "pickups", "visited", "cleared"]


## "" when `saved` has the shape restore() reads, else what is missing. A snapshot comes from a client and a
## missing key is a script error in the verifier, so the step runner refuses such a request as malformed instead of failing on it.
static func shape_problem(saved: Variant) -> String:
	if not saved is Dictionary:
		return "a snapshot must be an object"
	for key in TOP_KEYS:
		if not saved.has(key):
			return "the snapshot has no \"%s\"" % key
	if not saved["run"] is Dictionary:
		return "snapshot.run must be an object"
	for key in RUN_KEYS:
		if not saved["run"].has(key):
			return "snapshot.run has no \"%s\"" % key
	if not saved["run"]["party"] is Array or not saved["run"]["floorSeeds"] is Dictionary or not saved["log"] is Array \
			or not saved["requestedFloors"] is Array or not saved["tally"] is Dictionary:
		return "a snapshot field has the wrong type"
	for member in saved["run"]["party"]:
		if not member is Dictionary:
			return "a party member must be an object"
		for key in MEMBER_KEYS:
			if not member.has(key):
				return "a party member has no \"%s\"" % key
	if saved["map"] != null:
		if not saved["map"] is Dictionary or not saved["map"].get("cells") is Array:
			return "snapshot.map must be an object with cells"
		for key in ["size", "start", "boss", "attempts"]:
			if not saved["map"].has(key):
				return "snapshot.map has no \"%s\"" % key
		for cell in saved["map"]["cells"]:
			if not cell is Dictionary:
				return "a map cell must be an object"
			for key in CELL_KEYS:
				if not cell.has(key):
					return "a map cell has no \"%s\"" % key
	return ""



static func _map(map: FloorMap) -> Dictionary:
	var cells: Array = []
	for index in map.sorted_indices():
		var cell: Dictionary = _plain(map.cells[index])
		cell["index"] = index
		cell["cell"] = [map.cells[index]["cell"].x, map.cells[index]["cell"].y]
		cells.append(cell)
	return {"size": [map.size.x, map.size.y], "start": map.start, "boss": map.boss, "attempts": map.attempts,
		"cells": cells}


static func _load_map(saved: Dictionary) -> FloorMap:
	var map := FloorMap.new(Vector2i(saved["size"][0], saved["size"][1]))
	map.start = saved["start"]
	map.boss = saved["boss"]
	map.attempts = saved["attempts"]
	for cell in saved["cells"]:
		var content: Dictionary = cell["content"]
		var data := {
			"cell": Vector2i(cell["cell"][0], cell["cell"][1]), "role": str(cell["role"]),
			"special_tag": StringName(cell["special_tag"]), "room": StringName(cell["room"]), "doors": cell["doors"],
			"content": {"kind": str(content["kind"]), "encounter": StringName(content.get("encounter", "")),
				"event": StringName(content.get("event", "")), "enemies": content.get("enemies", [])},
			"pickups": cell["pickups"].map(func(pickup: Dictionary) -> Dictionary: return _pickup(pickup)),
			"visited": cell["visited"], "cleared": cell["cleared"],
		}
		if cell.has("opened"):
			data["opened"] = cell["opened"]
		map.cells[int(cell["index"])] = data
	return map


static func _pickup(saved: Dictionary) -> Dictionary:
	var pickup := saved.duplicate()
	pickup["item"] = StringName(saved["item"])
	if saved.has("priceItem"):
		pickup["priceItem"] = StringName(saved["priceItem"])
	if saved.has("kind"):
		pickup["kind"] = str(saved["kind"])
	return pickup


## state.event: {"cell", "event", "page"}, plus "rest_to" and "chapter" at a rest stop, "after" while gifts wait.
static func _event(saved: Dictionary) -> Dictionary:
	if saved.is_empty():
		return {}
	var event := saved.duplicate(true)
	event["event"] = StringName(saved["event"])
	if saved.has("chapter"):
		event["chapter"] = str(saved["chapter"])
	if saved.has("after"):
		event["after"] = {"kind": str(saved["after"]["kind"]), "page": saved["after"]["page"],
			"encounter": StringName(saved["after"]["encounter"])}
	return event


## A deep copy with StringNames as Strings and Vector2i as [x, y], so it can travel as JSON.
static func _plain(value: Variant) -> Variant:
	if value is Dictionary:
		var result := {}
		for key in value:
			result[String(key) if key is StringName else key] = _plain(value[key])
		return result
	if value is Array:
		return value.map(func(item) -> Variant: return _plain(item))
	if value is StringName:
		return String(value)
	if value is Vector2i:
		return [value.x, value.y]
	return value


## A deep copy with every whole float back as an int (JSON reads every number as a float; a snapshot holds no floats).
static func _ints(value: Variant) -> Variant:
	if value is Dictionary:
		var result := {}
		for key in value:
			result[key] = _ints(value[key])
		return result
	if value is Array:
		return value.map(func(item) -> Variant: return _ints(item))
	if value is float and value == floorf(value):
		return int(value)
	return value


static func _strings(values: Array) -> Array:
	return values.map(func(value) -> String: return String(value))


static func _names(values: Array) -> Array:
	return values.map(func(value) -> StringName: return StringName(str(value)))
