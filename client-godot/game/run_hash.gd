## Spec hash-id-lists 2.3: the run hash (run-v3) is the run's snapshot, encoded one-to-one (RunCanonical). The hashed state is
## RunSnapshot.capture_state(state) minus the fields in NOT_HASHED, plus the two inputs that travel beside the snapshot (the
## current floor's seed in server mode, the card pool's digest when the run has a pool). What the verifier restores is exactly
## what is hashed, and a field added to the snapshot later is hashed the moment it is saved.
##
## One line per part, so goldens stay readable and a mismatch can be traced to its first different line: the header, the `run`
## keys by name (one line per party member), the `map` keys by name then one line per cell in index order, `pendingBattle`,
## `waitingFloor`, `floorSeed`, `card_pool`. A part whose value is null, false, "", [] or {} writes no line, so a feature a run
## never touches adds nothing to its hash (test_empty_parts_restore_alike proves a missing part restores like an empty one).
class_name RunHash
extends RefCounted

const HEADER: String = "run-v3"
## Snapshot paths left out on purpose ("/" between keys), each with its reason. test_snapshot_fields_are_covered reads this list.
const NOT_HASHED: Dictionary = {
	"run/runId": "identity: a step compares it against the run itself",
	"run/devCommands": "a counter of console cheats (a cheat marks the run dev, which is hashed)",
	"run/floorSeeds": "replaced by floorSeed, the current floor's seed; the server's own seeds are the reference for the rest",
	"map/attempts": "how many tries the floor generator needed",
	"log": "a compact copy of the run log for the summary (controller only, not in capture_state)",
	"tally": "the summary's counters (controller only, not in capture_state)",
	"requestedFloors": "network bookkeeping (controller only, not in capture_state)",
}

## Spec 2.4: the play report's hashTiming. Off by default; the report switches it on and reads timing().
static var timing_on: bool = false
static var _count: int = 0
static var _total_usec: int = 0
static var _max_usec: int = 0
static var _max_floor: int = -1


static func lines(state: RunState) -> PackedStringArray:
	var snapshot := RunSnapshot.capture_state(state)
	var result := PackedStringArray([HEADER])
	var run: Dictionary = snapshot["run"]
	for key in _sorted_keys(run):
		if NOT_HASHED.has("run/" + key) or _empty(run[key]):
			continue
		if key == "party":
			for index in run[key].size():
				result.append("run.party[%d]=%s" % [index, RunCanonical.encode(run[key][index])])
		else:
			result.append("run.%s=%s" % [key, RunCanonical.encode(run[key])])
	if snapshot["map"] != null:
		result.append_array(map_lines(snapshot["map"]))
	for key in ["pendingBattle", "waitingFloor"]:
		if not _empty(snapshot[key]):
			result.append("%s=%s" % [key, RunCanonical.encode(snapshot[key])])
	if not state.floor_seeds.is_empty():
		result.append("floorSeed=%d" % int(state.floor_seeds.get(state.floor_index, 0)))  # server mode only
	if state.card_pool_set:
		result.append("card_pool=" + RunCanonical.encode(state.card_pool_digest()))  # spec card-collection 2.5
	return result


## The `map.` lines of a captured map (RunSnapshot._map): its keys by name, then one line per cell in index order.
static func map_lines(map: Dictionary) -> PackedStringArray:
	var result := PackedStringArray()
	for key in _sorted_keys(map):
		if key == "cells" or NOT_HASHED.has("map/" + key) or _empty(map[key]):
			continue
		result.append("map.%s=%s" % [key, RunCanonical.encode(map[key])])
	for cell in map["cells"]:
		result.append("map.cells[%d]=%s" % [int(cell["index"]), RunCanonical.encode(cell)])
	return result


## SHA-256 of the lines, lowercase hex.
static func of(state: RunState) -> String:
	if not timing_on:
		return StateHasher.sha256_hex("\n".join(lines(state)))
	var started := Time.get_ticks_usec()
	var hashed := StateHasher.sha256_hex("\n".join(lines(state)))
	var spent := Time.get_ticks_usec() - started
	_count += 1
	_total_usec += spent
	if spent > _max_usec:
		_max_usec = spent
		_max_floor = state.floor_index
	return hashed


static func reset_timing() -> void:
	_count = 0
	_total_usec = 0
	_max_usec = 0
	_max_floor = -1


## {"hashes", "totalUsec", "meanUsec", "maxUsec", "maxFloor"} since the last reset_timing().
static func timing() -> Dictionary:
	@warning_ignore("integer_division")
	var mean: int = _total_usec / _count if _count > 0 else 0
	return {"hashes": _count, "totalUsec": _total_usec, "meanUsec": mean, "maxUsec": _max_usec, "maxFloor": _max_floor}


static func _empty(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL:
			return true
		TYPE_BOOL:
			return not value
		TYPE_STRING, TYPE_STRING_NAME:
			return String(value).is_empty()
		TYPE_ARRAY, TYPE_DICTIONARY:
			return value.is_empty()
	return false


static func _sorted_keys(value: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for key in value:
		keys.append(String(key))
	keys.sort()
	return keys
