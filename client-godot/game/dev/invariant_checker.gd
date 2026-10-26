## Battle invariants for the chaos policy (spec playable-demo 2.3b), checked at every trace point: the battle's start,
## each turn (party and enemy), One More, ult interrupt and dev decision, and its end. Attach it as `Battle.trace`.
## It only reads state; it records no hashes unless `keep_trace` (then it is also a full BattleTrace, with lines).
class_name InvariantChecker
extends BattleTrace

## Per battle, so one broken rule can't flood the report.
const MAX_VIOLATIONS: int = 20
const BOUNDED: Array = [[BattleUnit.HP, BattleUnit.MAX_HP], [BattleUnit.MP, BattleUnit.MAX_MP],
	[BattleUnit.ENERGY, BattleUnit.MAX_ENERGY], [Battle.TOUGHNESS, Battle.MAX_TOUGHNESS]]

## [{"invariant", "point", "kind", "turn", "actor", "ability", "unit", "detail"}], in order.
var violations: Array[Dictionary] = []
var keep_trace: bool = false
var checked_points: int = 0


func _init(full_trace: bool = false) -> void:
	super(full_trace)
	keep_trace = full_trace


func point(battle: Battle, kind: String, actor: StringName = &"", ability: StringName = &"", target: StringName = &"") -> String:
	_check(battle, kind, actor, ability)
	checked_points += 1
	return super(battle, kind, actor, ability, target) if keep_trace else ""


func _check(battle: Battle, kind: String, actor: StringName, ability: StringName) -> void:
	for unit in battle.units():
		for pair in BOUNDED:
			if not unit.asc.has_attribute(pair[0]) or not unit.asc.has_attribute(pair[1]):
				continue
			var value := unit.stat(pair[0])
			var cap := unit.stat(pair[1])
			if value < 0 or value > cap:
				_violate(battle, kind, actor, ability, unit, "%s_out_of_range" % pair[0], "%s %d not in [0, %d]" % [pair[0], value, cap])
		var hp := unit.stat(BattleUnit.HP)
		if unit.alive and hp <= 0:
			_violate(battle, kind, actor, ability, unit, "alive_at_zero_hp", "alive with hp %d" % hp)
		elif not unit.alive and hp > 0:
			_violate(battle, kind, actor, ability, unit, "dead_with_hp", "dead with hp %d" % hp)
		if not unit.alive and not unit.statuses().is_empty():
			_violate(battle, kind, actor, ability, unit, "dead_with_statuses", ", ".join(unit.statuses().map(
				func(status: Dictionary) -> String: return status["tag"])))
	if kind == "end" and battle.outcome == Battle.TURN_LIMIT_OUTCOME:
		_violate(battle, kind, actor, ability, null, "turn_limit", "the battle hit the turn cap (%d)" % Battle.TURN_LIMIT)


func _violate(battle: Battle, kind: String, actor: StringName, ability: StringName, unit: BattleUnit,
		invariant: String, detail: String) -> void:
	if violations.size() >= MAX_VIOLATIONS:
		return
	violations.append({"invariant": invariant, "point": checked_points, "kind": kind, "turn": battle.turn,
		"actor": String(actor), "ability": String(ability), "unit": String(unit.unit_id) if unit != null else "",
		"detail": detail})
