## Isaac-style seeded floor generator (spec game-skeleton 3.2). Integers and the run's seeded streams only.
##
## generate() and from_layout() return {"map": FloorMap, "error": String}. The "pools" argument carries what the
## item pools must know: {"party": Array[StringName] character ids, "held": Array[StringName], "seen": Array[StringName]}
## ("seen" is extended with every item placed, so no item appears twice in a run).
class_name FloorGenerator
extends RefCounted

## Items tagged Dev (the dev stat items, spec dev-tools 3.3) are never in a pool.
const DEV_TAG: StringName = &"Dev"
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
	return _resolve(map, chapter, pools)


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
	return _resolve(map, chapter, pools, overrides)


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
func _resolve(map: FloorMap, chapter: ChapterDefinition, pools: Dictionary, overrides: Dictionary = {}) -> Dictionary:
	var content_rng := seeds.floor_rng(depth, "content")
	for index in map.sorted_indices():
		var data: Dictionary = map.cells[index]
		var room: RoomDefinition = content.rooms[data["room"]]
		var override: FloorLayoutCell = overrides.get(index)
		var resolved := _resolve_content(room, chapter, data["role"] == FloorMap.ROLE_BOSS, content_rng, override)
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
			var picked := pick_pickup(placement.item, placement.equipment, placement.item_query, loot_rng, pools)
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
		override: FloorLayoutCell) -> Dictionary:
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
				var query := room.content_query if room.content_query != null else chapter.event_query
				event = RunSeeds.pick_weighted(stream, _matching(content.events, query))
				if event == null:
					return {"error": "no event matches the event query"}
	if encounter != null:
		return {"kind": "encounter", "encounter": encounter.id, "event": &"",
			"enemies": resolve_enemies(encounter, room, is_boss, chapter.scaling, stream)}
	if event != null:
		return {"kind": "event", "encounter": &"", "event": event.id, "enemies": []}
	return {"kind": "none", "encounter": &"", "event": &"", "enemies": []}


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
## functions below ask; fixed items, loadouts, drops and mirrors never do.
static func _in_card_pool(pools: Dictionary, id: StringName) -> bool:
	var pool: Variant = pools.get("card_pool")
	return pool == null or pool.has(id)


## A fixed item, or one picked from the pool (unlocked, not held, not seen this run).
## Falls back to the run structure's fallback_item.
func pick_item(fixed: ItemDefinition, query: GameplayTagQuery, stream: RandomNumberGenerator, pools: Dictionary) -> ItemDefinition:
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
	if picked == null and run_structure != null:
		picked = run_structure.fallback_item
	return picked


## Spec item-pass 3.5: what a pedestal or shop slot offers. A fixed item or piece, else one pick from the items and
## the equipment matching the query together (items first, then equipment, each by id, so content without pooled
## equipment picks exactly as before). Falls back to the run structure's fallback_item.
func pick_pickup(fixed_item: ItemDefinition, fixed_equipment: EquipmentDefinition, query: GameplayTagQuery,
		stream: RandomNumberGenerator, pools: Dictionary) -> Resource:
	if fixed_item != null:
		return fixed_item
	if fixed_equipment != null:
		return fixed_equipment
	var candidates: Array = []
	for table in [content.items, content.equipment]:
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
	if picked == null and run_structure != null:
		picked = run_structure.fallback_item
	return picked


## Spec keys-and-gear 3.2: a piece of pooled equipment matching `query` (not held, not seen; rarity weights). With
## `prefer_slots`, pieces for those slot tags are picked first when there are any. Null when nothing is left.
func pick_equipment(query: GameplayTagQuery, stream: RandomNumberGenerator, pools: Dictionary,
		prefer_slots: Array[StringName] = []) -> EquipmentDefinition:
	var candidates: Array = []
	var preferred: Array = []
	for id in _sorted_ids(content.equipment):
		var piece: EquipmentDefinition = content.equipment[id]
		if piece.tags.is_empty() or not Unlocks.is_unlocked(piece) or not TagMatch.matches(query, piece.tags):
			continue
		if TagMatch.has(piece.tags, DEV_TAG) or pools.get("held", []).has(id) or pools.get("seen", []).has(id) \
				or not _in_card_pool(pools, id):
			continue
		candidates.append(piece)
		if prefer_slots.has(piece.slot):
			preferred.append(piece)
	return _pick_pooled(stream, preferred if not preferred.is_empty() else candidates)


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
