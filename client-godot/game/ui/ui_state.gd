## Spec ui-framework 2.2: the UI state tags, derived from GameMain's mode and the run (never stored, never part of a
## run or its hash). The UI policy's rules match these with GameplayTagQuery.
class_name UIState
extends RefCounted

const MENU: StringName = &"UI.State.Menu"
const RUN: StringName = &"UI.State.Run"
const MAP: StringName = &"UI.State.Run.Map"
const BATTLE: StringName = &"UI.State.Run.Battle"
const EVENT: StringName = &"UI.State.Run.Event"
const REST: StringName = &"UI.State.Run.Event.Rest"
const PICKUP: StringName = &"UI.State.Run.Pickup"
const STAIRS: StringName = &"UI.State.Run.Stairs"
const CHOICE: StringName = &"UI.State.Run.Stairs.Choice"
const END: StringName = &"UI.State.End"
const WON: StringName = &"UI.State.End.Won"
const LOST: StringName = &"UI.State.End.Lost"
const STOPPED: StringName = &"UI.State.End.Stopped"
const SANDBOX: StringName = &"UI.State.Sandbox"
## Spec ff7-ui 2.12: a menu screen (the GameMenu layer) is open over the run; the HUD panels it would cover hide.
## Set by UIManager from its stacks (not from the run), so compute() never gives it.
const MENU_OPEN: StringName = &"UI.State.Run.Menu"
## Every tag this file can give (for the tag checkpoint).
const ALL: Array[StringName] = [MENU, RUN, MAP, BATTLE, EVENT, REST, PICKUP, STAIRS, CHOICE, END, WON, LOST, STOPPED,
	SANDBOX, MENU_OPEN]


## The tags for GameMain's mode ("menu", "run", "end") and `run`, sorted.
static func compute(mode: String, run: RunController) -> Array[StringName]:
	var tags: Array[StringName] = []
	var state := run.state if run != null else null
	match mode:
		"menu":
			tags.append(MENU)
		"end":
			tags.append(END)
			if state == null or (run != null and run.runner_error != ""):
				tags.append(STOPPED)
			elif state.status == RunState.WON:
				tags.append(WON)
			else:
				tags.append(LOST)
		"run":
			tags.append(RUN)
			if state != null and state.map != null:
				_run_tags(run, state, tags)
	if state != null and state.sandbox:
		tags.append(SANDBOX)
	tags.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	return tags


static func _run_tags(run: RunController, state: RunState, tags: Array[StringName]) -> void:
	if not run.pending_battle.is_empty():
		tags.append(BATTLE)
		return
	if not state.event.is_empty():
		tags.append(EVENT)
		if state.event.has("rest_to"):
			tags.append(REST)
		return
	tags.append(MAP)
	var cell: Dictionary = state.map.cells.get(state.current_cell, {})
	if cell.get("cleared", false) and cell.get("pickups", []).any(func(pickup) -> bool: return not pickup["taken"]):
		tags.append(PICKUP)
	if state.boss_cleared and not run.is_last_floor() and state.status == RunState.ACTIVE and not state.sandbox:
		tags.append(STAIRS)
		if not run.next_floor_choices().is_empty():
			tags.append(CHOICE)
