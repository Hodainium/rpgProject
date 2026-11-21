## Spec ui-feedback 2.2: what a refused action was about, as the `data` of GameMain.refuse: {"target": <one of the
## names below>, extras}. The screen that tried the action asks here; the answer comes from the run's state (the same
## checks the run made), never from the refusal's text. {} = nothing to flash (an internal guard: the sound only).
## Read-only and presentation only: nothing here changes or logs the run.
class_name UIRefusal
extends RefCounted

const TARGET: StringName = &"target"
## A room tile on the big map and the minimap ("cell").
const ROOM := "room"
## A locked room's tile ("cell") or a locked chest's Open row ("chest" serial); the Keys counter pulses too.
const LOCK := "lock"
const KEYS := "keys"
## The Gold counter; with "placement", that pickup row's price pulses too (the spec's `price`, sent with `gold`).
const GOLD := "gold"
## A party member's row ("slot", or "unit" in battle).
const MEMBER := "member"
## A member's item slots ("slot"; "slots" when two members trade and either may be the one over).
const MEMBER_ITEMS := "member_items"
## An equipment slot on the gear screen ("slot", "equipment_slot": an Equipment.Slot.* tag or the use slot's number).
const GEAR_SLOT := "gear_slot"
## A member's SP bar ("slot" outside battle, "unit" in battle).
const SP := "sp"
## The skill's row in the battle command window or the Use Ability list ("ability").
const COMMAND := "command"
## A target the skill can't take ("unit" in battle).
const UNIT_TARGET := "target"
## The Give-to panel (an item waits for its holder).
const GIFT := "gift"


static func make(target: String, extras: Dictionary = {}) -> Dictionary:
	var data := extras.duplicate()
	data[TARGET] = target
	return data


## The waiting gift blocks every other run action (spec event-items).
static func gift_waiting(run: RunController) -> bool:
	return run != null and run.state != null and not run.state.pending_gifts.is_empty()


## Entering room `index` (the big map). Rows 1, 2, 10.
static func for_enter(run: RunController, index: int) -> Dictionary:
	if run == null or run.state == null:
		return {}
	if gift_waiting(run):
		return make(GIFT)
	if not run.can_enter(index):
		return make(ROOM, {"cell": index})
	if run.room_locked(index) and not run.state.golden_key and run.state.keys <= 0:
		return make(LOCK, {"cell": index})
	return {}


## Taking or buying pickup `placement` for the member in `slot`. Rows 6, 7, 8, 9, 10.
static func for_take(run: RunController, placement: int, slot: int) -> Dictionary:
	if run == null or run.state == null or run.state.map == null:
		return {}
	if run.state.status != RunState.ACTIVE or not run.pending_battle.is_empty():
		return {}  # "not now": the sound only
	if gift_waiting(run):
		return make(GIFT)
	var data: Dictionary = run.state.map.cells.get(run.state.current_cell, {})
	if not data.get("cleared", false):
		return {}  # "clear the room first": its rows are not even shown (row 4)
	for pickup in data.get("pickups", []):
		if pickup["placement"] != placement or pickup["taken"]:
			continue
		if pickup["price"] > run.state.coins:
			return make(GOLD, {"placement": placement})
		if pickup.get("kind", "") == FloorGenerator.KEYS_KIND:
			return make(KEYS) if run.state.keys >= RunStructure.MAX_KEYS else {}
		if pickup.get("kind", "") == FloorGenerator.EQUIPMENT_KIND:
			return {}
		var held := for_hold(run, slot, run.content.items.get(pickup["item"]))
		if not held.is_empty():
			held["placement"] = placement
		return held
	return {}


## Opening chest `serial` in this room. Rows 2, 10.
static func for_chest(run: RunController, serial: int) -> Dictionary:
	if run == null or run.state == null:
		return {}
	if gift_waiting(run):
		return make(GIFT)
	# Only a missing key is a lock (another reason, such as "not now", flashes nothing).
	var keyless := run.state.keys <= 0 and not run.state.golden_key
	for chest in run.room_chests():
		if int(chest["serial"]) == serial and not chest["opened"] and chest["needs_key"] and not chest["free"] and keyless:
			return make(LOCK, {"chest": serial})
	return {}


## Giving `item` to the member in `slot` (a pickup, a gift). Rows 8, 9.
static func for_hold(run: RunController, slot: int, item: ItemDefinition) -> Dictionary:
	if run == null or run.state == null or item == null:
		return {}
	var member := run.state.member(slot)
	if member.is_empty():
		return {}
	if not member["alive"]:
		return make(MEMBER, {"slot": slot})
	if run.can_hold(slot, item) != "":
		return make(MEMBER_ITEMS, {"slot": slot})
	return {}


## Moving a use item from `from_slot` to `to_slot` (with `swap`, trading places). Rows 8, 12: a plain move overfills the
## receiver; a trade can overfill either side, so both members' slots flash.
static func for_move(run: RunController, from_slot: int, to_slot: int, swap: bool) -> Dictionary:
	if gift_waiting(run):
		return make(GIFT)
	if run == null or run.state == null or run.state.member(from_slot).is_empty() or run.state.member(to_slot).is_empty() \
			or from_slot == to_slot:
		return {}
	return make(MEMBER_ITEMS, {"slot": to_slot, "slots": [to_slot, from_slot] if swap else [to_slot]})


## Equip, swap or take off on the gear screen. Row 11.
static func for_gear(run: RunController, slot: int, equipment_slot: Variant) -> Dictionary:
	if gift_waiting(run):
		return make(GIFT)
	return make(GEAR_SLOT, {"slot": slot, "equipment_slot": equipment_slot})


## A field use refused (RunController.use_field's [reason, detail]) for the member in `slot`. Row 13: "cannot activate"
## flashes the SP bar when SP is short (`sp_cost_x100`, the hint's exact cost, against the member's SP ×100), else the
## ability's row; an invalid target flashes that member.
static func for_field_use(run: RunController, reason: String, slot: int, ability: StringName, sp_cost_x100: int,
		target_slot: int) -> Dictionary:
	if reason == "NotNow" and gift_waiting(run):
		return make(GIFT)
	match reason:
		"IllegalAbility":
			var stats: Dictionary = run.party_stats().get(slot, {}) if run != null else {}
			if sp_cost_x100 > 0 and int(stats.get(BattleUnit.MP, 0)) < sp_cost_x100:
				return make(SP, {"slot": slot})
			return make(COMMAND, {"ability": ability, "slot": slot})
		"InvalidTarget":
			return make(MEMBER, {"slot": target_slot}) if target_slot > 0 else make(COMMAND, {"ability": ability,
				"slot": slot})
		"DeadActor":
			return make(MEMBER, {"slot": slot})
	return {}


## A battle action refused (ActionRecorder.action_rejected's reason) for `unit` casting `ability` at `target_id`. Rows 15,
## 16: "cannot activate" flashes the caster's SP bar and the skill's row when SP is short, else the row only; a target the
## skill can't take flashes that target's row.
static func for_battle(reason: String, unit: BattleUnit, ability: BattleAbility, target_id: StringName) -> Dictionary:
	if unit == null:
		return {}
	var tag: StringName = ability.ability_tag if ability != null else &""
	match reason:
		"IllegalAbility":
			var cost := CostReader.sp_cost(ability, unit.asc) if ability != null else 0
			var short := cost > 0 and unit.asc.has_attribute(BattleUnit.MP) and unit.stat(BattleUnit.MP) < cost
			return make(SP if short else COMMAND, {"unit": unit.unit_id, "ability": tag})
		"InvalidTarget":
			return make(UNIT_TARGET, {"unit": target_id, "ability": tag}) if target_id != &"" \
				else make(COMMAND, {"unit": unit.unit_id, "ability": tag})
		"DeadActor", "ActorMismatch":  # not this unit's move: its row, never its SP
			return make(MEMBER, {"unit": unit.unit_id})
	return {}
