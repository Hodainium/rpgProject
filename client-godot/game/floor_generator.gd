## Isaac-style seeded floor generator (spec game-skeleton 3.2). Integers and the run's seeded streams only.
##
## generate() and from_layout() return {"map": FloorMap, "error": String}. The "pools" argument carries what the
## item pools must know: {"party": Array[StringName] character ids, "held": Array[StringName], "seen": Array[StringName]}
## ("seen" is extended with every item placed, so no item appears twice in a run).
## Spec unique-events: "seen_events" (event ids placed from a query so far; extended with every one placed here, so a query
## event appears once per run) and the optional "unholdable" (food ids no living member can hold; absent = any food can be
## held).
class_name FloorGenerator
extends RefCounted

## Items tagged Dev (the dev stat items, spec dev-tools 3.3) are never in a pool.
const DEV_TAG: StringName = &"Dev"
## Spec unique-events 2.4: a drained pool gives one of these (spec food-items).
const FOOD_POOL: StringName = &"Pool.Food"
## A pickup's "kind" when it is a piece of equipment (spec item-pass 3.5).
const EQUIPMENT_KIND: String = "equipment"
## A pickup's "kind" (and "item") when it sells keys (spec keys-and-gear D12); "keys" holds how many.
const KEYS_KIND: String = "keys"

var content: ContentIndex
var run_structure: RunStructure
var run_seed: int
var depth: int
## Spec server-authority 3.5: where the streams come from; local(run_seed) unless a seed source is given.
var seeds: SeedSource
## Spec unique-events 2.4: pool picks that found nothing left (each one gave food, the fallback item or nothing).
var pools_drained: int = 0
## Problems the caller should warn about (a drained pick with no food and no fallback item).
var warnings: PackedStringArray = []


func _init(content_index: ContentIndex, structure: RunStructure, seed_value: int, floor_depth: int,
		seed_source: SeedSource = null) -> void:
	content = content_index
	run_structure = structure
	run_seed = seed_value
	depth = floor_depth
	seeds = seed_source if seed_source != null else SeedSource.local(seed_value)


## Steps 1-7 for a chapter.
@warning_ignore("integer_division")
func generate(chapter: ChapterDefinition, any_chapter: bool, pools: Dictionary) -> Dictionary:
	var rules := chapter.floor_gen_rules
	if rules == null:
		return _error("chapter %s has no floor_gen_rules" % chapter.id)
	var layout_rng := seeds.floor_rng(depth, "layout")
	var map := FloorMap.new(rules.grid_size)
	var target := mini(rules.max_rooms, rules.base_rooms + rules.rooms_per_depth * depth
		+ layout_rng.randi_range(0, maxi(rules.random_extra_rooms, 0)))
	var needed_dead_ends := 1 + rules.special_room_tags.size()
	var dead_ends: Array[int] = []
	var built := false
	for attempt in rules.max_attempts:
		map.attempts = attempt + 1
		map.cells.clear()
		map.start = map.index_of(Vector2i(rules.grid_size.x / 2, rules.grid_size.y / 2))
		_fill(map, map.start)
		var queue: Array[int] = [map.start]
		var count := 1
		while not queue.is_empty() and count < target:
			var current: int = queue.pop_front()
			for direction in FloorMap.DIRECTIONS:
				var next := map.cell_of(current) + direction
				if count >= target or not map.inside(next):
					continue
				var next_index := map.index_of(next)
				if map.cells.has(next_index) or map.neighbours(next_index).size() > 1:
					continue
				if layout_rng.randi_range(0, 9999) >= rules.branch_chance_x100:
					continue
				_fill(map, next_index)
				queue.append(next_index)
				count += 1
		if count < target:
			continue
		dead_ends = _dead_ends(map)
		if dead_ends.size() >= needed_dead_ends:
			built = true
			break
	if not built:
		return _error("floor rules %s: no layout with %d rooms and %d dead ends after %d attempts"
			% [rules.id, target, needed_dead_ends, rules.max_attempts])

	# Step 4: boss in the farthest dead end, special rooms in the others.
	var distances := map.distances()
	var boss := -1
	for index in dead_ends:
		if boss == -1 or distances[index] > distances[boss]:
			boss = index
	map.boss = boss
	map.cells[boss]["role"] = FloorMap.ROLE_BOSS
	dead_ends.erase(boss)
	for tag in rules.special_room_tags:
		var picked: int = dead_ends.pop_at(layout_rng.randi_range(0, dead_ends.size() - 1))
		map.cells[picked]["role"] = FloorMap.ROLE_SPECIAL
		map.cells[picked]["special_tag"] = tag
	map.cells[map.start]["role"] = FloorMap.ROLE_START

	# Step 5: rooms that fit each cell's doors.
	var rooms_rng := seeds.floor_rng(depth, "rooms")
	for index in map.sorted_indices():
		var data: Dictionary = map.cells[index]
		data["doors"] = map.door_mask(index)
		var type_tag := _type_tag(rules, data)
		var candidates: Array = []
		for room_id in _sorted_ids(content.rooms):
			var room: RoomDefinition = content.rooms[room_id]
			if TagMatch.has(room.tags, type_tag) and _in_chapter(room, chapter, any_chapter) and room.fits(data["doors"]):
				candidates.append(room)
		var room: RoomDefinition = RunSeeds.pick_weighted(rooms_rng, candidates)
		if room == null:
			return _error("no room for cell %s (role %s, tag %s, doors %d) in chapter %s"
				% [map.cell_of(index), data["role"], type_tag, data["doors"], chapter.id])
		data["room"] = room.id
	return _resolve(map, chapter, pools, {}, any_chapter, true)


## A hand-made floor (steps 6-7 only). Checked: cells inside the grid, connected, one start and one boss.
func from_layout(layout: FloorLayout, chapter: ChapterDefinition, pools: Dictionary) -> Dictionary:
	var built := layout_map(layout)
	if built["error"] != "":
		return _error(built["error"])
	return _resolve(built["map"], chapter, pools, built["overrides"])


## A one-room floor for the sandbox (spec dev-tools 2.2): the room is the start cell; its role comes from its tags
## against the chapter's rules (boss tag → boss, a special tag → special). Content resolves as on a real floor (steps
## 6-7), with an optional encounter or event override.
func single_room(room: RoomDefinition, chapter: ChapterDefinition, pools: Dictionary,
		encounter: EncounterDefinition = null, event: EventDefinition = null) -> Dictionary:
	var map := FloorMap.new(Vector2i(1, 1))
	_fill(map, 0)
	map.start = 0
	map.cells[0]["room"] = room.id
	var rules := chapter.floor_gen_rules
	if rules != null and TagMatch.has(room.tags, rules.boss_room_tag):
		map.boss = 0
		map.cells[0]["role"] = FloorMap.ROLE_BOSS
	elif rules != null and rules.special_room_tags.any(func(tag: StringName) -> bool: return TagMatch.has(room.tags, tag)):
		map.cells[0]["role"] = FloorMap.ROLE_SPECIAL
	var overrides := {}
	if encounter != null or event != null:
		var override := FloorLayoutCell.new()
		override.room = room
		override.encounter = encounter
		override.event = event
		overrides[0] = override
	# Spec unique-events (review): the sandbox plays the room it was asked for, so its event query ignores what the run has seen
	# (the floor it replaces placed its own events on a map nobody plays); an event it places is still recorded once.
	var sandbox_pools := pools.duplicate()
	sandbox_pools["seen_events"] = []
	var result := _resolve(map, chapter, sandbox_pools, overrides)
	if not pools.has("seen_events"):
		pools["seen_events"] = []
	for id in sandbox_pools["seen_events"]:
		if not pools["seen_events"].has(id):
			pools["seen_events"].append(id)
	return result


## Everything from_layout checks, plus that every room's doors cover its neighbours (spec dev-tools 3.7, bad_layout).
## "" when the layout is valid, else the problem.
static func check_layout(layout: FloorLayout) -> String:
	var built := layout_map(layout)
	if built["error"] != "":
		return built["error"]
	var map: FloorMap = built["map"]
	for index in map.sorted_indices():
		var room: RoomDefinition = built["overrides"][index].room
		if not room.fits(map.cells[index]["doors"]):
			return "layout %s: room %s at %s has no door for a neighbour (needs %d, has %d)" \
				% [layout.id, room.id, map.cell_of(index), map.cells[index]["doors"], room.doors]
	return ""


## The layout's cells as a FloorMap: {"map", "overrides": index -> FloorLayoutCell, "error"}.
static func layout_map(layout: FloorLayout) -> Dictionary:
	var map := FloorMap.new(layout.grid_size)
	var overrides := {}
	var failed := func(message: String) -> Dictionary: return {"map": null, "overrides": {}, "error": message}
	for entry in layout.cells:
		if entry == null or entry.room == null:
			return failed.call("layout %s: a cell has no room" % layout.id)
		if not map.inside(entry.cell):
			return failed.call("layout %s: cell %s is outside the %s grid" % [layout.id, entry.cell, layout.grid_size])
		var index := map.index_of(entry.cell)
		if map.cells.has(index):
			return failed.call("layout %s: cell %s is used twice" % [layout.id, entry.cell])
		_fill(map, index)
		map.cells[index]["room"] = entry.room.id
		overrides[index] = entry
		match entry.role:
			FloorLayoutCell.Role.START:
				if map.start != -1:
					return failed.call("layout %s: more than one start" % layout.id)
				map.start = index
				map.cells[index]["role"] = FloorMap.ROLE_START
			FloorLayoutCell.Role.BOSS:
				if map.boss != -1:
					return failed.call("layout %s: more than one boss" % layout.id)
				map.boss = index
				map.cells[index]["role"] = FloorMap.ROLE_BOSS
			FloorLayoutCell.Role.SPECIAL:
				map.cells[index]["role"] = FloorMap.ROLE_SPECIAL
	if map.start == -1 or map.boss == -1:
		return failed.call("layout %s needs exactly one start and one boss" % layout.id)
	if map.distances().size() != map.cells.size():
		return failed.call("layout %s: not every cell is connected to the start" % layout.id)
	for index in map.sorted_indices():
		map.cells[index]["doors"] = map.door_mask(index)
	return {"map": map, "overrides": overrides, "error": ""}


## Steps 6 (content) and 7 (pickups).
func _resolve(map: FloorMap, chapter: ChapterDefinition, pools: Dictionary, overrides: Dictionary = {},
		any_chapter: bool = false, generated: bool = false) -> Dictionary:
	var content_rng := seeds.floor_rng(depth, "content")
	if not pools.has("seen_events"):
		pools["seen_events"] = []
	for index in map.sorted_indices():
		var data: Dictionary = map.cells[index]
		var room: RoomDefinition = content.rooms[data["room"]]
		var override: FloorLayoutCell = overrides.get(index)
		if (override == null or (override.encounter == null and override.event == null)) \
				and room.content_mode == RoomDefinition.ContentMode.EVENT_QUERY and _events_ran_out(room, chapter, pools):
			# Spec unique-events 2.2: every matching event is seen; on a generated floor an ordinary room of the cell's type takes its
			# place, picked on its own stream (so the content stream draws as before until this happens). No room fits, or an
			# authored room (a layout cell, the sandbox's room) that is never swapped: the room stays and its content is none.
			var replacement := _swap_room(map, index, chapter, any_chapter) if generated else null
			data["fallback"] = true
			if replacement == null:
				data["content"] = {"kind": "none", "encounter": &"", "event": &"", "enemies": []}
				continue
			data["room"] = replacement.id
			room = replacement
		var resolved := _resolve_content(room, chapter, data["role"] == FloorMap.ROLE_BOSS, content_rng, override, pools)
		if resolved.has("error"):
			return _error("cell %s (%s): %s" % [map.cell_of(index), room.id, resolved["error"]])
		data["content"] = resolved
	for index in map.sorted_indices():
		var data: Dictionary = map.cells[index]
		var loot_rng := seeds.floor_rng(depth, "loot/%d" % index)
		var room: RoomDefinition = content.rooms[data["room"]]
		for number in room.placements.size():
			var placement: RoomPlacement = room.placements[number]
			if placement == null or not placement.kind in [RoomPlacement.Kind.ITEM_PEDESTAL, RoomPlacement.Kind.SHOP_SLOT]:
				continue
			if placement.keys > 0:
				# Spec keys-and-gear D12: a slot that sells keys draws nothing from the loot stream.
				data["pickups"].append({"placement": number + 1, "item": KEYS_KIND, "price": maxi(placement.price, 0),
					"taken": false, "kind": KEYS_KIND, "keys": placement.keys})
				continue
			var picked := pick_pickup(placement.item, placement.equipment, placement.item_query, loot_rng, pools,
				placement.offers)
			if picked == null:
				continue
			pools["seen"].append(picked.id)
			var price := 0
			if placement.kind == RoomPlacement.Kind.SHOP_SLOT:
				price = placement.price if placement.price >= 0 else picked.price
			var entry := pickup_entry(number + 1, picked, price)
			if placement.price_item != null:
				entry["priceItem"] = placement.price_item.id
			data["pickups"].append(entry)
	return {"map": map, "error": ""}


func _resolve_content(room: RoomDefinition, chapter: ChapterDefinition, is_boss: bool, stream: RandomNumberGenerator,
		override: FloorLayoutCell, pools: Dictionary) -> Dictionary:
	var encounter: EncounterDefinition = null
	var event: EventDefinition = null
	if override != null and override.encounter != null:
		encounter = override.encounter
	elif override != null and override.event != null:
		event = override.event
	else:
		match room.content_mode:
			RoomDefinition.ContentMode.ENCOUNTER:
				encounter = room.encounter
			RoomDefinition.ContentMode.ENCOUNTER_QUERY:
				var query := room.content_query
				if query == null:
					query = chapter.boss_encounter_query if is_boss else chapter.encounter_query
				if is_boss and room.content_query == null and chapter.boss_rotation:
					encounter = rotated_boss(chapter)
				else:
					encounter = RunSeeds.pick_weighted(stream, _matching(content.encounters, query))
				if encounter == null:
					return {"error": "no encounter matches the %s query" % ("boss" if is_boss else "encounter")}
			RoomDefinition.ContentMode.EVENT:
				event = room.event
			RoomDefinition.ContentMode.EVENT_QUERY:
				# Spec unique-events 2.1: once per run; placing it marks it seen (so two rooms of one floor differ too). _resolve
				# swapped the room when nothing unseen is left, so this always finds one.
				event = RunSeeds.pick_weighted(stream, _unseen_events(room, chapter, pools))
				if event == null:
					return {"error": "no event matches the event query"}
				pools["seen_events"].append(event.id)
			RoomDefinition.ContentMode.WAVES:
				return resolve_waves(room, chapter, stream)
	if encounter != null:
		return {"kind": "encounter", "encounter": encounter.id, "event": &"",
			"enemies": resolve_enemies(encounter, room, is_boss, chapter.scaling, stream)}
	if event != null:
		return {"kind": "event", "encounter": &"", "event": event.id, "enemies": []}
	return {"kind": "none", "encounter": &"", "event": &"", "enemies": []}


## Spec unique-events 2.1: the events an EVENT_QUERY room may still draw: matching its query (else the chapter's), weight
## above 0, not placed from a query earlier in the run.
func _unseen_events(room: RoomDefinition, chapter: ChapterDefinition, pools: Dictionary) -> Array:
	var query := room.content_query if room.content_query != null else chapter.event_query
	var seen: Array = pools.get("seen_events", [])
	return _matching(content.events, query).filter(func(event: EventDefinition) -> bool:
		return event.weight_x100 > 0 and not seen.has(event.id))


## Spec unique-events 2.2: true when the room's query has no event left to draw: every match is seen, or it matches none (user,
## 2026-11-22: running out is game design, like food for drained items, so an empty query falls back too; the validator warns).
func _events_ran_out(room: RoomDefinition, chapter: ChapterDefinition, pools: Dictionary) -> bool:
	return _unseen_events(room, chapter, pools).is_empty()


## Spec unique-events 2.2: the room replacing an exhausted event room: one with the cell's type tag in the chapter, fitting its
## doors, whose content is no event, picked on floor/<n>/room_swap/<cell>. Null when none fits (or the chapter has no rules).
func _swap_room(map: FloorMap, index: int, chapter: ChapterDefinition, any_chapter: bool) -> RoomDefinition:
	var rules := chapter.floor_gen_rules
	if rules == null:
		return null
	var data: Dictionary = map.cells[index]
	var type_tag := _type_tag(rules, data)
	var candidates: Array = []
	for room_id in _sorted_ids(content.rooms):
		var room: RoomDefinition = content.rooms[room_id]
		if room.content_mode in [RoomDefinition.ContentMode.EVENT, RoomDefinition.ContentMode.EVENT_QUERY]:
			continue
		if TagMatch.has(room.tags, type_tag) and _in_chapter(room, chapter, any_chapter) and room.fits(data["doors"]):
			candidates.append(room)
	return RunSeeds.pick_weighted(seeds.floor_rng(depth, "room_swap/%d" % index), candidates)


## Spec floor-rooms 2.1: a challenge room's waves, in order, on the content stream. A wave without a fixed encounter picks
## from its query (empty: the chapter's encounter query), skipping encounters this room already picked while another one
## is left. The content's encounter and enemies are wave 1's; "waves" holds them all.
func resolve_waves(room: RoomDefinition, chapter: ChapterDefinition, stream: RandomNumberGenerator) -> Dictionary:
	var waves: Array = []
	var picked: Array[String] = []
	for wave in room.waves:  # a fixed wave anywhere in the list counts as picked for the query waves
		if wave != null and wave.encounter != null:
			picked.append(String(wave.encounter.id))
	for number in room.waves.size():
		var wave: RoomWave = room.waves[number]
		if wave == null:
			return {"error": "wave %d is empty" % (number + 1)}
		var encounter := wave.encounter
		if encounter == null:
			var query := wave.content_query if wave.content_query != null else chapter.encounter_query
			var candidates := _matching(content.encounters, query)
			var fresh := candidates.filter(func(entry: EncounterDefinition) -> bool:
				return entry.weight_x100 > 0 and not picked.has(String(entry.id)))
			encounter = RunSeeds.pick_weighted(stream, fresh if not fresh.is_empty() else candidates)
			if encounter == null:
				return {"error": "no encounter matches wave %d's query" % (number + 1)}
		if not picked.has(String(encounter.id)):
			picked.append(String(encounter.id))
		waves.append({"encounter": encounter.id,
			"enemies": resolve_enemies(encounter, room, false, chapter.scaling, stream)})
	if waves.is_empty():
		return {"error": "a WAVES room has no waves"}
	return {"kind": "waves", "encounter": waves[0]["encounter"], "event": &"", "enemies": waves[0]["enemies"],
		"waves": waves}


## Spec playable-demo 3.8 (boss rotation): the chapter's boss candidates (sorted ids, weight above 0), shuffled once per
## run by the stream chapter/<id>/bosses; the chapter's k-th floor in the run takes entry k mod n. Stateless, so the
## run state and hash hold nothing new, and two floors of one chapter never meet the same boss while it has two.
func rotated_boss(chapter: ChapterDefinition) -> EncounterDefinition:
	var candidates: Array = _matching(content.encounters, chapter.boss_encounter_query).filter(
		func(encounter: EncounterDefinition) -> bool: return encounter.weight_x100 > 0)
	if candidates.is_empty():
		return null
	var shuffle := seeds.run_rng("chapter/%s/bosses" % chapter.id)
	for index in range(candidates.size() - 1, 0, -1):
		var other := shuffle.randi_range(0, index)
		var held: Variant = candidates[index]
		candidates[index] = candidates[other]
		candidates[other] = held
	var nth := 0
	if run_structure != null:
		for floor_index in mini(depth, run_structure.floors.size()):
			var slot: FloorSlot = run_structure.floors[floor_index]
			if slot != null and slot.chapters.has(chapter):
				nth += 1
	return candidates[nth % candidates.size()]


## EnemySnapshot dictionaries for an encounter placed in a room: loadout precedence (enemy default → encounter slot →
## room placement) and elite rolls (not in boss rooms).
func resolve_enemies(encounter: EncounterDefinition, room: RoomDefinition, is_boss: bool, scaling: ScalingRules,
		stream: RandomNumberGenerator) -> Array:
	var placement_loadouts := {}
	if room != null:
		for number in room.placements.size():
			var placement: RoomPlacement = room.placements[number]
			if placement != null and placement.kind == RoomPlacement.Kind.ENEMY_SPAWN and placement.loadout != null:
				placement_loadouts[placement.slot] = ContentIndex.loadout_ref(placement.loadout, room.id, str(number + 1))
	var enemies: Array = []
	for index in encounter.slots.size():
		var slot: EncounterSlot = encounter.slots[index]
		var number := index + 1
		var ref := ""
		if placement_loadouts.has(number):
			ref = placement_loadouts[number]
		elif slot.loadout != null:
			ref = ContentIndex.loadout_ref(slot.loadout, encounter.id, str(number))
		elif slot.enemy.default_loadout != null:
			ref = ContentIndex.loadout_ref(slot.enemy.default_loadout, slot.enemy.id, "default")
		var variant: EnemyVariant = slot.variant
		var enemy := slot.enemy as EnemyDefinition
		if variant == null and not is_boss and enemy != null and not enemy.variants.is_empty():
			var chance := scaling.elite_chance_x100 if scaling != null else 0
			if RunSeeds.roll(stream, chance):
				variant = enemy.variants[stream.randi_range(0, enemy.variants.size() - 1)]
		enemies.append({
			"slot": number,
			"unitDefId": String(slot.enemy.id),
			"loadoutRef": ref if ref != "" else null,
			"variantId": String(variant.id) if variant != null else null,
		})
	return enemies


## Spec playable-demo 3.7: a weighted pick of items or pieces with the run's rarity weights; without weights exactly
## RunSeeds.pick_weighted (so content without them draws as before).
func _pick_pooled(stream: RandomNumberGenerator, candidates: Array) -> Variant:
	if run_structure == null or run_structure.rarity_weights_x100.is_empty():
		return RunSeeds.pick_weighted(stream, candidates)
	var weights: Array[int] = []
	for entry in candidates:
		weights.append(run_structure.weighted(entry))
	return RunSeeds.pick_weighted_by(stream, candidates, weights)


## Spec card-collection 2.5: a pick is allowed when the run has no card pool, or the pool holds the id. Only the three pick
## functions below ask; fixed items, loadouts and mirrors never do (drops ask through RunController._pooled_drop).
static func _in_card_pool(pools: Dictionary, id: StringName) -> bool:
	var pool: Variant = pools.get("card_pool")
	return pool == null or pool.has(id)


## A fixed item, or one picked from the pool (unlocked, not held, not seen this run).
## Nothing left: food, else the run structure's fallback_item (spec unique-events 2.4), unless `use_fallback` is false (then
## null).
func pick_item(fixed: ItemDefinition, query: GameplayTagQuery, stream: RandomNumberGenerator, pools: Dictionary,
		use_fallback: bool = true) -> ItemDefinition:
	if fixed != null:
		return fixed
	var candidates: Array = []
	for item_id in _sorted_ids(content.items):
		var item: ItemDefinition = content.items[item_id]
		if not Unlocks.is_unlocked(item) or not TagMatch.matches(query, item.tags) or TagMatch.has(item.tags, DEV_TAG):
			continue
		if pools.get("held", []).has(item_id) or pools.get("seen", []).has(item_id) or not _in_card_pool(pools, item_id):
			continue
		candidates.append(item)
	var picked: ItemDefinition = _pick_pooled(stream, candidates)
	if picked == null and use_fallback:
		picked = _drained(stream, pools, true)  # spec unique-events 2.4
	return picked


## Spec item-pass 3.5: what a pedestal or shop slot offers. A fixed item or piece, else one pick from the items and
## the equipment matching the query together (items first, then equipment, each by id, so content without pooled
## equipment picks exactly as before). Spec unique-events 2.4: nothing left gives a food item, else the run structure's
## fallback_item. Spec floor-rooms 3.1: `offers` keeps only items (ITEMS) or only equipment (EQUIPMENT: nothing left gives a
## food item too, but never the fallback item; null without food).
func pick_pickup(fixed_item: ItemDefinition, fixed_equipment: EquipmentDefinition, query: GameplayTagQuery,
		stream: RandomNumberGenerator, pools: Dictionary, offers: int = RoomPlacement.Offers.ANY) -> Resource:
	if fixed_item != null:
		return fixed_item
	if fixed_equipment != null:
		return fixed_equipment
	var tables: Array = [content.items, content.equipment]
	if offers == RoomPlacement.Offers.ITEMS:
		tables = [content.items]
	elif offers == RoomPlacement.Offers.EQUIPMENT:
		tables = [content.equipment]
	var candidates: Array = []
	for table in tables:
		for id in _sorted_ids(table):
			var entry: Resource = table[id]
			if not Unlocks.is_unlocked(entry) or not TagMatch.matches(query, entry.tags) or TagMatch.has(entry.tags, DEV_TAG):
				continue
			if table == content.equipment and entry.tags.is_empty():
				continue  # unpooled equipment (loadouts, events) is never offered
			if pools.get("held", []).has(id) or pools.get("seen", []).has(id) or not _in_card_pool(pools, id):
				continue
			candidates.append(entry)
	var picked: Resource = _pick_pooled(stream, candidates)
	if picked == null:
		# Spec unique-events 2.4: food; the armory (EQUIPMENT) too, but never the fallback item.
		picked = _drained(stream, pools, offers != RoomPlacement.Offers.EQUIPMENT)
	return picked


## Spec keys-and-gear 3.2: a piece of pooled equipment matching `query` (not held, not seen; rarity weights). With
## `prefer_slots`, pieces for those slot tags are picked first when there are any. Null when nothing is left.
func pick_equipment(query: GameplayTagQuery, stream: RandomNumberGenerator, pools: Dictionary,
		prefer_slots: Array[StringName] = [], only_slot: StringName = &"") -> EquipmentDefinition:
	var candidates: Array = []
	var preferred: Array = []
	for id in _sorted_ids(content.equipment):
		var piece: EquipmentDefinition = content.equipment[id]
		if piece.tags.is_empty() or not Unlocks.is_unlocked(piece) or not TagMatch.matches(query, piece.tags):
			continue
		if only_slot != &"" and piece.slot != only_slot:
			continue  # spec event-pass: GiveEquipment.only_slot (a weapon rack gives a weapon)
		if TagMatch.has(piece.tags, DEV_TAG) or pools.get("held", []).has(id) or pools.get("seen", []).has(id) \
				or not _in_card_pool(pools, id):
			continue
		candidates.append(piece)
		if prefer_slots.has(piece.slot):
			preferred.append(piece)
	return _pick_pooled(stream, preferred if not preferred.is_empty() else candidates)


## Spec unique-events 2.4: what a pool pick with nothing left gives: a food item (Pool.Food, unlocked, not a dev item, in the
## card pool, held and seen ones too, not in pools["unholdable"]) on `stream`, which the empty pick left untouched; no food
## → the run's fallback item when `use_fallback`; neither → null, with a warning. Counted in pools_drained.
func drained_food(stream: RandomNumberGenerator, pools: Dictionary, use_fallback: bool = true) -> ItemDefinition:
	return _drained(stream, pools, use_fallback)


func _drained(stream: RandomNumberGenerator, pools: Dictionary, use_fallback: bool) -> ItemDefinition:
	pools_drained += 1
	var unholdable: Array = pools.get("unholdable", [])
	var candidates: Array = []
	for item_id in _sorted_ids(content.items):
		var item: ItemDefinition = content.items[item_id]
		if not TagMatch.has(item.tags, FOOD_POOL) or not Unlocks.is_unlocked(item) or TagMatch.has(item.tags, DEV_TAG):
			continue
		if unholdable.has(item_id) or not _in_card_pool(pools, item_id):
			continue
		candidates.append(item)
	var picked: ItemDefinition = _pick_pooled(stream, candidates)
	if picked == null and use_fallback and run_structure != null:
		picked = run_structure.fallback_item
	if picked == null and use_fallback:
		warnings.append("a drained item pool found no food a member can hold and no fallback item")
	return picked


## A room pickup: {"placement", "item": the item or equipment id, "price", "taken"}, plus "kind": "equipment" for a
## piece of equipment (items carry no kind, so their pickups, hashes and goldens are unchanged).
static func pickup_entry(placement: int, picked: Resource, price: int) -> Dictionary:
	var entry := {"placement": placement, "item": picked.id, "price": price, "taken": false}
	if picked is EquipmentDefinition:
		entry["kind"] = EQUIPMENT_KIND
	return entry


func _in_chapter(room: RoomDefinition, chapter: ChapterDefinition, any_chapter: bool) -> bool:
	if not any_chapter:
		return TagMatch.matches(chapter.room_query, room.tags)
	for slot in run_structure.floors:
		for other in slot.chapters:
			if other != null and TagMatch.matches(other.room_query, room.tags):
				return true
	return false


static func _type_tag(rules: FloorGenRules, data: Dictionary) -> StringName:
	match data["role"]:
		FloorMap.ROLE_START:
			return rules.start_room_tag
		FloorMap.ROLE_BOSS:
			return rules.boss_room_tag
		FloorMap.ROLE_SPECIAL:
			return data["special_tag"]
	return rules.normal_room_tag


func _matching(index: Dictionary, query: GameplayTagQuery) -> Array:
	var result: Array = []
	for id in _sorted_ids(index):
		if TagMatch.matches(query, index[id].tags):
			result.append(index[id])
	return result


static func _dead_ends(map: FloorMap) -> Array[int]:
	var result: Array[int] = []
	for index in map.sorted_indices():
		if index != map.start and map.neighbours(index).size() == 1:
			result.append(index)
	return result


static func _fill(map: FloorMap, index: int) -> void:
	map.cells[index] = {
		"cell": map.cell_of(index), "role": FloorMap.ROLE_NORMAL, "special_tag": &"", "room": &"", "doors": 0,
		"content": {"kind": "none", "encounter": &"", "event": &"", "enemies": []}, "pickups": [],
		"visited": false, "cleared": false,
	}


static func _sorted_ids(index: Dictionary) -> Array:
	var ids := index.keys()
	ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	return ids


static func _error(message: String) -> Dictionary:
	return {"map": null, "error": message}
