## Spec bot-play 2.2: how the smart run bot explores a floor. Pure and static. A floor is explored FULL (every reachable
## room before the boss) when what its floor rules can place is worth at least the profile's threshold, else BOSS (the
## shortest known way to the boss, a challenge room found on the way fought first). The bot sees what a player could:
## visited rooms and their neighbours, the room types the map shows (RunController.room_type_known) and the chapter's
## floor rules; never an unrevealed room's content.
class_name ExplorePlan
extends RefCounted

const FULL: String = "full"
const BOSS: String = "boss"


## The loot value of the current floor: the profile's room value of each special room tag the chapter's floor rules can
## place (a tag listed 4 times counts 4 times). A floor with no rules (a fixed layout) counts the special rooms its map
## holds instead.
static func loot_value(run: RunController, profile: BotProfile) -> int:
	var total := 0
	var current := run.chapter()
	var rules: FloorGenRules = current.floor_gen_rules if current != null else null
	if rules != null:
		for tag in rules.special_room_tags:
			total += profile.room_value(tag)
		return total
	for index in run.state.map.sorted_indices():
		var data: Dictionary = run.state.map.cells[index]
		if data["role"] == FloorMap.ROLE_SPECIAL:
			total += profile.room_value(data["special_tag"])
	return total


## FULL or BOSS for the current floor (the profile's `explore` forces one).
static func mode(run: RunController, profile: BotProfile) -> String:
	if profile.explore == BotProfile.EXPLORE_FULL:
		return FULL
	if profile.explore == BotProfile.EXPLORE_BOSS:
		return BOSS
	return FULL if loot_value(run, profile) >= profile.explore_threshold else BOSS


## The room to enter next on the current floor in `floor_mode`, or -1 when nothing is left.
static func next_room(run: RunController, profile: BotProfile, floor_mode: String) -> int:
	var unvisited := func(index: int) -> bool:
		var data: Dictionary = run.state.map.cells[index]
		return not data["visited"] and data["role"] != FloorMap.ROLE_BOSS and not run.room_locked(index)
	if floor_mode == FULL and not profile.exploratory:
		# Not exploratory (user, 2026-11-22): the loot rooms the map shows first, then explore only to find the rest;
		# once every room the floor rules value is visited (or locked with no key), go the boss's way.
		if not loot_done(run, profile):
			var loot := nearest(run, func(index: int) -> bool:
				var data: Dictionary = run.state.map.cells[index]
				return not data["visited"] and data["role"] == FloorMap.ROLE_SPECIAL and not run.room_locked(index) \
					and profile.room_value(data["special_tag"]) > 0)
			if loot != -1:
				return loot
			var opening := locked_target(run, profile)
			if opening != -1:
				return opening
			var search := nearest(run, unvisited)
			if search != -1:
				return search
		floor_mode = BOSS
	if floor_mode == FULL:
		var next := nearest(run, unvisited)
		if next != -1:
			return next
		var locked := locked_target(run, profile)
		if locked != -1:
			return locked
		return boss_target(run)
	# BOSS: a challenge room found on the way, a locked loot room the keys open, the boss once it shows, else explore.
	var challenge := nearest(run, func(index: int) -> bool:
		var data: Dictionary = run.state.map.cells[index]
		return str(data["content"].get("kind", "")) == "waves" and not data["cleared"] and not run.room_locked(index))
	if challenge != -1:
		return challenge
	var locked := locked_target(run, profile)
	if locked != -1:
		return locked
	var boss := boss_target(run)
	if boss != -1:
		return boss
	return nearest(run, unvisited)


## Whether every room the floor rules value (profile.room_value > 0, a tag listed twice counts twice) has been handled:
## visited, or shown on the map but locked with no key or golden key to open it. A fixed layout counts its own special
## rooms. A floor that placed fewer than its rules list is never done (the bot explores it fully).
static func loot_done(run: RunController, profile: BotProfile) -> bool:
	var expected := 0
	var current := run.chapter()
	var rules: FloorGenRules = current.floor_gen_rules if current != null else null
	var map := run.state.map
	if rules != null:
		for tag in rules.special_room_tags:
			if profile.room_value(tag) > 0:
				expected += 1
	var handled := 0
	var no_key := run.state.keys <= 0 and not run.state.golden_key
	for index in map.sorted_indices():
		var data: Dictionary = map.cells[index]
		if data["role"] != FloorMap.ROLE_SPECIAL or profile.room_value(data["special_tag"]) <= 0:
			continue
		if rules == null:
			expected += 1
		if data["visited"] or no_key and run.room_locked(index) and BotGear.shown(run, index):
			handled += 1
	return handled >= expected


## The enterable cell passing `wanted` that is nearest to the current room by steps through visited rooms (ties to the
## lowest index), or -1.
static func nearest(run: RunController, wanted: Callable) -> int:
	var map := run.state.map
	var steps := {run.state.current_cell: 0}
	var queue: Array[int] = [run.state.current_cell]
	while not queue.is_empty():
		var current: int = queue.pop_front()
		for next in map.neighbours(current):
			if not steps.has(next) and map.cells[next]["visited"]:
				steps[next] = steps[current] + 1
				queue.append(next)
	var best := -1
	var best_steps := 0
	for index in map.sorted_indices():
		if not run.can_enter(index) or not wanted.call(index):
			continue
		var distance := -1
		for neighbour in map.neighbours(index):
			if steps.has(neighbour) and (distance == -1 or int(steps[neighbour]) + 1 < distance):
				distance = int(steps[neighbour]) + 1
		if distance == -1:
			distance = 1 << 20  # next to a visited room the walk from here can't reach (never on a connected floor)
		if best == -1 or distance < best_steps:
			best = index
			best_steps = distance
	return best


## The boss room when it can be entered now, else -1.
static func boss_target(run: RunController) -> int:
	for index in run.state.map.sorted_indices():
		if run.state.map.cells[index]["role"] == FloorMap.ROLE_BOSS and run.can_enter(index) \
				and not run.state.map.cells[index]["visited"]:
			return index
	return -1


## An enterable locked room the party can open now (keys or the golden key): the one the profile values most (item rooms
## first with the default values), ties to the nearest; -1 none.
static func locked_target(run: RunController, profile: BotProfile) -> int:
	if run.state.keys <= 0 and not run.state.golden_key:
		return -1
	var best_value := -1
	for index in run.state.map.sorted_indices():
		if run.can_enter(index) and run.room_locked(index):
			best_value = maxi(best_value, profile.room_value(run.state.map.cells[index]["special_tag"]))
	if best_value < 0:
		return -1
	return nearest(run, func(index: int) -> bool:
		return run.room_locked(index) and profile.room_value(run.state.map.cells[index]["special_tag"]) == best_value)
