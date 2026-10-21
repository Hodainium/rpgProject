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
func delay(unit: BattleUnit, percent: int) -> void:
	if av.has(unit):
		av[unit] += Fixed.pct(full_av(unit), percent)


## SPD changed mid-cycle: rescale the remaining distance, av = av * old / new (integer division).
@warning_ignore("integer_division")
func on_spd_changed(unit: BattleUnit, old_spd: float, new_spd: float) -> void:
	if not av.has(unit) or int(new_spd) <= 0 or int(old_spd) <= 0:
		return
	av[unit] = av[unit] * int(old_spd) / int(new_spd)


func _goes_before(a: BattleUnit, b: BattleUnit) -> bool:
	if av[a] != av[b]:
		return av[a] < av[b]
	if a.side != b.side:
		return a.side == BattleUnit.Side.PARTY
	return a.slot < b.slot
