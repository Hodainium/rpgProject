## Scripted player for whole runs (spec game-skeleton section 6, test_run_scripted; spec playable-demo 2.3: the play
## report and `autorun`). Dev and tests only.
##
## Policy, all deterministic: battles use ScriptedController (or `battle`, which must fight the pending battle); events
## take the first enabled choice; in a cleared room take every free pickup and buy what is affordable (for the first
## member who can hold it); once per floor use the first field option; then enter the unvisited room with the lowest
## index next to a visited one; after the boss go to the next floor (a route choice drawn from the policy's own stream
## dev/route/<floor>). Stops when the run ends or after `max_steps`.
## Spec keys-and-gear 3.5: on the map it also opens every chest it can (a Gilded one only with a key to spare after the
## floor's locked rooms), wears found gear in empty slots (first living member by slot), and opens locked rooms it can
## afford, item rooms before shops, before it would enter the boss room. Runs without keys play exactly as before.
## Spec event-items: an item waiting for its holder goes to the first living member who can hold it.
## `chaos` (the chaos policy): {"rng", "illegal_x100", "violations": Array, "refused": Dictionary}: at that share of map
## steps it first tries a run action that must be refused (RUN_CASES) and checks that nothing changed.
## Returns "" (the run ended or stopped on a runner error), "stuck" (nothing left to do) or "step cap".
class_name RunPlayer
extends RefCounted

const RUN_CASES: Array[String] = ["chest_no_key", "chest_index", "locked_no_key", "swap_not_worn", "swap_self",
	"move_not_held", "move_full", "give_nothing"]
const TREASURE_TAG: StringName = &"Room.Type.Treasure"


static func play(run: RunController, max_steps: int = 400, battle: Callable = Callable(), chaos: Dictionary = {}) -> String:
	var used_field_on := -1
	for step in max_steps:
		if run.state.status != RunState.ACTIVE or run.runner_error != "":
			return ""
		if run.waiting_for_floor() >= 0:
			# Spec dev-tools E3: a server run waits at the stairs for its seed; `wait floor <n>` takes it from here.
			return "waiting for floor %d's seed" % run.waiting_for_floor()
		if not run.pending_battle.is_empty():
			if battle.is_valid():
				await battle.call(run)
			else:
				await run.fight(ScriptedController.new())
			continue
		if not run.state.pending_gifts.is_empty():
			var gift := run.pending_gift()
			var holder := 0
			for member in run.state.party:
				if gift != null and run.can_hold(member["slot"], gift) == "":
					holder = member["slot"]
					break
			if holder == 0 or run.give_to(holder) != "":
				return "stuck"
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
		_open_chests(run)
		if not run.state.pending_gifts.is_empty():
			continue  # spec event-items: a chest's item waits for its holder first
		_wear_gear(run)
		if not chaos.is_empty():
			try_illegal(run, chaos)
		if used_field_on != run.state.floor_index:
			used_field_on = run.state.floor_index
			var options := run.field_options()
			if not options.is_empty():
				var option: Dictionary = options[0]
				var targets: Array = option["targets"]
				await run.use_field(option["slot"], option["ability"], targets[0] if not targets.is_empty() else 0)
				continue
		if run.state.boss_cleared and not run.is_last_floor():
			# Spec playable-demo 3.8: a route choice comes from the policy's own stream, never the run's.
			var choices := run.next_floor_choices()
			var pick: StringName = &""
			if choices.size() > 1:
				var route_rng := RunSeeds.rng(run.state.run_seed, "dev/route/%d" % (run.state.floor_index + 1))
				pick = choices[route_rng.randi_range(0, choices.size() - 1)].id
			run.next_floor(pick)
			continue
		var next := next_room(run)
		if next == -1:
			return "stuck"
		run.enter_room(next)
	return "" if run.state.status != RunState.ACTIVE or run.runner_error != "" else "step cap"


static func next_room(run: RunController) -> int:
	var picked := -1
	for index in run.state.map.sorted_indices():
		if not run.state.map.cells[index]["visited"] and run.can_enter(index) and not run.room_locked(index):
			picked = index
			break
	if picked == -1 or run.state.map.cells[picked]["role"] == FloorMap.ROLE_BOSS:
		var locked := _locked_target(run)
		if locked != -1:
			return locked
	return picked


## An enterable locked room the party can open now (keys or the golden key): item rooms first, then the rest; -1 none.
static func _locked_target(run: RunController) -> int:
	if run.state.keys <= 0 and not run.state.golden_key:
		return -1
	var other := -1
	for index in run.state.map.sorted_indices():
		if run.state.map.cells[index]["visited"] or not run.can_enter(index) or not run.room_locked(index):
			continue
		if run.state.map.cells[index]["special_tag"] == TREASURE_TAG:
			return index
		if other == -1:
			other = index
	return other


## Opens every chest it can: Wooden ones always; one that costs a key only while a key is left over after the floor's
## locked rooms (or for free: golden key, Run.Chest.NoKey).
static func _open_chests(run: RunController) -> void:
	var opened := true
	while opened and run.state.status == RunState.ACTIVE and run.runner_error == "":
		opened = false
		var locked := 0
		for index in run.state.map.cells:
			if run.room_locked(index):
				locked += 1
		for chest in run.chests():
			if not chest["can_open"]:
				continue
			if chest["needs_key"] and not chest["free"] and run.state.keys <= locked:
				continue
			if run.open_chest(chest["index"]) == "":
				opened = true
				break


## Wears each piece in the armor inventory on the first living member (by slot) whose slot for it is empty.
static func _wear_gear(run: RunController) -> void:
	for piece_id in run.state.armor.duplicate():
		var piece: EquipmentDefinition = run.content.equipment.get(piece_id)
		if piece == null:
			continue
		for member in run.state.party:
			if member["alive"] and not member["equipment"].has(piece.slot):
				run.equip(member["slot"], piece_id)
				break


## Chaos (spec keys-and-gear 3.5): at chaos["illegal_x100"] of map steps, one run action that must be refused, picked
## from the RUN_CASES that can be built now. A refusal must change nothing: no log entry, the same run hash.
static func try_illegal(run: RunController, chaos: Dictionary) -> void:
	var rng: RandomNumberGenerator = chaos["rng"]
	if not RunSeeds.roll(rng, int(chaos.get("illegal_x100", 2000))):
		return
	var cases: Array[Callable] = []
	var names: Array[String] = []
	for case in RUN_CASES:
		var action := _illegal_action(run, case)
		if action.is_valid():
			cases.append(action)
			names.append(case)
	if cases.is_empty():
		return
	var pick := rng.randi_range(0, cases.size() - 1)
	var before_hash := run.state.run_hash()
	var before_log := run.run_log.size()
	var result: String = cases[pick].call()
	chaos["refused"][names[pick]] = int(chaos["refused"].get(names[pick], 0)) + 1
	var problem := ""
	if result == "":
		problem = "the run accepted it"
	elif run.run_log.size() != before_log:
		problem = "refused (%s) but logged" % result
	elif run.state.run_hash() != before_hash:
		problem = "refused (%s) but the run changed" % result
	if problem != "":
		chaos["violations"].append({"seed": run.state.run_seed, "floor": run.state.floor_index + 1, "battle": 0,
			"encounter": "run action " + names[pick], "invariant": "run_action_not_refused", "case": names[pick],
			"detail": problem})


## The call for an illegal run action `case`, or an invalid Callable when it can't be built now.
static func _illegal_action(run: RunController, case: String) -> Callable:
	var state := run.state
	match case:
		"chest_no_key":
			if state.keys == 0:
				for chest in run.chests():
					if chest["needs_key"] and not chest["free"]:
						return run.open_chest.bind(chest["index"])
		"chest_index":
			return run.open_chest.bind(state.chests.size())
		"locked_no_key":
			if state.keys == 0 and not state.golden_key:
				for index in state.map.sorted_indices():
					if run.can_enter(index) and run.room_locked(index):
						return run.enter_room.bind(index)
		"swap_not_worn":
			if not state.armor.is_empty():
				return run.swap_gear.bind(state.party[0]["slot"], state.armor[0])
		"swap_self":
			for member in state.party:
				for slot_tag in member["equipment"]:
					return run.swap_gear.bind(member["slot"], member["equipment"][slot_tag])
		"move_not_held":
			if state.party.size() > 1:
				for member in state.party:
					for use_slot in member["use_slots"]:
						var other: int = state.party[0]["slot"] if member["slot"] != state.party[0]["slot"] else state.party[1]["slot"]
						return run.move_item.bind(other, use_slot["item"], member["slot"])
		"move_full":
			for giver in state.party:
				for receiver in state.party:
					if giver["slot"] != receiver["slot"] and not giver["use_slots"].is_empty() \
							and receiver["use_slots"].size() >= run.use_capacity(receiver["slot"]):
						return run.move_item.bind(giver["slot"], giver["use_slots"][0]["item"], receiver["slot"])
		"give_nothing":  # spec event-items: give_to with no gift waiting
			if state.pending_gifts.is_empty():
				return run.give_to.bind(state.party[0]["slot"])
	return Callable()


static func _take_pickups(run: RunController) -> void:
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	if not data["cleared"]:
		return
	for pickup in data["pickups"]:
		if pickup["taken"] or pickup["price"] > run.state.coins:
			continue
		if pickup.get("kind", "") == FloorGenerator.KEYS_KIND:
			run.take(pickup["placement"], run.state.party[0]["slot"])  # spec keys-and-gear D12: keys for sale
			continue
		if pickup.get("kind", "") == FloorGenerator.EQUIPMENT_KIND:
			run.take(pickup["placement"], run.state.party[0]["slot"])  # armor goes to the armor inventory (item-pass 3.5)
			continue
		for member in run.state.party:
			if run.can_hold(member["slot"], run.content.items[pickup["item"]]) == "":
				run.take(pickup["placement"], member["slot"])
				break

