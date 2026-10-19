## FIFO queue of triggered passives (spec game-skeleton 3.4, decision 10).
##
## GodotGAS activates abilities whose trigger_event_tag matches an event immediately and without awaiting them, which
## would interleave coroutines nondeterministically. CombatASC.send_gameplay_event enqueues them here instead, and the
## battle drains the queue at fixed points (after each action, turn start and turn end), awaiting each activation.
class_name TriggerQueue
extends RefCounted

## A chain deeper than this (triggers caused by triggers caused by...) stops, the same way every time.
const MAX_DEPTH: int = 10

var draining: bool = false
## Depth of the entry being activated while draining; new entries go one deeper.
var current_depth: int = 0
var _entries: Array[Dictionary] = []


## entry: {"unit": BattleUnit, "ability": BattleAbility, "event_tag": StringName, "payload": Variant}
func push(unit: Node, ability: BattleAbility, event_tag: StringName, payload: Variant) -> void:
	_entries.append({
		"unit": unit,
		"ability": ability,
		"event_tag": event_tag,
		"payload": payload,
		"depth": current_depth + 1 if draining else 0,
	})


func pop() -> Dictionary:
	return _entries.pop_front()


func is_empty() -> bool:
	return _entries.is_empty()


func clear() -> void:
	_entries.clear()
