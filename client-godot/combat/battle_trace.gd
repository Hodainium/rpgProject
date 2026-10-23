## Determinism trace (spec atomic-battles 2.C): the state hash after every action of a battle, party and enemy, and on
## demand the canonical lines it was computed from. Tests and dev tools only: it never enters the wire contract, and a
## battle without one (Battle.trace == null) never hashes before its end.
##
## Lines are delta-encoded: point 0 holds its full canonical lines ("+line"), every later point the multiset difference
## against the previous point ("-line" removals first, then "+line" additions, each in canonical order).
class_name BattleTrace
extends RefCounted

const TRACE_VERSION: int = 1
## Verdict of a trace recorded on the client (a replay trace carries the replay verdict instead).
const RECORDED: String = "Recorded"

var with_lines: bool = false
var points: Array[Dictionary] = []
var verdict: String = RECORDED
var reason: Variant = null
var battle_id: String = ""
var _previous: PackedStringArray = PackedStringArray()


func _init(keep_lines: bool = false) -> void:
	with_lines = keep_lines


## Records one point. Returns "" or the hashing error (the battle turns it into a runner error).
func point(battle: Battle, kind: String, actor: StringName = &"", ability: StringName = &"", target: StringName = &"") -> String:
	var collected := StateHasher.canonical_lines(battle)
	if collected["error"] != "":
		return collected["error"]
	var lines: PackedStringArray = collected["lines"]
	battle_id = battle.battle_id
	var entry := {
		"i": points.size(),
		"turn": battle.turn,
		"kind": kind,
		"actor": _id_or_null(actor),
		"ability": _id_or_null(ability),
		"target": _id_or_null(target),
		"hash": StateHasher.sha256_hex("\n".join(lines)),
	}
	if with_lines:
		entry["lines"] = Array(delta(_previous, lines))
		_previous = lines
	points.append(entry)
	return ""


## The trace file (spec 3.3), field order fixed so the same battle always writes the same bytes.
func to_json() -> Dictionary:
	return {
		"traceVersion": TRACE_VERSION,
		"hashVersion": StateHasher.VERSION_LINE,
		"battleId": battle_id,
		"engineVersion": ReplayRunner.engine_version(),
		"verdict": verdict,
		"reason": reason,
		"points": points,
	}


## "-line" for each line only in `before`, then "+line" for each line only in `after` (multiset difference).
static func delta(before: PackedStringArray, after: PackedStringArray) -> PackedStringArray:
	var result := PackedStringArray()
	var left := _counts(after)
	for line in before:
		if left.get(line, 0) > 0:
			left[line] -= 1
		else:
			result.append("-" + line)
	left = _counts(before)
	for line in after:
		if left.get(line, 0) > 0:
			left[line] -= 1
		else:
			result.append("+" + line)
	return result


## Applies one point's deltas to a running multiset {line: count}.
static func apply_delta(state: Dictionary, deltas: Array) -> void:
	for change in deltas:
		var text := str(change)
		var line := text.substr(1)
		if text.begins_with("+"):
			state[line] = int(state.get(line, 0)) + 1
		elif int(state.get(line, 0)) <= 1:
			state.erase(line)
		else:
			state[line] = int(state[line]) - 1


## The full canonical lines at each point of a lined trace, sorted (the deltas don't keep the canonical order).
static func rebuild(trace: Dictionary) -> Array[PackedStringArray]:
	var result: Array[PackedStringArray] = []
	var state := {}
	for entry in trace.get("points", []):
		apply_delta(state, entry.get("lines", []))
		result.append(_expand(state))
	return result


## The first point where two traces differ, or {} when they match. {"i", "fields": [names that differ], "a": point or
## null, "b": point or null (null: that trace ended), "only_a"/"only_b": canonical lines in one side only (when both
## traces have lines)}. Points are returned without their lines.
static func diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var points_a: Array = a.get("points", [])
	var points_b: Array = b.get("points", [])
	var lined := _has_lines(points_a) and _has_lines(points_b)
	var state_a := {}
	var state_b := {}
	for index in maxi(points_a.size(), points_b.size()):
		var pa: Variant = points_a[index] if index < points_a.size() else null
		var pb: Variant = points_b[index] if index < points_b.size() else null
		if pa == null or pb == null:
			return {"i": index, "fields": ["end"], "a": _bare(pa), "b": _bare(pb), "only_a": [], "only_b": []}
		if lined:
			apply_delta(state_a, pa.get("lines", []))
			apply_delta(state_b, pb.get("lines", []))
		var fields: Array[String] = []
		for field in ["kind", "turn", "actor", "ability", "target", "hash"]:
			if pa.get(field) != pb.get(field):
				fields.append(field)
		if not fields.is_empty():
			var result := {"i": index, "fields": fields, "a": _bare(pa), "b": _bare(pb), "only_a": [], "only_b": []}
			if lined:
				result["only_a"] = Array(_expand(_minus(state_a, state_b)))
				result["only_b"] = Array(_expand(_minus(state_b, state_a)))
			return result
	return {}


## Plain text for a diff result, printed by every user of the diff.
static func describe(divergence: Dictionary) -> String:
	if divergence.is_empty():
		return "traces match"
	var a: Variant = divergence["a"]
	var b: Variant = divergence["b"]
	var lines := PackedStringArray()
	if a == null or b == null:
		var longer: Dictionary = a if a != null else b
		lines.append("first divergence at point %d: trace %s ends there; the other goes on with %s" % [divergence["i"],
			"a" if a == null else "b", _action_text(longer)])
		return "\n".join(lines)
	lines.append("first divergence at point %d (%s)" % [divergence["i"], _action_text(a)])
	for field in divergence["fields"]:
		lines.append("  %s: a=%s  b=%s" % [field, a.get(field), b.get(field)])
	for line in divergence.get("only_a", []):
		lines.append("  - " + str(line))
	for line in divergence.get("only_b", []):
		lines.append("  + " + str(line))
	return "\n".join(lines)


static func _action_text(entry: Dictionary) -> String:
	var parts := PackedStringArray(["turn %d" % int(entry.get("turn", 0)), str(entry.get("kind"))])
	for field in ["actor", "ability", "target"]:
		if entry.get(field) != null:
			parts.append(str(entry[field]))
	return ", ".join(parts)


static func _id_or_null(id: StringName) -> Variant:
	return null if id == &"" else String(id)


static func _counts(lines: PackedStringArray) -> Dictionary:
	var result := {}
	for line in lines:
		result[line] = int(result.get(line, 0)) + 1
	return result


static func _minus(state: Dictionary, other: Dictionary) -> Dictionary:
	var result := {}
	for line in state:
		var left := int(state[line]) - int(other.get(line, 0))
		if left > 0:
			result[line] = left
	return result


static func _expand(state: Dictionary) -> PackedStringArray:
	var result := PackedStringArray()
	for line in state:
		for count in int(state[line]):
			result.append(line)
	result.sort()
	return result


static func _has_lines(points_list: Array) -> bool:
	return not points_list.is_empty() and points_list[0].has("lines")


static func _bare(entry: Variant) -> Variant:
	if entry == null:
		return null
	var copy: Dictionary = entry.duplicate()
	copy.erase("lines")
	return copy
