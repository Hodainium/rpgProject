## Scripted player for whole runs (spec game-skeleton section 6, test_run_scripted; spec playable-demo 2.3: the play
## report and `autorun`). Dev and tests only.
##
## Policy, all deterministic: battles use ScriptedController (or `battle`, which must fight the pending battle); events
## take the first enabled choice; in a cleared room take every free pickup and buy what is affordable (for the first
## member who can hold it); once per floor use the first field option; then enter the unvisited room with the lowest
## index next to a visited one; after the boss go to the next floor. Stops when the run ends or after `max_steps`.
## Returns "" (the run ended or stopped on a runner error), "stuck" (nothing left to do) or "step cap".
class_name RunPlayer
extends RefCounted


static func play(run: RunController, max_steps: int = 400, battle: Callable = Callable()) -> String:
	var used_field_on := -1
	for step in max_steps:
		if run.state.status != RunState.ACTIVE or run.runner_error != "":
			return ""
		if not run.pending_battle.is_empty():
			if battle.is_valid():
				await battle.call(run)
			else:
				await run.fight(ScriptedController.new())
			continue
		if not run.state.event.is_empty():
			var page := run.current_page()
			var picked := -1
			for index in page.choices.size():
				if run.choice_enabled(index):
					picked = index
					break
			if picked == -1:
				return "stuck"
			run.choose(picked)
			continue
		_take_pickups(run)
		if used_field_on != run.state.floor_index:
			used_field_on = run.state.floor_index
			var options := run.field_options()
			if not options.is_empty():
				var option: Dictionary = options[0]
				var targets: Array = option["targets"]
				await run.use_field(option["slot"], option["ability"], targets[0] if not targets.is_empty() else 0)
				continue
		if run.state.boss_cleared and not run.is_last_floor():
			run.next_floor()
			continue
		var next := next_room(run)
		if next == -1:
			return "stuck"
		run.enter_room(next)
	return "" if run.state.status != RunState.ACTIVE or run.runner_error != "" else "step cap"


static func next_room(run: RunController) -> int:
	for index in run.state.map.sorted_indices():
		if not run.state.map.cells[index]["visited"] and run.can_enter(index):
			return index
	return -1


static func _take_pickups(run: RunController) -> void:
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	if not data["cleared"]:
		return
	for pickup in data["pickups"]:
		if pickup["taken"] or pickup["price"] > run.state.coins:
			continue
		if pickup.get("kind", "") == FloorGenerator.EQUIPMENT_KIND:
			run.take(pickup["placement"], run.state.party[0]["slot"])  # armor goes to the armor inventory (item-pass 3.5)
			continue
		for member in run.state.party:
			if run.can_hold(member["slot"], run.content.items[pickup["item"]]) == "":
				run.take(pickup["placement"], member["slot"])
				break

