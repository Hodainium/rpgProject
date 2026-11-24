## Spec bot-play 2.7: the smart run bot's numbers. The bots decide by conditionals on tags (ExplorePlan, LootScorer,
## BotGear); a profile only holds the numbers they weigh with, so a better bot is a better file, not new code. Whole
## numbers; shares are percents. Bot code, not game balance: the shipped profiles live in game/auto/profiles/.
@tool
class_name BotProfile
extends Resource

const SPREAD: int = 0
const FLAT: int = 1
const CARRY: int = 2

const EXPLORE_SMART: String = "smart"
const EXPLORE_FULL: String = "full"
const EXPLORE_BOSS: String = "boss"
const EXPLORE_MODES: Array[String] = [EXPLORE_SMART, EXPLORE_FULL, EXPLORE_BOSS]
const PARTS: Array[String] = ["explore", "placement", "gear", "shop", "field"]

## A name for the report.
@export var id: String = "smart"
## Which of the bot's decisions are on (spec 2.7: each change measured alone); a part left out plays as RunPlayer did
## before the slice: explore (ExplorePlan), placement (free pickups and gifts by LootScorer), gear (BotGear.improve),
## shop (BotGear.shop), field (BotGear.field_before).
@export var parts: Array[String] = PARTS.duplicate()
## Exploration (2.2): what each special room tag on a floor's rules is worth; a floor whose rules sum to at least the
## threshold is explored fully, any other goes straight to the boss. `explore` forces one mode (smart = by the rule).
@export var room_values: Dictionary = {
	&"Room.Type.Treasure": 100, &"Room.Type.Shop": 60, &"Room.Type.Armory": 60, &"Room.Type.Altar": 100,
	&"Room.Type.Challenge": 20,
}
@export var explore_threshold: int = 50
@export_enum("smart", "full", "boss") var explore: String = EXPLORE_SMART
## On a FULL floor: true visits every room (more fights, more XP); false heads for the boss once every room the floor
## rules value has been visited (or is locked with no key to open it) (user, 2026-11-22).
@export var exploratory: bool = true
## Placement (2.4): fit tag -> {role tag or "*" -> weight}. A member is weighed by its best live role for the fit; "*" for
## a member none of whose roles the fit names.
@export var fit_weight: Dictionary = {
	&"Item.Fit.Damage": {&"Unit.Role.Damage": 100, &"Unit.Role.FollowUp": 80, &"Unit.Role.Dot": 60,
		&"Unit.Role.Break": 60, "*": 30},
	&"Item.Fit.FollowUp": {&"Unit.Role.FollowUp": 120, &"Unit.Role.Damage": 70, "*": 30},
	&"Item.Fit.Dot": {&"Unit.Role.Dot": 120, &"Unit.Role.Damage": 50, "*": 25},
	&"Item.Fit.Break": {&"Unit.Role.Break": 120, &"Unit.Role.Damage": 60, "*": 30},
	&"Item.Fit.Healing": {&"Unit.Role.Healer": 120, &"Unit.Role.Support": 50, "*": 10},
	&"Item.Fit.Survival": {&"Unit.Role.Tank": 100, "*": 80},
	&"Item.Fit.Speed": {&"Unit.Role.Support": 90, &"Unit.Role.Healer": 80, &"Unit.Role.Control": 80, "*": 60},
	&"Item.Fit.Sp": {&"Unit.Role.Support": 90, &"Unit.Role.Healer": 80, &"Unit.Role.Damage": 70, "*": 60},
	&"Item.Fit.Ult": {&"Unit.Role.Damage": 80, &"Unit.Role.Support": 70, "*": 60},
	&"Item.Fit.Control": {&"Unit.Role.Control": 120, &"Unit.Role.Support": 60, "*": 40},
	&"Item.Fit.Party": {"*": 60},
	&"Item.Fit.Run": {"*": 40},
}
## Fit tag -> {"mode": SPREAD | FLAT | CARRY, "step": percent per held thing of that fit}. Unlisted fits are FLAT.
@export var stack: Dictionary = {
	&"Item.Fit.Survival": {"mode": SPREAD, "step": 25},
}
## What an Item.Grants.* adds when the member does not have that role yet.
@export var new_role_value: int = 50
## With CARRY fits, one member piles up every CARRY kind (the first goes to the best damage dealer by the weights).
@export var carry_seed: bool = true
## Item.Fit.Party: added per Survival-fit thing the member holds, and for the Tank role.
@export var party_survival_step: int = 20
@export var party_tank_bonus: int = 40
## Gear (2.5): a move is made only when it raises the score by this percent; at most max_moves per trigger.
@export var swap_margin: int = 15
@export var max_moves: int = 6
## Shops (2.6): nothing worth less than buy_floor to the party is bought.
## With no key held, a shelf's key is always bought when the next floor's rules lock a room with one of these tags
## (user, 2026-11-22: the next floor's item room).
@export var next_floor_key_rooms: Array[StringName] = [&"Room.Type.Treasure"]
@export var buy_floor: int = 10
## A pickup paid with an item (an altar's Void Scar, a curse price) is taken only when its best holder values it at least
## this much (user, 2026-11-22). 0 takes them all, the old rule.
@export var altar_floor: int = 0
## Field actions (2.6): heal a member under this HP percent before a battle room; restore SP under this percent before the
## boss.
@export var field_heal_below: int = 50
@export var field_sp_below: int = 30
## At most this many field actions before one room.
@export var field_max_uses: int = 4


func uses(part: String) -> bool:
	return parts.has(part)


## The weight of `fit` for a member with `roles` (its best role for the fit, else "*").
func weight(fit: StringName, roles: Array[StringName]) -> int:
	var table: Dictionary = _lookup(fit_weight, fit, {})
	var best := -1
	for role in roles:
		var value: Variant = _lookup(table, role, null)
		if value != null:
			best = maxi(best, int(value))
	if best >= 0:
		return best
	return int(table.get("*", 0))


func stack_mode(fit: StringName) -> int:
	var row: Variant = _lookup(stack, fit, null)
	return int(row.get("mode", FLAT)) if row is Dictionary else FLAT


func stack_step(fit: StringName) -> int:
	var row: Variant = _lookup(stack, fit, null)
	return int(row.get("step", 0)) if row is Dictionary else 0


func room_value(tag: StringName) -> int:
	return int(_lookup(room_values, tag, 0))


## A dictionary looked up by a tag whether it was saved with StringName or String keys.
static func _lookup(table: Dictionary, key: Variant, fallback: Variant) -> Variant:
	if table.has(key):
		return table[key]
	if table.has(String(key)):
		return table[String(key)]
	if table.has(StringName(key)):
		return table[StringName(key)]
	return fallback
