## Spec bot-play 2.4-2.6: the smart run bot's item, gear, shop and field decisions. Static; every decision is an
## ordinary logged run action (take, buy, equip, unequip, swap_gear, move_item, use_field) checked by the run like a
## player's. Scores come from LootScorer, numbers from a BotProfile. `stats` collects what the play report shows
## (refusals by action and reason, moves, purchases); pass {} to collect nothing.
class_name BotGear
extends RefCounted

const ROLE_HEAL: StringName = &"Ability.Role.Heal"
const ROLE_REVIVE: StringName = &"Ability.Role.Revive"
const ROLE_RESTORE_MP: StringName = &"Ability.Role.RestoreMP"


## Takes the free pickups of the current (cleared) room (spec 2.4): every one except things marked bad (Item.Curse);
## food to the lowest HP share (spec food-items D4), every other item to the living member who values it most, armor
## into the armor inventory. Priced pickups are left to shop().
static func take_free(run: RunController, profile: BotProfile, stats: Dictionary) -> void:
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	if not data["cleared"]:
		return
	for pickup in data["pickups"].duplicate():
		if pickup["taken"] or int(pickup["price"]) > 0 or not _active(run):
			continue
		var kind := str(pickup.get("kind", ""))
		if kind == FloorGenerator.KEYS_KIND and run.state.keys >= RunStructure.MAX_KEYS:
			continue  # the run refuses keys past the cap
		if kind == FloorGenerator.KEYS_KIND or kind == FloorGenerator.EQUIPMENT_KIND:
			if kind == FloorGenerator.EQUIPMENT_KIND:
				var piece_tags: Array = run.content.equipment[pickup["item"]].tags
				if LootScorer.is_bad(piece_tags) and not pickup.has("priceItem") \
						or not worth_its_price(run, profile, pickup, piece_tags, null):
					continue
			_act(run, stats, "take", run.take(pickup["placement"], run.state.party[0]["slot"]))
			continue
		var item: ItemDefinition = run.content.items[pickup["item"]]
		if LootScorer.is_bad(item.tags) and not pickup.has("priceItem") \
				or not worth_its_price(run, profile, pickup, item.tags, item):
			continue
		var holder := holder_for(run, profile, item)
		if holder != 0 and _act(run, stats, "take", run.take(pickup["placement"], holder)) \
				and LootScorer.fits_of(item.tags).is_empty() and not stats.is_empty():
			stats["untagged"] = int(stats.get("untagged", 0)) + 1  # an untagged item placed by today's rule


## Whether a pickup is worth taking for its price: anything without an item price is; one paid with an item (an altar's
## Void Scar, a curse) only when its best holder values it at least profile.altar_floor (user, 2026-11-22).
static func worth_its_price(run: RunController, profile: BotProfile, pickup: Dictionary, tags: Array,
		item: ItemDefinition) -> bool:
	if not pickup.has("priceItem") or profile.altar_floor <= 0:
		return true
	return int(LootScorer.best_value(LootScorer.context(run, profile), tags, item)[0]) >= profile.altar_floor


## Who gets `item` (0 = nobody can hold it): food by the food rule, anything else by LootScorer.
static func holder_for(run: RunController, profile: BotProfile, item: ItemDefinition) -> int:
	if item == null:
		return 0
	if TagMatch.has(item.tags, RunController.DROP_FOOD_POOL):
		return food_holder(run, item)
	return LootScorer.best_holder(LootScorer.context(run, profile), item)


## Spec food-items D4: the living member with the lowest HP share who can hold it, ties to the lowest slot.
static func food_holder(run: RunController, item: ItemDefinition) -> int:
	var holders: Array = run.state.party.filter(func(member) -> bool: return run.can_hold(member["slot"], item) == "")
	if holders.is_empty():
		return 0
	var stats := BotCache.party_stats(run)
	var best := 0
	var best_share := -1
	for member in holders:
		var max_hp := int(stats.get(member["slot"], {}).get(BattleUnit.MAX_HP, 0))
		if max_hp <= 0:
			continue
		var share := int(member["hp"]) * 100 / max_hp
		if best == 0 or share < best_share:
			best = member["slot"]
			best_share = share
	return best if best != 0 else holders[0]["slot"]


## Spec 2.6: buys from the current room's shelf, best value ÷ price first, while affordable. Keys the floor's locked rooms
## still need are bought first (and one when none is held and the next floor locks its item room, keys_wanted). Nothing
## is saved for a key that costs too much: the bot does not come back to a shop. A thing worth less than buy_floor to the
## party is left; a piece counts by what wearing it would add (_piece_gain).
static func shop(run: RunController, profile: BotProfile, stats: Dictionary) -> void:
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	if not data["cleared"] or not _active(run):
		return
	while _active(run):
		var key := _key_on_sale(data)
		if key.is_empty() or keys_wanted(run, profile) <= 0 or int(key["price"]) > run.state.coins \
				or run.state.keys >= RunStructure.MAX_KEYS:
			break
		var spent := int(key["price"])
		if not _act(run, stats, "buy", run.take(key["placement"], run.state.party[0]["slot"])):
			break
		_spent(run, stats, spent, ["keys"])
	# One purchase at a time: the offers are valued again after each, since what the party holds changes the values.
	while _active(run):
		var offer := _best_offer(run, profile, data)
		if offer.is_empty():
			break
		var slot: int = run.state.party[0]["slot"]
		if not offer["equipment"]:
			slot = holder_for(run, profile, offer["thing"])
		if slot == 0 or not _act(run, stats, "buy", run.take(offer["placement"], slot)):
			break
		var fits: Array = LootScorer.fits_of(offer["tags"])
		_spent(run, stats, offer["price"], fits if not fits.is_empty() else ["untagged"])


## The shelf's best affordable offer (value ÷ price, ties to the lowest placement) worth at least buy_floor, or {}.
static func _best_offer(run: RunController, profile: BotProfile, data: Dictionary) -> Dictionary:
	var ctx := LootScorer.context(run, profile)
	var offers: Array = []
	for pickup in data["pickups"]:
		if pickup["taken"] or int(pickup["price"]) <= 0 or str(pickup.get("kind", "")) == FloorGenerator.KEYS_KIND 				or int(pickup["price"]) > run.state.coins:
			continue
		var equipment: bool = str(pickup.get("kind", "")) == FloorGenerator.EQUIPMENT_KIND
		var thing: Resource = run.content.equipment[pickup["item"]] if equipment else run.content.items[pickup["item"]]
		var tags: Array = thing.tags
		if LootScorer.is_bad(tags):
			continue
		var best: Array = [_piece_gain(run, ctx, profile, thing), 0] if equipment else LootScorer.best_value(ctx, tags, thing)
		if int(best[0]) < profile.buy_floor or not equipment and int(best[1]) == 0:
			continue
		offers.append({"placement": int(pickup["placement"]), "price": int(pickup["price"]), "value": int(best[0]),
			"ratio": int(best[0]) * 100 / int(pickup["price"]), "equipment": equipment, "thing": thing, "tags": tags})
	offers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["ratio"] > b["ratio"] or a["ratio"] == b["ratio"] and a["placement"] < b["placement"])
	return offers[0] if not offers.is_empty() else {}


## What a piece on the shelf is worth to the party: its value on a living member whose slot is empty (unless pieces in the
## bag fill those slots already), or what it adds over a worn piece it beats by the margin. 0: nobody would wear it.
static func _piece_gain(run: RunController, ctx: Dictionary, profile: BotProfile, piece: EquipmentDefinition) -> int:
	var empty := _open_slots(run, piece.slot) > 0
	var best := 0
	for member in run.state.party:
		if not member["alive"]:
			continue
		var worn: EquipmentDefinition = run.content.equipment.get(member["equipment"].get(piece.slot, &""))
		if worn == null:
			if empty:
				best = maxi(best, LootScorer.value(ctx, piece.tags, member["slot"]))
			continue
		var now := LootScorer.value(ctx, worn.tags, member["slot"], worn.id)
		var then := LootScorer.value(ctx, piece.tags, member["slot"], worn.id)
		if better(now, then, profile):
			best = maxi(best, then - now)
	return best


## Living members with nothing in `slot_tag`, less the pieces in the bag that fit it (curses aside).
static func _open_slots(run: RunController, slot_tag: StringName) -> int:
	var open := 0
	for member in run.state.party:
		if member["alive"] and not member["equipment"].has(slot_tag):
			open += 1
	for piece_id in run.state.armor:
		var piece: EquipmentDefinition = run.content.equipment.get(piece_id)
		if piece != null and piece.slot == slot_tag and not LootScorer.is_bad(piece.tags):
			open -= 1
	return open


## How many more keys the floor's locked rooms need (locked rooms the map shows, next to a visited room or revealed,
## minus keys held; 0 with a golden key).
static func keys_needed(run: RunController) -> int:
	if run.state.golden_key:
		return 0
	var locked := 0
	for index in run.state.map.sorted_indices():
		if run.room_locked(index) and shown(run, index):
			locked += 1
	return maxi(0, locked - run.state.keys)


## Spec 2.5: the bounded improvement pass after a pickup, a battle, or a death or revive: wear what fits an empty slot
## (never leave a piece in the bag while a living member has its slot empty, Item.Curse excepted), upgrade a worn piece by
## the margin, swap pieces between wearers, move use items; a dead member's pieces come off first. Each move strictly
## raises the party's score by the margin, and at most max_moves are made. Returns the moves made.
static func improve(run: RunController, profile: BotProfile, stats: Dictionary) -> int:
	var moves := 0
	for member in run.state.party:
		if member["alive"] or not _active(run):
			continue
		for slot_tag in LootScorer._sorted_names(member["equipment"].keys()):
			if moves >= profile.max_moves:
				return moves
			if _open_slots(run, slot_tag) <= 0:
				continue  # step 5 "where the rules allow": nobody living could wear it; it stays for a revive
			if _act(run, stats, "unequip", run.unequip(member["slot"], slot_tag)):
				moves += 1
				_count(stats, "unequips")
	while moves < profile.max_moves and _active(run):
		var ctx := LootScorer.context(run, profile)
		var move := _wear_move(run, ctx)
		# Moving what is already placed ignores max HP: a worn +HP piece makes its wearer sturdy and the others frail, so
		# the same trade would look good again in reverse.
		ctx["max_hp"] = LootScorer.NO_MAX_HP
		if move.is_empty():
			move = _upgrade_move(run, ctx, profile)
		if move.is_empty():
			move = _swap_move(run, ctx, profile)
		if move.is_empty():
			move = _use_item_move(run, ctx, profile)
		if move.is_empty():
			break
		var result: String = move["call"].call()
		if not _act(run, stats, move["action"], result):
			break
		moves += 1
		_count(stats, move["count"])
	return moves


## Step 1: a piece in the bag for the living member with that slot empty who values it most (ties to the lowest slot).
static func _wear_move(run: RunController, ctx: Dictionary) -> Dictionary:
	for piece_id in run.state.armor:
		var piece: EquipmentDefinition = run.content.equipment.get(piece_id)
		if piece == null or LootScorer.is_bad(piece.tags):
			continue
		var best := 0
		var best_value := -1
		for member in run.state.party:
			if not member["alive"] or member["equipment"].has(piece.slot):
				continue
			var score := LootScorer.value(ctx, piece.tags, member["slot"])
			if score > best_value:
				best = member["slot"]
				best_value = score
		if best != 0:
			return {"action": "equip", "count": "equips", "call": run.equip.bind(best, piece_id)}
	return {}


## Step 2: a piece in the bag that beats a living wearer's piece in its slot by the margin (the biggest gain first); the
## old piece goes back to the bag (equip swaps them in one logged action).
static func _upgrade_move(run: RunController, ctx: Dictionary, profile: BotProfile) -> Dictionary:
	var best := {}
	var best_gain := 0
	for piece_id in _sorted_ids(run.state.armor):
		var piece: EquipmentDefinition = run.content.equipment.get(piece_id)
		if piece == null or LootScorer.is_bad(piece.tags):
			continue
		for member in run.state.party:
			var worn_id: Variant = member["equipment"].get(piece.slot)
			if not member["alive"] or worn_id == null or worn_id == piece_id:
				continue
			var worn: EquipmentDefinition = run.content.equipment.get(worn_id)
			if worn == null:
				continue
			var now := LootScorer.value(ctx, worn.tags, member["slot"], worn_id)
			var then := LootScorer.value(ctx, piece.tags, member["slot"], worn_id)
			if better(now, then, profile) and then - now > best_gain:
				best_gain = then - now
				best = {"action": "equip", "count": "upgrades", "call": run.equip.bind(member["slot"], piece_id)}
	return best


## Step 3: two living wearers of the same slot trade pieces when the pair's score rises by the margin.
static func _swap_move(run: RunController, ctx: Dictionary, profile: BotProfile) -> Dictionary:
	var best := {}
	var best_gain := 0
	var party: Array = run.state.party
	for i in party.size():
		for j in range(i + 1, party.size()):
			var a: Dictionary = party[i]
			var b: Dictionary = party[j]
			if not a["alive"] or not b["alive"]:
				continue
			for slot_tag in LootScorer._sorted_names(a["equipment"].keys()):
				if not b["equipment"].has(slot_tag):
					continue
				var piece_a: StringName = a["equipment"][slot_tag]
				var piece_b: StringName = b["equipment"][slot_tag]
				if piece_a == piece_b or _first_wearer(run, piece_b, a["slot"]) != b["slot"]:
					continue  # swap_gear takes the piece from its first other wearer: only score the trade it makes
				var tags_a: Array = run.content.equipment[piece_a].tags
				var tags_b: Array = run.content.equipment[piece_b].tags
				var now := LootScorer.value(ctx, tags_a, a["slot"], piece_a) + LootScorer.value(ctx, tags_b, b["slot"], piece_b)
				var then := LootScorer.value(ctx, tags_b, a["slot"], piece_a) + LootScorer.value(ctx, tags_a, b["slot"], piece_b)
				if better(now, then, profile) and then - now > best_gain:
					best_gain = then - now
					best = {"action": "swap_gear", "count": "swaps", "call": run.swap_gear.bind(a["slot"], piece_b)}
	return best


## The first member other than `slot` wearing `piece_id` (swap_gear's `from`), or 0.
static func _first_wearer(run: RunController, piece_id: StringName, slot: int) -> int:
	var piece: EquipmentDefinition = run.content.equipment.get(piece_id)
	if piece == null:
		return 0
	for wearer in run.state.party:
		if wearer["slot"] != slot and wearer["equipment"].get(piece.slot, &"") == piece_id:
			return wearer["slot"]
	return 0


## Step 4: a use item moves to a living member with a free use slot, or trades places with one of theirs, when the
## score rises by the margin. Items that add use slots never move (they change the capacities).
static func _use_item_move(run: RunController, ctx: Dictionary, profile: BotProfile) -> Dictionary:
	var best := {}
	var best_gain := 0
	for giver in run.state.party:
		for use_slot in giver["use_slots"]:
			var item_id: StringName = use_slot["item"]
			var item: ItemDefinition = run.content.items.get(item_id)
			if item == null or item.extra_use_slots > 0:
				continue
			var spare: int = run.use_capacity(giver["slot"]) - giver["use_slots"].size()
			var here := LootScorer.value(ctx, item.tags, giver["slot"], item_id)
			for receiver in run.state.party:
				if receiver["slot"] == giver["slot"] or not receiver["alive"]:
					continue
				if receiver["use_slots"].size() < run.use_capacity(receiver["slot"]):
					var there := LootScorer.value(ctx, item.tags, receiver["slot"])
					if spare >= -1 and better(here, there, profile) and there - here > best_gain:
						best_gain = there - here
						best = {"action": "move_item", "count": "useMoves",
							"call": run.move_item.bind(giver["slot"], item_id, receiver["slot"])}
					continue
				if spare < 0 or receiver["use_slots"].size() > run.use_capacity(receiver["slot"]):
					continue  # move_item refuses a trade that leaves either over its capacity (a lost Satchel)
				for theirs in receiver["use_slots"]:
					var other: ItemDefinition = run.content.items.get(theirs["item"])
					if other == null or other.extra_use_slots > 0 or theirs["item"] == item_id:
						continue
					var now := here + LootScorer.value(ctx, other.tags, receiver["slot"], other.id)
					var then := LootScorer.value(ctx, item.tags, receiver["slot"], other.id) \
						+ LootScorer.value(ctx, other.tags, giver["slot"], item_id)
					if better(now, then, profile) and then - now > best_gain:
						best_gain = then - now
						best = {"action": "move_item", "count": "useMoves",
							"call": run.move_item.bind(giver["slot"], item_id, receiver["slot"], other.id)}
	return best


## Whether `then` beats `now` by the profile's margin (strictly, so equal values never move).
static func better(now: int, then: int, profile: BotProfile) -> bool:
	return then > now and then * 100 > now * (100 + profile.swap_margin)


## Spec 2.6: field actions before entering `next_cell` (-1: none planned): revive a dead member; heal a member under
## field_heal_below before a room that may hold a battle, anyone hurt before the boss room; restore SP under
## field_sp_below before the boss. At most field_max_uses actions. Returns how many were used.
static func field_before(run: RunController, profile: BotProfile, next_cell: int, stats: Dictionary) -> int:
	var uses := 0
	while uses < profile.field_max_uses and _active(run):
		var pick := field_pick(run, profile, next_cell)
		if pick.is_empty():
			break
		var problem: Array = await run.use_field(pick["slot"], pick["ability"], pick["target"])
		if not problem.is_empty():
			_act(run, stats, "use_field", "%s" % problem[0] if problem.size() < 2 else "%s: %s" % [problem[0], problem[1]])
			break
		uses += 1
		_count(stats, "fieldUses")
	return uses


## The field action to take now, {"slot", "ability", "target"}, or {} (spec 2.6). Read only.
static func field_pick(run: RunController, profile: BotProfile, next_cell: int) -> Dictionary:
	var options := BotCache.field_options(run)
	if options.is_empty():
		return {}
	return choose_field(run, profile, next_cell, options, BotCache.party_stats(run))


## field_pick's decision over given `options` (field_options' shape) and `stats` (party_stats' shape). Read only.
static func choose_field(run: RunController, profile: BotProfile, next_cell: int, options: Array[Dictionary],
		stats: Dictionary) -> Dictionary:
	var dead: Array[int] = []
	for member in run.state.party:
		if not member["alive"]:
			dead.append(member["slot"])
	if not dead.is_empty():
		var revive := _option(run, options, ROLE_REVIVE, dead)
		if not revive.is_empty():
			return revive
	if next_cell < 0 or not run.state.map.cells.has(next_cell):
		return {}
	var boss: bool = run.state.map.cells[next_cell]["role"] == FloorMap.ROLE_BOSS
	if boss or may_fight(run, next_cell):
		var hurt := _below(run, stats, BattleUnit.HP, BattleUnit.MAX_HP, profile.field_heal_below)
		if not hurt.is_empty():
			var heal := _option(run, options, ROLE_HEAL, hurt)
			if not heal.is_empty():
				return heal
		if boss:
			# SP first: the small top-ups below cost SP and share the same few uses.
			var drained := _below(run, stats, BattleUnit.MP, BattleUnit.MAX_MP, profile.field_sp_below)
			if not drained.is_empty():
				var rest := _option(run, options, ROLE_RESTORE_MP, drained)
				if not rest.is_empty():
					return rest
			# Before the boss, anyone hurt is topped up, but only by spells and cooldown items: a consumable is kept.
			var topped := _below(run, stats, BattleUnit.HP, BattleUnit.MAX_HP, 100)
			if not topped.is_empty():
				var top := _option(run, options, ROLE_HEAL, topped, 1)
				if not top.is_empty():
					return top
	return {}


## Whether a player would expect a battle in `cell`: an unvisited room that is not a known special room (or a challenge
## room not cleared), or the boss room.
static func may_fight(run: RunController, cell: int) -> bool:
	var data: Dictionary = run.state.map.cells[cell]
	if data["role"] == FloorMap.ROLE_BOSS:
		return not data["cleared"]
	if data["cleared"] or data["visited"]:
		return false
	if data["role"] == FloorMap.ROLE_SPECIAL:
		return str(data["content"].get("kind", "")) == "waves"
	return data["role"] == FloorMap.ROLE_NORMAL


## The living (or, for HP, any listed) members under `limit` percent of `attribute`, lowest share first, ties to the
## lowest slot.
static func _below(run: RunController, stats: Dictionary, attribute: String, maximum: String, limit: int) -> Array[int]:
	var found: Array = []
	for member in run.state.party:
		if not member["alive"]:
			continue
		var top := int(stats.get(member["slot"], {}).get(maximum, 0))
		if top <= 0:
			continue
		var current := int(stats[member["slot"]].get(attribute, 0))
		var share := current * 100 / top
		if share < limit:
			found.append([share, member["slot"]])
	found.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or a[0] == b[0] and a[1] < b[1])  # sort-ok: [share, slot] ints
	var slots: Array[int] = []
	for entry in found:
		slots.append(entry[1])
	return slots


## The first option with `role` that reaches the neediest of `needy` (a targeted one aimed at the first listed slot it can
## reach; an untargeted one only when it covers them: ALL_* always, SELF when the caster is the first needy). Cooldown
## items first, then spells, then consumable items (up to `max_rank`), each in field_options order.
static func _option(run: RunController, options: Array[Dictionary], role: StringName, needy: Array[int],
		max_rank: int = 2) -> Dictionary:
	for rank in max_rank + 1:
		for option in options:
			if not option.get("roles", []).has(role) or _option_rank(run, option) != rank:
				continue
			var targets: Array = option["targets"]
			if targets.is_empty():
				var ability := int(option["targeting"]) if option.has("targeting") else _ability_of(run, option)
				if ability == BattleAbility.Targeting.SELF and option["slot"] != needy[0]:
					continue
				return {"slot": option["slot"], "ability": option["ability"], "target": 0}
			for slot in needy:
				if targets.has(slot):
					return {"slot": option["slot"], "ability": option["ability"], "target": slot}
	return {}


## 0 a cooldown item, 1 a spell, 2 a consumable item.
static func _option_rank(run: RunController, option: Dictionary) -> int:
	if option["item"] == &"":
		return 1
	var item: ItemDefinition = run.content.items.get(option["item"])
	if item != null and item.use_mode == ItemDefinition.UseMode.COOLDOWN:
		return 0
	return 2


## The targeting of an option's ability (SELF or ALL_*: what an untargeted option reaches).
static func _ability_of(run: RunController, option: Dictionary) -> int:
	var member := run.state.member(option["slot"])
	var scene: PackedScene = null
	if option["item"] != &"":
		var item: ItemDefinition = run.content.items.get(option["item"])
		scene = item.use_ability if item != null else null
	else:
		var character: CharacterDefinition = run.content.units.get(member["character"])
		scene = character.skill_scene(option["ability"]) if character != null else null
	if scene == null:
		return BattleAbility.Targeting.ALL_ALLIES
	var node := scene.instantiate()
	var ability := node as BattleAbility
	if ability == null:
		node.free()
		return BattleAbility.Targeting.ALL_ALLIES
	var targeting := int(ability.targeting)
	ability.free()
	return targeting


## The keys to buy now: what this floor's shown locked rooms need, and at least one when none is held and the next floor
## locks a room the profile names (next_floor_key_rooms: its item room; user, 2026-11-22).
static func keys_wanted(run: RunController, profile: BotProfile) -> int:
	var needed := keys_needed(run)
	if needed == 0 and run.state.keys == 0 and not run.state.golden_key \
			and next_floor_locks(run, profile.next_floor_key_rooms):
		needed = 1
	return needed


## Whether the next floor locks a room with one of `tags`: a chapter its floor slot can pick places one, its rules lock
## it, and the run's locks are on by then (RunStructure.unlocked_floors). What a player can know from the run's layout.
static func next_floor_locks(run: RunController, tags: Array[StringName]) -> bool:
	var structure := run.structure
	var next := run.state.floor_index + 1
	if structure == null or not structure.uses_keys() or next >= structure.floors.size() or next < structure.unlocked_floors:
		return false
	var slot: FloorSlot = structure.floors[next]
	for chapter in slot.chapters:
		var rules: FloorGenRules = chapter.floor_gen_rules if chapter != null else null
		if rules == null:
			continue
		for tag in tags:
			if rules.special_room_tags.has(tag) and rules.locked_room_tags.has(tag):
				return true
	return false


## Whether the map shows `index` to a player: visited, next to a visited room, or the map is revealed.
static func shown(run: RunController, index: int) -> bool:
	if run.state.revealed or run.state.map.cells[index]["visited"]:
		return true
	for neighbour in run.state.map.neighbours(index):
		if run.state.map.cells[neighbour]["visited"]:
			return true
	return false


static func _key_on_sale(data: Dictionary) -> Dictionary:
	for pickup in data["pickups"]:
		if not pickup["taken"] and str(pickup.get("kind", "")) == FloorGenerator.KEYS_KIND and int(pickup["price"]) > 0:
			return pickup
	return {}


## Records a bot action's refusal (a bot bug, spec 4): stats["refused"]["<action>: <reason>"]. True when it was done.
static func _act(_run: RunController, stats: Dictionary, action: String, result: String) -> bool:
	if result == "":
		return true
	if stats.has("refused"):
		var key := "%s: %s" % [action, result]
		stats["refused"][key] = int(stats["refused"].get(key, 0)) + 1
	return false


static func _spent(run: RunController, stats: Dictionary, coins: int, kinds: Array) -> void:
	if not stats.has("shop"):
		return
	var by_floor: Dictionary = stats["shop"].get_or_add("coinsByFloor", {})
	var key := str(run.state.floor_index + 1)
	by_floor[key] = int(by_floor.get(key, 0)) + coins
	var bought: Dictionary = stats["shop"].get_or_add("bought", {})
	for kind in kinds:
		bought[String(kind)] = int(bought.get(String(kind), 0)) + 1


static func _count(stats: Dictionary, key: String) -> void:
	if stats.has("moves"):
		stats["moves"][key] = int(stats["moves"].get(key, 0)) + 1


static func _sorted_ids(ids: Array) -> Array:
	var names := ids.duplicate()
	names.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	return names


static func _active(run: RunController) -> bool:
	return run.state.status == RunState.ACTIVE and run.runner_error == "" and run.pending_battle.is_empty() \
		and run.state.event.is_empty() and run.state.pending_gifts.is_empty()
