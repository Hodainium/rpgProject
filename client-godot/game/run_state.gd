## The state of one run (spec game-skeleton 3.6). Plain data: slice 2b moves it to Postgres one-to-one.
##
## party: Array of members sorted by slot: {
##   "slot": int, "character": StringName, "level": int,
##   "hp": int, "mp": int or null, "energy": int or null (×100, like the attributes), "alive": bool,
##   "skills": Array[StringName] (learned skills beyond the base kit),
##   "items": Array[StringName] (passive items, pickup order),
##   "use_slots": Array of {"item": StringName, "cooldown": int (won battles left; 0 = ready)},
##   "equipment": Dictionary slot tag → equipment id }
class_name RunState
extends RefCounted

const ACTIVE: String = "Active"
const WON: String = "Won"
const LOST: String = "Lost"

var run_id: String = ""
var run_seed: int = 0
var run_structure_id: StringName = &""
var party: Array[Dictionary] = []
var coins: int = 0
## Every item placed or given this run (no item appears twice).
var seen_items: Array[StringName] = []
var floor_index: int = 0
var chapter_id: StringName = &""
var map: FloorMap
var current_cell: int = -1
var boss_cleared: bool = false
## Counters for the order-dependent streams (field actions, item gifts) on the current floor.
var field_actions_on_floor: int = 0
var gifts_on_floor: int = 0
## The open event: {"cell": int, "event": StringName, "page": int}, or empty.
var event: Dictionary = {}
var status: String = ACTIVE


func member(slot: int) -> Dictionary:
	for entry in party:
		if entry["slot"] == slot:
			return entry
	return {}


## Slot of the member playing `character_id` (alive only when asked), or 0.
func member_slot(character_id: StringName, alive_only: bool = true) -> int:
	for entry in party:
		if entry["character"] == character_id and (entry["alive"] or not alive_only):
			return entry["slot"]
	return 0


## Slot of the member holding `item_id` (passive or in a use slot), or 0.
func holder_of(item_id: StringName) -> int:
	for entry in party:
		if entry["items"].has(item_id):
			return entry["slot"]
		for use_slot in entry["use_slots"]:
			if use_slot["item"] == item_id:
				return entry["slot"]
	return 0


## Every item held by anyone.
func held_items() -> Array[StringName]:
	var result: Array[StringName] = []
	for entry in party:
		result.append_array(entry["items"])
		for use_slot in entry["use_slots"]:
			result.append(use_slot["item"])
	return result


func party_characters() -> Array[StringName]:
	var result: Array[StringName] = []
	for entry in party:
		result.append(entry["character"])
	return result


func anyone_alive() -> bool:
	for entry in party:
		if entry["alive"]:
			return true
	return false


## Canonical lines for the run hash (spec 3.6).
func canonical_lines() -> PackedStringArray:
	var lines := PackedStringArray([
		"run-v1",
		"seed=%d" % run_seed,
		"structure=%s" % run_structure_id,
		"status=%s" % status,
		"floor=%d|chapter=%s|cell=%d|boss_cleared=%d" % [floor_index, chapter_id, current_cell, 1 if boss_cleared else 0],
		"coins=%d" % coins,
		"counters=%d|%d" % [field_actions_on_floor, gifts_on_floor],
		"seen=%s" % ",".join(seen_items),
	])
	for entry in party:
		var slots := PackedStringArray()
		for use_slot in entry["use_slots"]:
			slots.append("%s:%d" % [use_slot["item"], use_slot["cooldown"]])
		var gear := PackedStringArray()
		var slot_tags: Array = entry["equipment"].keys()
		slot_tags.sort()
		for tag in slot_tags:
			gear.append("%s=%s" % [tag, entry["equipment"][tag]])
		lines.append("member=%d|%s|%d|%s|%s|%s|%d|%s|%s|%s|%s" % [entry["slot"], entry["character"], entry["level"],
			entry["hp"], entry["mp"], entry["energy"], 1 if entry["alive"] else 0, ",".join(entry["skills"]),
			",".join(entry["items"]), ",".join(slots), ",".join(gear)])
	if map != null:
		lines.append_array(map.canonical_lines())
	return lines


## SHA-256 of the canonical lines, lowercase hex.
func run_hash() -> String:
	return StateHasher.sha256_hex("\n".join(canonical_lines()))
