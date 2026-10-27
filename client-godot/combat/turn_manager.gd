## HSR-style action value turn order, integers only (spec "Turn order").
##
## full_av = AV_SCALE / SPD, where SPD is stored ×100: SPD 100 (10000) → 10000 = 100.00 AV.
## The living unit with the lowest AV acts next; ties go Party before Enemy, then lower slot first.
class_name TurnManager
extends RefCounted

## HSR's 10 000 gauge, ×100 for two decimals of AV, ×100 because SPD is stored ×100.
const AV_SCALE: int = 100_000_000
## SPD below 1.00 is a content error.
const MIN_SPD: int = 100

var av: Dictionary = {}  # BattleUnit -> int


## Content error message, or "" when the unit's SPD is valid.
static func spd_problem(unit: BattleUnit) -> String:
	var spd := unit.stat(BattleUnit.SPD)
	return "" if spd >= MIN_SPD else "%s has SPD %s (below 1)" % [unit.unit_id, Fixed.to_display(spd)]


@warning_ignore("integer_division")
static func full_av(unit: BattleUnit) -> int:
	return AV_SCALE / maxi(unit.stat(BattleUnit.SPD), MIN_SPD)


func add(unit: BattleUnit) -> void:
	av[unit] = full_av(unit)


func remove(unit: BattleUnit) -> void:
	av.erase(unit)


## The next actor among the queued units.
func next_actor() -> BattleUnit:
	var best: BattleUnit = null
	for unit in av:
		if best == null or _goes_before(unit, best):
			best = unit
	return best


## Moves time forward to the actor's turn: every queued unit's AV drops by the actor's AV.
func elapse(actor: BattleUnit) -> void:
	var elapsed: int = av[actor]
	for unit in av:
		av[unit] -= elapsed


## After acting, the actor starts a full cycle using its current SPD.
func reset(actor: BattleUnit) -> void:
	if av.has(actor):
		av[actor] = full_av(actor)


## HSR action delay (spec item-pass 3.2): pushes the unit back by `percent` (stored ×100) of its full action value.
## A negative percent is an action advance (spec content-pass H6); the remaining action value never drops below 0.
func delay(unit: BattleUnit, percent: int) -> void:
	if av.has(unit):
		av[unit] = maxi(av[unit] + Fixed.pct(full_av(unit), percent), 0)


## SPD changed mid-cycle: rescale the remaining distance, av = av * old / new (integer division).
@warning_ignore("integer_division")
func on_spd_changed(unit: BattleUnit, old_spd: float, new_spd: float) -> void:
	if not av.has(unit) or int(new_spd) <= 0 or int(old_spd) <= 0:
		return
	av[unit] = av[unit] * int(old_spd) / int(new_spd)


## Spec ff7-ui 2.6 (presentation only, never called by Battle.run): the next `count` turns if nothing changes, as
## [{"unit": BattleUnit, "av": int}] where av is the action value from now until that turn. Works on a copy of the
## table with the same rules as next_actor / elapse / reset, so the live order is never touched.
func preview(count: int) -> Array:
	var table := av.duplicate()
	var result: Array = []
	var elapsed_total := 0
	for i in count:
		var best: BattleUnit = null
		for unit in table:
			if best == null or _before_in(table, unit, best):
				best = unit
		if best == null:
			break
		var elapsed: int = table[best]
		elapsed_total += elapsed
		result.append({"unit": best, "av": elapsed_total})
		for unit in table:
			table[unit] -= elapsed
		table[best] = full_av(best)
	return result


func _goes_before(a: BattleUnit, b: BattleUnit) -> bool:
	return _before_in(av, a, b)


static func _before_in(table: Dictionary, a: BattleUnit, b: BattleUnit) -> bool:
	if table[a] != table[b]:
		return table[a] < table[b]
	if a.side != b.side:
		return a.side == BattleUnit.Side.PARTY
	return a.slot < b.slot
