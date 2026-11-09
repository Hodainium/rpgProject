## A run_log entry on the wire (spec server-authority 3.1): RunController's log entries as Rpg.Contracts
## RunActionRequest dictionaries (camelCase, unused fields left out, field order as in the C# record), and back:
## apply() plays a wire action on a run through the same RunController methods as play, which is how a resume tail is
## replayed (2.4). The analytics fields (item, character, price, coins, offers) are read from the run right after the
## action; they are claims, checked by replay like the rest.
class_name RunWire
extends RefCounted

## Entry types that always carry a snapshot; an action that leaves a battle pending does too (RunController).
const CHECKPOINTS: Array[String] = ["start_run", "battle", "next_floor"]
## Spec run-verify 2.2: a snapshot is also attached once this many actions have gone by since the last one, so a step stays short.
const CHECKPOINT_EVERY: int = 100
const TREASURE_TAG: StringName = &"Room.Type.Treasure"


## The RunActionRequest for `entry` (logged as seq `seq`): {seq, action, stateHash, playedAt[, snapshot]}.
static func request(run: RunController, entry: Dictionary, seq: int, state_hash: String, snapshot: Dictionary,
		conditions: Dictionary) -> Dictionary:
	var result := {"seq": seq, "action": action(run, entry, conditions), "stateHash": state_hash,
		"playedAt": Time.get_datetime_string_from_system(true) + "Z"}
	if not snapshot.is_empty():
		result["snapshot"] = snapshot
	return result


## The RunAction record for `entry`, in the record's field order.
static func action(run: RunController, entry: Dictionary, conditions: Dictionary) -> Dictionary:
	var state := run.state
	var type := str(entry["type"])
	var fields := {"floor": int(entry.get("floor", state.floor_index))}
	match type:
		"enter_room":
			fields["cell"] = entry["cell"]
		"choose":
			fields["cell"] = entry["cell"]
			fields["page"] = entry["page"]
			fields["choice"] = entry["choice"]
		"take", "buy":
			fields["cell"] = entry["cell"]
			fields["placement"] = entry["placement"]
			if entry.has("slot"):
				fields["slot"] = entry["slot"]
		"field":
			fields["slot"] = entry["slot"]
			fields["ability"] = entry["ability"]
			fields["target"] = entry["target"]
		"equip":
			fields["slot"] = entry["slot"]
		"unequip":
			fields["slot"] = entry["slot"]
		"swap_gear":
			fields["slot"] = entry["slot"]
		"move_item":
			fields["slot"] = entry["slot"]
		"give_to":
			fields["cell"] = entry["cell"]
			fields["slot"] = entry["slot"]
		"battle":
			fields["cell"] = entry["cell"]
	match type:
		"take", "buy":
			var pickup := _pickup(state, int(entry["cell"]), int(entry["placement"]))
			var kind := str(entry.get("kind", ""))
			fields["itemId"] = str(pickup.get("item", ""))
			fields["kind"] = "Keys" if kind == FloorGenerator.KEYS_KIND \
				else "Equipment" if kind == FloorGenerator.EQUIPMENT_KIND else "Item"
			if fields["kind"] == "Item" and entry.has("slot"):
				fields["characterId"] = String(state.member(int(entry["slot"])).get("character", &""))
		"field":
			if entry.get("item") != null:
				fields["itemId"] = entry["item"]
			fields["characterId"] = String(state.member(int(entry["slot"])).get("character", &""))
		"give_to":
			fields["itemId"] = entry["item"]
		"move_item":
			fields["itemId"] = entry["item"]
	match type:
		"equip", "swap_gear":
			fields["equipmentId"] = entry["equipment"]
		"unequip":
			fields["equipmentSlot"] = entry["equipment_slot"]
	if type == "swap_gear":
		fields["fromSlot"] = entry["from"]
	if type == "move_item":
		fields["toSlot"] = entry["to"]
		if entry.get("swap") != null:
			fields["swapItemId"] = entry["swap"]
	if type == "open_chest":
		fields["chestId"] = entry["chest"]
		fields["serial"] = entry["serial"]
	if entry.has("unlock"):
		fields["unlock"] = entry["unlock"]
	if type == "next_floor" and entry.has("chapter"):
		fields["chapter"] = entry["chapter"]
	if type in ["take", "buy"]:
		var pickup := _pickup(state, int(entry["cell"]), int(entry["placement"]))
		fields["price"] = int(pickup.get("price", 0))
		if pickup.has("priceItem"):
			fields["priceItemId"] = String(pickup["priceItem"])
	fields["coinsAfter"] = state.coins
	if type == "enter_room":
		fields["offers"] = offers(state, int(entry["cell"]))
	if type == "battle":
		fields["battle"] = {"battleId": entry["battleId"], "conditions": conditions, "actionLog": entry["actionLog"]}
	# The record's field order: type, floor, then the optional fields as RunAction declares them.
	var ordered := {"type": type}
	for key in ["floor", "cell", "page", "choice", "placement", "slot", "ability", "target", "itemId", "kind",
			"characterId", "equipmentId", "equipmentSlot", "fromSlot", "toSlot", "swapItemId", "chestId", "serial",
			"unlock", "chapter", "price", "priceItemId", "coinsAfter", "offers", "battle"]:
		if fields.has(key):
			ordered[key] = fields[key]
	return ordered


## Every pickup on offer in `cell` (ItemOffer records).
static func offers(state: RunState, cell: int) -> Array:
	var data: Dictionary = state.map.cells.get(cell, {})
	var result: Array = []
	for pickup in data.get("pickups", []):
		var kind := str(pickup.get("kind", ""))
		var source := "Other"
		if data["role"] == FloorMap.ROLE_BOSS:
			source = "BossReward"
		elif int(pickup["price"]) > 0 or pickup.has("priceItem"):
			source = "Shop"
		elif data["role"] == FloorMap.ROLE_SPECIAL and data["special_tag"] == TREASURE_TAG:
			source = "Treasure"
		result.append({"placement": pickup["placement"], "itemId": str(pickup["item"]), "price": pickup["price"],
			"source": source, "kind": "Keys" if kind == FloorGenerator.KEYS_KIND
				else "Equipment" if kind == FloorGenerator.EQUIPMENT_KIND else "Item"})
	return result


## Plays one wire action (a RunAction dictionary) on `run` through its public methods. "" or why it failed.
## start_run and end entries are not actions to play: the run start is the snapshot, a Lost end follows its battle.
static func apply(run: RunController, wire: Dictionary) -> String:
	var type := str(wire["type"])
	match type:
		"start_run", "end":
			return ""
		"enter_room":
			return run.enter_room(int(wire["cell"]))
		"choose":
			return run.choose(int(wire["choice"]))
		"take", "buy":
			return run.take(int(wire["placement"]), int(wire.get("slot", 0)))
		"field":
			var problem: Array = await run.use_field(int(wire["slot"]), StringName(str(wire["ability"])),
				int(wire.get("target", 0)))
			return "" if problem.is_empty() else "%s: %s" % problem
		"equip":
			return run.equip(int(wire["slot"]), StringName(str(wire["equipmentId"])))
		"unequip":
			return run.unequip(int(wire["slot"]), StringName(str(wire["equipmentSlot"])))
		"swap_gear":
			return run.swap_gear(int(wire["slot"]), StringName(str(wire["equipmentId"])))
		"move_item":
			return run.move_item(int(wire["slot"]), StringName(str(wire["itemId"])), int(wire["toSlot"]),
				StringName(str(wire.get("swapItemId", ""))))
		"give_to":
			return run.give_to(int(wire["slot"]))
		"open_chest":
			for index in run.state.chests.size():
				if int(run.state.chests[index]["serial"]) == int(wire["serial"]):
					return run.open_chest(index)
			return "no chest with serial %d" % int(wire["serial"])
		"battle":
			var battle: Dictionary = wire["battle"]
			var expected: String = str(run.battle_snapshot()["battleId"]) if not run.pending_battle.is_empty() else ""
			if expected != str(battle["battleId"]):
				return "battle %s is not the pending one (%s)" % [battle["battleId"], expected]
			return await run.fight(LoggedBattle.new(battle["actionLog"]["actions"]))
		"next_floor":
			return run.next_floor(StringName(str(wire.get("chapter", ""))))
	return "unknown action type %s" % type


## Spec run-verify 2.2: the replay of a logged action against what the client claimed. A floor's seed reaches a client at some
## moment the log does not record, so the replay hands out the server's seeds lazily instead of all at once: a run that waits
## for a floor's seed stays waiting until the claimed hash shows it had the seed (`hash_matches`) or the next action proves it.
## Returns true when the run is waiting for a floor whose seed `seeds` (floor → int) holds, and gives it to the run.
static func provide_waiting(run: RunController, seeds: Dictionary) -> bool:
	var waiting := run.waiting_for_floor()
	if waiting < 0 or not seeds.has(waiting):
		return false
	run.provide_floor_seed(waiting, int(seeds[waiting]))
	return true


## Whether the run's state hash is `claimed`, in either of the two states the client can have been in: still waiting for the
## floor's seed, or already holding it (then the seed is handed over and the hash taken again).
static func hash_matches(run: RunController, claimed: String, seeds: Dictionary) -> bool:
	if run.state.run_hash() == claimed:
		return true
	return provide_waiting(run, seeds) and run.state.run_hash() == claimed


static func _pickup(state: RunState, cell: int, placement: int) -> Dictionary:
	for pickup in state.map.cells.get(cell, {}).get("pickups", []):
		if int(pickup["placement"]) == placement:
			return pickup
	return {}


## Replays a logged battle's party decisions (the verifier's ReplayController) and hands fight() the same entries.
class LoggedBattle:
	extends ReplayRunner.ReplayController

	var entries: Array[Dictionary] = []

	func _init(logged: Array) -> void:
		super(logged)
		for entry in logged:
			entries.append(entry)
