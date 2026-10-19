## Reads an ability's animation into its execution sequence (spec "Execution sequence").
##
## The animation is the source of truth for what executes: every method-track key calling `execute(&"<row id>")`,
## sorted by (time, track index, key index), becomes one entry. Other method keys (sound, VFX) are ignored.
## Read at runtime and cached per Animation resource, so it can never go stale after an animation is edited.
## Client and headless use this same reader, so they can't disagree.
class_name ExecutionReader
extends RefCounted

const EXECUTE_METHOD: StringName = &"execute"

static var _cache: Dictionary = {}  # Animation -> Array[StringName]


## The ordered row ids for an animation. Empty when the animation has no execute keys.
static func sequence_for(animation: Animation) -> Array[StringName]:
	if animation == null:
		return []
	if _cache.has(animation):
		return _cache[animation]
	var found := _execute_keys(animation)
	found.sort_custom(func(a: Array, b: Array) -> bool: return _key_order(a, b))
	var sequence: Array[StringName] = []
	for found_key in found:
		sequence.append(found_key[3])
	_cache[animation] = sequence
	return sequence


## Problems that make an ability unusable in combat. Empty when valid.
static func validate(ability: BattleAbility) -> PackedStringArray:
	var problems := PackedStringArray()
	var label := String(ability.ability_tag)
	if ability.animation == null:
		problems.append("%s: no animation (every ability needs one)" % label)
		return problems
	var ids := {}
	for row in ability.executions:
		if row == null or row.id == &"":
			problems.append("%s: execution row without an id" % label)
		elif ids.has(row.id):
			problems.append("%s: duplicate execution row id '%s'" % [label, row.id])
		else:
			ids[row.id] = true
	var sequence := sequence_for(ability.animation)
	if sequence.is_empty():
		problems.append("%s: animation has no execute keys" % label)
	for row_id in sequence:
		if not ids.has(row_id):
			problems.append("%s: animation executes missing row '%s'" % [label, row_id])
	return problems


static func clear_cache() -> void:
	_cache.clear()


## Unsorted [time, track index, key index, row id] for every execute key.
## Kept in separate functions on purpose: collecting, sorting and reading the entries inside one static function
## produced corrupted entries in Godot 4.7.2 (local slot reuse). tests/combat/test_execution.gd pins the result.
static func _execute_keys(animation: Animation) -> Array:
	var found: Array = []
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_METHOD:
			continue
		for key in animation.track_get_key_count(track):
			if animation.method_track_get_name(track, key) == EXECUTE_METHOD:
				found.append(_key_entry(animation, track, key))
	return found


static func _key_entry(animation: Animation, track: int, key: int) -> Array:
	var args := animation.method_track_get_params(track, key)
	var row_id := StringName(str(args[0])) if not args.is_empty() else &""
	return [animation.track_get_key_time(track, key), track, key, row_id]


static func _key_order(a: Array, b: Array) -> bool:
	if a[0] != b[0]:
		return a[0] < b[0]
	if a[1] != b[1]:
		return a[1] < b[1]
	return a[2] < b[2]
