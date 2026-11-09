## The state of one run (spec game-skeleton 3.6). Plain data: slice 2b moves it to Postgres one-to-one.
##
## party: Array of members sorted by slot: {
##   "slot": int, "character": StringName, "level": int,
##   "hp": int, "mp": int or null, "energy": int or null (×100, like the attributes), "alive": bool,
##   "skills": Array[StringName] (learned skills beyond the base kit),
##   "items": Array[StringName] (passive items, pickup order),
##   "use_slots": Array of {"item": StringName, "cooldown": int (won battles left; 0 = ready)},
##   "equipment": Dictionary slot tag → equipment id }
class_name RunState
extends RefCounted

const ACTIVE: String = "Active"
const WON: String = "Won"
const LOST: String = "Lost"

var run_id: String = ""
var run_seed: int = 0
## Spec server-authority 3.5: server mode only, floor index → the floor seed the server issued (empty in local mode).
## The run's streams come from seeds(), never from run_seed directly.
var floor_seeds: Dictionary = {}
var run_structure_id: StringName = &""
var party: Array[Dictionary] = []
var coins: int = 0
## Every item placed or given this run (no item appears twice). Equipment offered on pedestals is listed here too.
var seen_items: Array[StringName] = []
## Spec item-pass 3.5: the party's armor inventory, equipment ids in pickup order. Pieces found in the run land here
## and are equipped from here; they are never dropped. Hashed only when not empty.
var armor: Array[StringName] = []
var floor_index: int = 0
var chapter_id: StringName = &""
var map: FloorMap
var current_cell: int = -1
var boss_cleared: bool = false
## Counters for the order-dependent streams (field actions, item gifts) on the current floor.
var field_actions_on_floor: int = 0
var gifts_on_floor: int = 0
## The open event: {"cell": int, "event": StringName, "page": int}, or empty. Spec event-items: while a choice waits for
## give_to it also holds "after" ({"kind": "page" | "encounter" | "end", "page", "encounter"}).
var event: Dictionary = {}
## Spec run-verify: the battle waiting in the current room and the floor waiting for its seed. They decide what the run can do
## next, so they belong to the state the run hash covers (RunController reads and writes them through its own properties).
var pending_battle: Dictionary = {}
var waiting_floor: Dictionary = {}
## Spec event-items: items waiting for the player to pick their holder (give_to), in order. Not hashed: the hash is
## taken between actions, and a given item is hashed in its holder's line.
var pending_gifts: Array[StringName] = []
var status: String = ACTIVE
## Dev tools (spec dev-tools 3.4): a cheat or a sandbox happened in this run. Hashed only when true, so it can never pass
## as a clean run, and clean runs hash exactly as before.
var dev: bool = false
## A sandbox run (one room or one hand-made floor); never a next floor.
var sandbox: bool = false
## The console's `reveal`: the map view shows every room. A view flag, not hashed.
var revealed: bool = false
## Spec keys-and-gear 2.7: event rooms show their type on this floor (a RevealRooms outcome). A view flag, not hashed.
var reveal_events: bool = false
## Spec keys-and-gear 3.1: keys (0-99), the golden key (this floor only), the chest inventory in drop order
## ({"chest": id, "serial": int}) and the next chest serial (its contents stream is "chest/<serial>").
var keys: int = 0
var golden_key: bool = false
var chests: Array[Dictionary] = []
var chest_serial: int = 0
## Dev commands so far; the k-th one draws from the stream "dev/<k>".
var dev_commands: int = 0
## Spec card-collection 2.5: the item pool of the run (item and equipment ids: the core set and the cards owned at the start).
## Only picks from the item pools are restricted to it (FloorGenerator); loadouts, named gifts, drops and mirrors ignore it.
## `card_pool_set` false = unrestricted (local mode today). The pool is the server's input (never in a snapshot), and the run
## hash covers a digest of it only when it is set, so runs without one hash exactly as before.
var card_pool: Array[StringName] = []
var card_pool_set: bool = false


## Restricts the item pools to `ids` (any array of ids); sorted, so the digest never depends on the order they arrived in.
func set_card_pool(ids: Array) -> void:
	var sorted: Array[String] = []
	for id in ids:
		sorted.append(String(id))
	sorted.sort()
	card_pool.clear()
	for id in sorted:
		card_pool.append(StringName(id))
	card_pool_set = true


## SHA-256 of the sorted pool ids joined by commas (what the run hash carries).
func card_pool_digest() -> String:
	return digest_of(card_pool)


## The same digest for any array of ids (a save's pool, checked against the digest it was written with).
static func digest_of(ids: Array) -> String:
	var sorted: Array[String] = []
	for id in ids:
		sorted.append(String(id))
	sorted.sort()
	return StateHasher.sha256_hex(",".join(sorted))


## "" when `saved` (a local save or ServerLink save) kept the pool it was written with, else why not. A save of a run without a
## pool has no digest and is fine. A missing or changed pool would make every hash of the run differ from the server's.
static func save_pool_problem(saved: Dictionary) -> String:
	if not saved.has("cardPoolDigest"):
		return ""
	if not saved.get("cardPool") is Array:
		return "the save lost its card pool"
	return "" if digest_of(saved["cardPool"]) == str(saved["cardPoolDigest"]) else "the save's card pool was changed"



## The run's seed source: local (the run seed) or server (the issued floor seeds).
func seeds() -> SeedSource:
	return SeedSource.new(run_seed, floor_seeds)


func member(slot: int) -> Dictionary:
	for entry in party:
		if entry["slot"] == slot:
			return entry
	return {}


## Slot of the member playing `character_id` (alive only when asked), or 0.
func member_slot(character_id: StringName, alive_only: bool = true) -> int:
	for entry in party:
		if entry["character"] == character_id and (entry["alive"] or not alive_only):
			return entry["slot"]
	return 0


## Slot of the member holding `item_id` (passive or in a use slot), or 0.
func holder_of(item_id: StringName) -> int:
	for entry in party:
		if entry["items"].has(item_id):
			return entry["slot"]
		for use_slot in entry["use_slots"]:
			if use_slot["item"] == item_id:
				return entry["slot"]
	return 0


## Every item held by anyone.
func held_items() -> Array[StringName]:
	var result: Array[StringName] = []
	for entry in party:
		result.append_array(entry["items"])
		for use_slot in entry["use_slots"]:
			result.append(use_slot["item"])
	return result


## Every piece of equipment the party has: equipped by anyone, or in the armor inventory.
func held_equipment() -> Array[StringName]:
	var result: Array[StringName] = []
	for entry in party:
		for tag in entry["equipment"]:
			result.append(entry["equipment"][tag])
	result.append_array(armor)
	return result


func party_characters() -> Array[StringName]:
	var result: Array[StringName] = []
	for entry in party:
		result.append(entry["character"])
	return result


func anyone_alive() -> bool:
	for entry in party:
		if entry["alive"]:
			return true
	return false


## Canonical lines for the run hash (spec 3.6).
func canonical_lines() -> PackedStringArray:
	var lines := PackedStringArray([
		"run-v2",
		"seed=%d" % run_seed,
		"structure=%s" % run_structure_id,
		"status=%s" % status,
		"floor=%d|chapter=%s|cell=%d|boss_cleared=%d" % [floor_index, chapter_id, current_cell, 1 if boss_cleared else 0],
		"coins=%d" % coins,
		"counters=%d|%d" % [field_actions_on_floor, gifts_on_floor],
		"seen=%s" % ",".join(seen_items),
	])
	if not floor_seeds.is_empty():
		# Spec server-authority 3.5: server mode only, so local runs hash exactly as before.
		lines.insert(2, "floor_seed=%d" % int(floor_seeds.get(floor_index, 0)))
	for entry in party:
		var slots := PackedStringArray()
		for use_slot in entry["use_slots"]:
			slots.append("%s:%d" % [use_slot["item"], use_slot["cooldown"]])
		var gear := PackedStringArray()
		var slot_tags: Array = entry["equipment"].keys()
		slot_tags.sort()
		for tag in slot_tags:
			gear.append("%s=%s" % [tag, entry["equipment"][tag]])
		var line := "member=%d|%s|%d|%s|%s|%s|%d|%s|%s|%s|%s" % [entry["slot"], entry["character"], entry["level"],
			entry["hp"], entry["mp"], entry["energy"], 1 if entry["alive"] else 0, ",".join(entry["skills"]),
			",".join(entry["items"]), ",".join(slots), ",".join(gear)]
		if int(entry.get("xp", 0)) > 0:
			line += "|xp=%d" % entry["xp"]  # spec playable-demo 3.11; never on a run without XP
		lines.append(line)
	if not armor.is_empty():
		lines.append("armor=%s" % ",".join(armor))
	if keys > 0 or golden_key or not chests.is_empty() or chest_serial > 0:
		# Spec keys-and-gear 3.1: only on runs that ever saw a key or a chest, so older runs hash as before.
		var held := PackedStringArray()
		for chest in chests:
			held.append("%s:%d" % [chest["chest"], chest["serial"]])
		lines.append("keys=%d|golden=%d|chests=%s|serial=%d" % [keys, 1 if golden_key else 0, ",".join(held), chest_serial])
	if map != null:
		lines.append_array(map.canonical_lines())
	# Spec run-verify: everything else that decides play, each only when set (so most lines are absent most of the time). Left out on
	# purpose, with the reason: run_id (identity, which a step compares against the run itself), the seeds of floors not entered yet
	# (the server's own are the reference), dev_commands (a counter of console cheats), and the log, tallies and requested floors
	# (summaries and network bookkeeping, never read by a rule).
	if not event.is_empty():
		lines.append("event=" + StateHasher.canonical(event))
	if not pending_gifts.is_empty():
		lines.append("gifts=" + ",".join(pending_gifts))
	if revealed:
		lines.append("revealed=1")
	if reveal_events:
		lines.append("reveal_events=1")
	if sandbox:
		lines.append("sandbox=1")
	if not pending_battle.is_empty():
		lines.append("pending=" + StateHasher.canonical(pending_battle))
	if not waiting_floor.is_empty():
		lines.append("waiting=" + StateHasher.canonical(waiting_floor))
	if card_pool_set:
		lines.append("card_pool=" + card_pool_digest())  # spec card-collection 2.5
	if dev:
		lines.append("dev=1")
	return lines


## SHA-256 of the canonical lines, lowercase hex.
func run_hash() -> String:
	return StateHasher.sha256_hex("\n".join(canonical_lines()))
