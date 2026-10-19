## Test-only scripted player for whole runs (spec game-skeleton section 6, test_run_scripted).
##
## Policy, all deterministic: battles use ScriptedController; events take the first enabled choice; in a cleared room
## take every free pickup and buy what is affordable (for the first member who can hold it); once per floor use the
## first field option; then enter the unvisited room with the lowest index next to a visited one; after the boss go to
## the next floor. Stops when the run ends or after `max_steps`.
class_name RunPlayer
extends RefCounted


static func play(run: RunController, max_steps: int = 400) -> void:
	var used_field_on := -1
	for step in max_steps:
		if run.state.status != RunState.ACTIVE or run.runner_error != "":
			return
		if not run.pending_battle.is_empty():
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
				return
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
			return
		run.enter_room(next)


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
		for member in run.state.party:
			if run.can_hold(member["slot"], run.content.items[pickup["item"]]) == "":
				run.take(pickup["placement"], member["slot"])
				break


## A RunController under `host`, started on the fixtures with the given party and seed.
static func start(host: Node, seed_text: String, party: Array = ["fixture.character.knight", "fixture.character.medic",
		"fixture.character.rogue"]) -> RunController:
	var run := RunController.new()
	host.add_child(run)
	var error := run.start_run(TestCase.fixtures(), party, seed_text)
	if error != "":
		push_error("RunPlayer.start: " + error)
	return run
