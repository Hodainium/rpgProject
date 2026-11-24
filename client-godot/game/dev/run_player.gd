## Scripted player for whole runs (spec game-skeleton section 6, test_run_scripted; spec playable-demo 2.3: the play
## report and `autorun`). Dev and tests only.
##
## Policy, all deterministic: battles use ScriptedController (or `battle`, which must fight the pending battle); events
## (spec event-pass 2.8) take a class choice when one is enabled, else a random enabled choice (`events` "random") or the
## best-scoring one ("smart"), drawn from the bots' own stream dev/event/...; in a cleared room take every free pickup and buy what is affordable (for the first
## member who can hold it); once per floor use the first field option; then enter the unvisited room with the lowest
## index next to a visited one; after the boss go to the next floor (a route choice drawn from the policy's own stream
## dev/route/<floor>). Stops when the run ends or after `max_steps`.
## Spec keys-and-gear 3.5: on the map it also opens every chest it can (a Gilded one only with a key to spare after the
## floor's locked rooms), wears found gear in empty slots (first living member by slot), and opens locked rooms it can
## afford, item rooms before shops, before it would enter the boss room. Runs without keys play exactly as before.
## Spec event-items: an item waiting for its holder goes to the first living member who can hold it.
## `chaos` (the chaos policy): {"rng", "illegal_x100", "violations": Array, "refused": Dictionary}: at that share of map
## steps it first tries a run action that must be refused (RUN_CASES) and checks that nothing changed.
## Spec bot-play: with a BotProfile (`bot`, the smart and chaos policies) the run decisions are the smart run bot's:
## each floor explored FULL or straight to the BOSS by what its floor rules can place (ExplorePlan), every free pickup
## to the member who values it most and the shelf bought by value ÷ price (BotGear, LootScorer), gear worn, upgraded and
## swapped and use items moved by the profile's margin, field actions by what the party needs. `bot = null` is the old
## behaviour above, unchanged. `bot_stats` (bot runs only) collects the play report's blocks: "floors" (per floor: mode,
## rooms visited of generated, things left behind, deaths), "refused" (bot actions the run refused, by action and
## reason: a bot bug), "moves", "shop", "untagged".
## Returns "" (the run ended or stopped on a runner error), "stuck" (nothing left to do) or "step cap".
class_name RunPlayer
extends RefCounted

const RUN_CASES: Array[String] = ["chest_no_key", "chest_missing", "locked_no_key", "swap_not_worn", "swap_self",
	"move_not_held", "move_full", "give_nothing", "take_drop_twice"]
const TREASURE_TAG: StringName = &"Room.Type.Treasure"


static func play(run: RunController, max_steps: int = 400, battle: Callable = Callable(), chaos: Dictionary = {},
		events: String = EventScorer.POLICY_RANDOM, bot: BotProfile = null, bot_stats: Dictionary = {}) -> String:
	if bot == null:
		return await _play(run, max_steps, battle, chaos, events, null, bot_stats)
	BotCache.begin(run)
	var stop := await _play(run, max_steps, battle, chaos, events, bot, bot_stats)
	BotCache.end(run)
	_close_floor(run, bot_stats)  # however the play stopped
	return stop


static func _play(run: RunController, max_steps: int, battle: Callable, chaos: Dictionary, events: String, bot: BotProfile,
		bot_stats: Dictionary) -> String:
	var used_field_on := -1
	var plan := {"floor": -1, "mode": "", "field_for": "", "alive": {}}
	if bot != null:
		for key in ["floors", "refused", "moves", "shop"]:
			bot_stats.get_or_add(key, [] if key == "floors" else {})
	for step in max_steps:
		if bot != null:
			_track_floor(run, bot, plan, bot_stats)
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
			var holder := BotGear.holder_for(run, bot, run.pending_gift()) if _uses(bot, "placement") \
				else gift_holder(run, run.pending_gift())
			if holder == 0:
				return "stuck"
			var gift_problem := run.give_to(holder)
			if gift_problem != "":
				if bot != null:
					BotGear._act(run, bot_stats, "give_to", gift_problem)
				return "stuck"
			continue
		if not run.state.event.is_empty():
			# Spec event-pass 2.8: class choices first, then the smart scorer or a random enabled choice (the bots' stream).
			var page := run.current_page()
			var enabled: Array = []
			for index in page.choices.size():
				if run.choice_enabled(index):
					enabled.append(index)
			var picked := EventScorer.pick(run, enabled, events)
			if picked == -1:
				return "stuck"
			run.choose(picked)
			continue
		_open_chests(run)  # spec floor-chests: open the room's chests first, then take what they put out with the rest
		# Spec bot-play 2.7: each of the bot's parts can be off (measured alone); an off part plays as before.
		if _uses(bot, "placement"):
			BotGear.take_free(run, bot, bot_stats)
		else:
			_take_pickups(run, true, not _uses(bot, "shop"))
		if _uses(bot, "shop"):
			BotGear.shop(run, bot, bot_stats)
		elif _uses(bot, "placement"):
			_take_pickups(run, false, true)
		if _uses(bot, "gear"):
			BotGear.improve(run, bot, bot_stats)
		else:
			_wear_gear(run)
		if bot != null and (run.state.status != RunState.ACTIVE or run.runner_error != ""
				or not run.pending_battle.is_empty() or not run.state.pending_gifts.is_empty()):
			continue  # a pickup's hook ended the run or left something waiting: the loop's start handles it
		if not chaos.is_empty():
			try_illegal(run, chaos)
		if not _uses(bot, "field") and used_field_on != run.state.floor_index:
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
			if bot != null:
				_close_floor(run, bot_stats)  # counted on this floor's map, before the next one replaces it
				var floor_problem := run.next_floor(pick)
				if floor_problem != "":
					BotGear._act(run, bot_stats, "next_floor", floor_problem)
					return "stuck"
			else:
				run.next_floor(pick)
			continue
		var next := ExplorePlan.next_room(run, bot, plan["mode"]) if _uses(bot, "explore") else next_room(run)
		if next == -1:
			return "stuck"
		if bot != null:
			# Spec bot-play 2.6: field actions before the room, once per room (a revive, a heal before a fight).
			var key := "%d/%d" % [run.state.floor_index, next]
			if _uses(bot, "field") and plan["field_for"] != key:
				plan["field_for"] = key
				if await BotGear.field_before(run, bot, next, bot_stats) > 0:
					continue
			BotGear._act(run, bot_stats, "enter_room", run.enter_room(next))
			continue
		run.enter_room(next)
	return "" if run.state.status != RunState.ACTIVE or run.runner_error != "" else "step cap"


## Spec bot-play 2.7: opens the floor's record when a new floor starts (its mode from ExplorePlan) and counts member deaths
## on it (a member alive at the last step and dead now).
static func _track_floor(run: RunController, bot: BotProfile, plan: Dictionary, bot_stats: Dictionary) -> void:
	if run.state.map != null and plan["floor"] != run.state.floor_index and run.state.status == RunState.ACTIVE \
			and run.waiting_for_floor() < 0:
		_close_floor(run, bot_stats)
		plan["floor"] = run.state.floor_index
		plan["mode"] = ExplorePlan.mode(run, bot) if _uses(bot, "explore") else "lowest"
		var current := run.chapter()
		bot_stats["floors"].append({"floor": run.state.floor_index + 1, "chapter": String(current.id) if current != null else "",
			"mode": plan["mode"], "rooms": run.state.map.cells.size(), "visited": 0, "leftBehind": 0, "deaths": 0,
			"open": true})
	if bot_stats["floors"].is_empty():
		return
	var record: Dictionary = bot_stats["floors"][-1]
	for member in run.state.party:
		if plan["alive"].get(member["slot"], false) and not member["alive"] and record.get("open", false):
			record["deaths"] += 1
		plan["alive"][member["slot"]] = member["alive"]


## Closes the open floor record: rooms visited, and free things left on the floor of visited rooms (keys aside).
static func _close_floor(run: RunController, bot_stats: Dictionary) -> void:
	if bot_stats.get("floors", []).is_empty() or not bot_stats["floors"][-1].get("open", false):
		return
	var record: Dictionary = bot_stats["floors"][-1]
	record.erase("open")
	if run.state.map == null:
		return
	for index in run.state.map.sorted_indices():
		var data: Dictionary = run.state.map.cells[index]
		if not data["visited"]:
			continue
		record["visited"] += 1
		for pickup in data["pickups"]:
			if not pickup["taken"] and int(pickup["price"]) == 0 and str(pickup.get("kind", "")) != FloorGenerator.KEYS_KIND:
				record["leftBehind"] += 1


## Whether the bot (null: none) has `part` on.
static func _uses(bot: BotProfile, part: String) -> bool:
	return bot != null and bot.uses(part)


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
		var challenge := _challenge_target(run)
		if challenge != -1:
			return challenge
	return picked


## Spec floor-rooms: before the boss, a challenge room not yet fought (its waves start on entry), like the locked rooms. When
## it is not next to a visited room yet, the next unvisited room on the way (lowest index, not the boss); -1 none. Runs
## without challenge rooms play exactly as before.
static func _challenge_target(run: RunController) -> int:
	var waiting := false
	for index in run.state.map.sorted_indices():
		var data: Dictionary = run.state.map.cells[index]
		if str(data["content"]["kind"]) == "waves" and not data["cleared"] and not run.room_locked(index):
			if run.can_enter(index):
				return index
			waiting = true
	if not waiting:
		return -1
	for index in run.state.map.sorted_indices():
		var data: Dictionary = run.state.map.cells[index]
		if not data["visited"] and data["role"] != FloorMap.ROLE_BOSS and run.can_enter(index) and not run.room_locked(index):
			return index
	return -1


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


## Opens every chest in the current room it can (spec floor-chests): Wooden ones always; one that costs a key only while a key
## is left over after the floor's locked rooms (or for free: golden key, Run.Chest.NoKey).
static func _open_chests(run: RunController) -> void:
	var opened := true
	while opened and run.state.status == RunState.ACTIVE and run.runner_error == "":
		opened = false
		var locked := 0
		for index in run.state.map.cells:
			if run.room_locked(index):
				locked += 1
		for chest in run.room_chests():
			if not chest["can_open"]:
				continue
			if chest["needs_key"] and not chest["free"] and run.state.keys <= locked:
				continue
			if run.open_chest(chest["serial"]) == "":
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
				for chest in run.room_chests():
					if chest["needs_key"] and not chest["free"] and not chest["opened"]:
						return run.open_chest.bind(chest["serial"])
		"chest_missing":
			return run.open_chest.bind(state.chest_serial)  # spec floor-chests: no chest has this serial yet
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
		"take_drop_twice":  # spec boss-drops 6.11: a battle's drop taken already
			for pickup in run.drop_pickups(state.current_cell):
				if pickup["taken"]:
					return run.take.bind(pickup["placement"], state.party[0]["slot"])
	return Callable()


## Who the bots give a waiting gift to (0 = nobody can hold it). Spec food-items D4: food (Pool.Food) goes to the living
## member with the lowest HP share (hp × 100 / max_hp; ties to the lowest slot); anything else to the first member who
## can hold it. can_hold already refuses the dead.
static func gift_holder(run: RunController, gift: ItemDefinition) -> int:
	if gift == null:
		return 0
	if not TagMatch.has(gift.tags, RunController.DROP_FOOD_POOL):
		return run._first_holder(gift)
	var holders: Array = run.state.party.filter(func(member) -> bool: return run.can_hold(member["slot"], gift) == "")
	if holders.is_empty():
		return 0
	var stats := run.party_stats()
	var best := 0
	var best_share := -1
	for member in holders:
		var max_hp := int(stats.get(member["slot"], {}).get(BattleUnit.MAX_HP, 0))
		if max_hp <= 0:
			continue
		var share := int(member["hp"]) * 100 / max_hp
		if best == 0 or share < best_share or (share == best_share and member["slot"] < best):
			best = member["slot"]
			best_share = share
	return best if best != 0 else holders[0]["slot"]


## Takes the room's pickups the old way (bot = null): `free` the free ones, `priced` what costs coins (spec bot-play 2.7:
## the bot's placement and shop parts can each be off).
static func _take_pickups(run: RunController, free: bool = true, priced: bool = true) -> void:
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	if not data["cleared"]:
		return
	for pickup in data["pickups"]:
		if pickup["taken"] or pickup["price"] > run.state.coins:
			continue
		if not (priced if int(pickup["price"]) > 0 else free):
			continue
		if pickup.get("kind", "") == FloorGenerator.KEYS_KIND:
			run.take(pickup["placement"], run.state.party[0]["slot"])  # spec keys-and-gear D12: keys for sale
			continue
		if pickup.get("kind", "") == FloorGenerator.EQUIPMENT_KIND:
			run.take(pickup["placement"], run.state.party[0]["slot"])  # armor goes to the armor inventory (item-pass 3.5)
			continue
		if pickup.has("chest") or pickup.has("drop"):
			# Spec floor-chests 3.5: a chest's item goes where a gift would (food to the lowest HP share, spec food-items);
			# spec boss-drops 6.11: so does a battle's drop.
			var holder := gift_holder(run, run.content.items[pickup["item"]])
			if holder != 0:
				run.take(pickup["placement"], holder)
			continue
		for member in run.state.party:
			if run.can_hold(member["slot"], run.content.items[pickup["item"]]) == "":
				run.take(pickup["placement"], member["slot"])
				break

