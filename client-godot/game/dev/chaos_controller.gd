## The chaos policy (spec playable-demo 2.3b): a party controller that plays badly on purpose, for stress tests.
## Dev and tests only. It draws from its own RandomNumberGenerator (RunSeeds stream "dev/chaos/<battle id>"), never
## from the battle's, and records the ActionLog like ActionRecorder does, so its battles replay like any other.
##
## Each decision: with `illegal_x100` (×100 percent) it submits an illegal move first (one of ILLEGAL_CASES that can
## be built now) and expects the battle to refuse it with no state change, no log entry and no RNG draw; then (or
## otherwise) it picks uniformly among every legal (ability, target) pair, good or bad. At each ult window it presses a
## random ready ult half the time. Anything unexpected goes to `violations`.
## Spec playable-demo 3.9 (D21): with a `base` controller (the smart policy), only `chaos_x100` of the decisions go
## chaotic (one draw per decision from the same stream; none at 100%); the others, and every decision while not
## `active` (before the report's --chaos-from floor), are the base's.
class_name ChaosController
extends RefCounted

const ILLEGAL_CASES: Array[String] = ["unaffordable", "ult_as_action", "unknown_ability", "dead_target",
	"invalid_target", "missing_target", "no_target", "stray_target"]
const ILLEGAL_INTERRUPTS: Array[String] = ["ult_not_ready", "dead_caster", "enemy_caster", "not_an_ult"]
const UNKNOWN_ABILITY: StringName = &"Chaos.Ability.Unknown"
## A legal pick the battle refuses this many times in a row ends the battle (Rejected) instead of looping.
const MAX_REFUSALS: int = 3

var entries: Array[Dictionary] = []
## [{"kind", "turn", "unit", "case", "detail"}].
var violations: Array[Dictionary] = []
## Illegal moves submitted and refused, by case.
var refused: Dictionary = {}
var illegal_x100: int = 0
## Share of decisions that go chaotic (×100 percent); 10000 = all of them (no draw).
var chaos_x100: int = 10000
## False: every decision is the base's (the floors before --chaos-from).
var active: bool = true
var base: Object = null

var _rng: RandomNumberGenerator
## The illegal move waiting for on_invalid: {"case", "hash", "rng", "entries"}.
var _probe: Dictionary = {}
var _force_legal: bool = false
var _refusals: int = 0


func _init(policy_rng: RandomNumberGenerator, illegal_percent_x100: int = 0) -> void:
	_rng = policy_rng
	illegal_x100 = illegal_percent_x100


func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
	if _calm():
		return base.choose(battle, unit)
	if _try_illegal(battle):
		# A quarter of the time an illegal ult press at the DECISION window, otherwise an illegal turn action.
		var illegal := _illegal_interrupt(battle) if _rng.randi_range(0, 3) == 0 else {}
		if illegal.is_empty():
			illegal = _illegal_action(battle, unit)
		if not illegal.is_empty():
			return _submit_illegal(battle, illegal)
	_force_legal = false
	if _coin():
		var ult := _legal_ult(battle)
		if not ult.is_empty():
			return ult
	var pairs := _legal_actions(battle, unit)
	if pairs.is_empty():
		_violate(battle, "no_legal_move", unit.unit_id, "", "no ability can activate")
		var abilities := unit.action_abilities()
		return {"ability": abilities[0].ability_tag if not abilities.is_empty() else UNKNOWN_ABILITY, "target": &""}
	return pairs[_rng.randi_range(0, pairs.size() - 1)]


func interrupt(battle: Battle) -> Dictionary:
	if _calm():
		return base.interrupt(battle)
	if _try_illegal(battle):
		var illegal := _illegal_interrupt(battle)
		if not illegal.is_empty():
			return _submit_illegal(battle, illegal)
	_force_legal = false
	return _legal_ult(battle) if _coin() else {}


func on_invalid(battle: Battle, unit: BattleUnit, reason: String, detail: String) -> bool:
	_force_legal = true
	if _probe.is_empty():
		_refusals += 1
		_violate(battle, "legal_refused", unit.unit_id, reason, detail)
		return _refusals < MAX_REFUSALS
	var after := _state(battle)
	for key in ["hash", "rng", "entries"]:
		if after[key] != _probe[key]:
			_violate(battle, "illegal_changed_state", unit.unit_id, _probe["case"], "%s changed (%s)" % [key, detail])
	refused[_probe["case"]] = refused.get(_probe["case"], 0) + 1
	_probe = {}
	return true


func after_party_turn(battle: Battle, unit: BattleUnit, action: Dictionary) -> void:
	_accepted(battle, unit)
	entries.append(ActionRecorder.entry(battle.turn, unit.unit_id, action, battle.extra_action))


func after_interrupt(battle: Battle, unit: BattleUnit, action: Dictionary) -> void:
	_accepted(battle, unit)
	entries.append(ActionRecorder.entry(battle.turn, unit.unit_id, action, false, true))


func _accepted(battle: Battle, unit: BattleUnit) -> void:
	_refusals = 0
	if not _probe.is_empty():
		_violate(battle, "illegal_accepted", unit.unit_id, _probe["case"], "the battle took an illegal move")
		_probe = {}


## This decision is the base's: no chaos yet, or the per-decision draw says calm. Never calm without a base.
func _calm() -> bool:
	if base == null:
		return false
	if not active:
		return true
	if _force_legal or chaos_x100 >= 10000:
		return false
	return _rng.randi_range(0, 9999) >= chaos_x100


# --- Legal moves ----------------------------------------------------------------------------------------------------

## Every (ability, target) the unit can take as its action now, in grant then slot order.
func _legal_actions(battle: Battle, unit: BattleUnit) -> Array[Dictionary]:
	var pairs: Array[Dictionary] = []
	for ability in unit.action_abilities():
		if not unit.asc.can_activate_ability(ability):
			continue
		if not ability.needs_target():
			pairs.append({"ability": ability.ability_tag, "target": &""})
			continue
		for target in battle.target_candidates(unit, ability):
			pairs.append({"ability": ability.ability_tag, "target": target.unit_id})
	return pairs


## A random ready party ult and target, as an interrupt choice; {} when none is ready.
func _legal_ult(battle: Battle) -> Dictionary:
	var choices: Array[Dictionary] = []
	for unit in _party(battle, true):
		for ability in unit.ultimate_abilities():
			if not unit.asc.can_activate_ability(ability):
				continue
			if not ability.needs_target():
				choices.append({"interrupt": true, "unit": unit.unit_id, "ability": ability.ability_tag, "target": &""})
				continue
			for target in battle.target_candidates(unit, ability):
				choices.append({"interrupt": true, "unit": unit.unit_id, "ability": ability.ability_tag,
					"target": target.unit_id})
	return choices[_rng.randi_range(0, choices.size() - 1)] if not choices.is_empty() else {}


# --- Illegal moves --------------------------------------------------------------------------------------------------

func _try_illegal(battle: Battle) -> bool:
	if _force_legal or illegal_x100 <= 0:
		return false
	return _rng.randi_range(0, 9999) < illegal_x100


## One illegal turn action that can be built now (a random case among those possible), with "case" set; {} if none.
func _illegal_action(battle: Battle, unit: BattleUnit) -> Dictionary:
	var built: Array[Dictionary] = []
	var abilities := unit.action_abilities()
	var targeted := abilities.filter(func(ability: BattleAbility) -> bool:
		return ability.needs_target() and unit.asc.can_activate_ability(ability))
	var untargeted := abilities.filter(func(ability: BattleAbility) -> bool:
		return not ability.needs_target() and unit.asc.can_activate_ability(ability))
	for ability in abilities:
		if not unit.asc.can_activate_ability(ability):
			built.append({"case": "unaffordable", "ability": ability.ability_tag, "target": _any_target(battle, unit, ability)})
			break
	for ult in unit.ultimate_abilities():
		built.append({"case": "ult_as_action", "ability": ult.ability_tag, "target": _any_target(battle, unit, ult)})
		break
	built.append({"case": "unknown_ability", "ability": UNKNOWN_ABILITY, "target": &""})
	if not targeted.is_empty():
		var ability: BattleAbility = targeted[_rng.randi_range(0, targeted.size() - 1)]
		var candidates := battle.target_candidates(unit, ability)
		for other in battle.units():
			if not other.alive and not candidates.has(other):
				built.append({"case": "dead_target", "ability": ability.ability_tag, "target": other.unit_id})
				break
		for other in battle.units():
			if other.alive and not candidates.has(other):
				built.append({"case": "invalid_target", "ability": ability.ability_tag, "target": other.unit_id})
				break
		built.append({"case": "missing_target", "ability": ability.ability_tag, "target": &"X9"})
		built.append({"case": "no_target", "ability": ability.ability_tag, "target": &""})
	if not untargeted.is_empty():
		var ability: BattleAbility = untargeted[_rng.randi_range(0, untargeted.size() - 1)]
		built.append({"case": "stray_target", "ability": ability.ability_tag, "target": unit.unit_id})
	return built[_rng.randi_range(0, built.size() - 1)]


## One illegal ult press with a real caster (a null caster is rejected outright by design, like a forged log), or {}.
func _illegal_interrupt(battle: Battle) -> Dictionary:
	var built: Array[Dictionary] = []
	for unit in _party(battle, true):
		for ult in unit.ultimate_abilities():
			if not unit.asc.can_activate_ability(ult):
				built.append({"case": "ult_not_ready", "interrupt": true, "unit": unit.unit_id, "ability": ult.ability_tag,
					"target": _any_target(battle, unit, ult)})
				break
		var actions := unit.action_abilities()
		if not actions.is_empty():
			built.append({"case": "not_an_ult", "interrupt": true, "unit": unit.unit_id, "ability": actions[0].ability_tag,
				"target": _any_target(battle, unit, actions[0])})
	for unit in _party(battle, false):
		if not unit.alive and not unit.ultimate_abilities().is_empty():
			var ult: BattleAbility = unit.ultimate_abilities()[0]
			built.append({"case": "dead_caster", "interrupt": true, "unit": unit.unit_id, "ability": ult.ability_tag,
				"target": &""})
			break
	for unit in battle.units():
		if not unit.is_party() and unit.alive and not unit.ultimate_abilities().is_empty():
			built.append({"case": "enemy_caster", "interrupt": true, "unit": unit.unit_id,
				"ability": unit.ultimate_abilities()[0].ability_tag, "target": &""})
			break
	return built[_rng.randi_range(0, built.size() - 1)] if not built.is_empty() else {}


func _submit_illegal(battle: Battle, illegal: Dictionary) -> Dictionary:
	_probe = _state(battle)
	_probe["case"] = illegal["case"]
	var choice := illegal.duplicate()
	choice.erase("case")
	return choice


## A plausible target for `ability` (its first candidate, else none), so a case tests one thing at a time.
static func _any_target(battle: Battle, unit: BattleUnit, ability: BattleAbility) -> StringName:
	if not ability.needs_target():
		return &""
	var candidates := battle.target_candidates(unit, ability)
	return candidates[0].unit_id if not candidates.is_empty() else &"E1"


func _state(battle: Battle) -> Dictionary:
	return {"hash": StateHasher.compute(battle)["hash"], "rng": battle.rng.state, "entries": entries.size()}


static func _party(battle: Battle, alive_only: bool) -> Array[BattleUnit]:
	var party: Array[BattleUnit] = []
	for unit in battle.units():
		if unit.is_party() and (unit.alive or not alive_only):
			party.append(unit)
	party.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)
	return party


func _coin() -> bool:
	return _rng.randi_range(0, 1) == 1


func _violate(battle: Battle, kind: String, unit_id: StringName, case: String, detail: String) -> void:
	violations.append({"kind": kind, "turn": battle.turn, "unit": String(unit_id), "case": case, "detail": detail})
