## The smart policy (spec playable-demo 3.9, D20): a party controller that plays well, for tests and reports. Dev and
## tests only. Deterministic and RNG-free (the player's choices are inputs, never simulation); records the ActionLog
## like ActionRecorder does.
##
## Each decision, in order: revive a dead ally; heal when an ally is under HEAL_BELOW of its max HP; otherwise the
## (ability, target) with the best score. A move is scored by its estimated damage (ATK × multiplier, or flat): × 2 on
## a weakness, ½ on a resist, never into a drain; × 1.5 when it can break the target, × 1.3 when it can kill it; area
## moves add every target they hit; a status-only move counts when the target lacks the status. Costed moves wait
## while MP is under MP_RESERVE (heals excepted). A ready ult is cast when it hits two or more enemies, hits a boss,
## kills its target, or (support ults) revives or heals a hurt party. Ties keep grant order, then slot order.
class_name SmartController
extends RefCounted

const HEAL_BELOW: int = 45      # % of max HP
const MP_RESERVE: int = 30      # % of max MP
const HEAL_WORDS: Array[String] = ["heal", "regen", "revive", "mend", "sanctuary", "salve", "holy", "potion", "restore"]

var entries: Array[Dictionary] = []
var _fallback: bool = false


func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
	var ult := _ult_worth_casting(battle)
	if not ult.is_empty():
		return ult
	var actions := _activatable(unit)
	if _fallback:
		_fallback = false
		return _first_legal(battle, unit, actions)
	var revive := _support(battle, unit, actions, true)
	if not revive.is_empty():
		return revive
	if _party_hurt(battle):
		var heal := _support(battle, unit, actions, false)
		if not heal.is_empty():
			return heal
	var best := {}
	var best_score := -1
	for ability in actions:
		if not ability.targets_enemies():
			continue
		if ability.cost_effect != null and _mp_percent(unit) < MP_RESERVE:
			continue
		for target in _targets(battle, unit, ability):
			var score := score_of(battle, unit, ability, target)
			if score > best_score:
				best_score = score
				best = {"ability": ability.ability_tag, "target": target.unit_id if ability.needs_target() else &""}
	return best if not best.is_empty() else _first_legal(battle, unit, actions)


func interrupt(battle: Battle) -> Dictionary:
	return _ult_worth_casting(battle)


func on_invalid(_battle: Battle, unit: BattleUnit, reason: String, detail: String) -> bool:
	push_warning("SmartController: %s refused (%s %s); taking the first legal move" % [unit.unit_id, reason, detail])
	_fallback = true
	return true


func after_party_turn(battle: Battle, unit: BattleUnit, action: Dictionary) -> void:
	entries.append(ActionRecorder.entry(battle.turn, unit.unit_id, action, battle.extra_action))


func after_interrupt(battle: Battle, unit: BattleUnit, action: Dictionary) -> void:
	entries.append(ActionRecorder.entry(battle.turn, unit.unit_id, action, false, true))


# --- Scoring ---------------------------------------------------------------------------------------------------------------

## The estimated value of `ability` aimed at `target` (whole numbers; higher is better, 0 = useless).
@warning_ignore("integer_division")
static func score_of(battle: Battle, unit: BattleUnit, ability: BattleAbility, target: BattleUnit) -> int:
	var hit: Array[BattleUnit] = [target]
	if ability.targeting == BattleAbility.Targeting.ALL_ENEMIES:
		hit = _enemies_of(battle, unit)
	var total := 0
	for index in hit.size():
		var other := hit[index]
		var value := _value_on(unit, ability, other)
		if ability.targeting == BattleAbility.Targeting.BLAST_ENEMY and other != target:
			value /= 2
		total += value
	if ability.targeting == BattleAbility.Targeting.BLAST_ENEMY:
		for other in _neighbours(battle, unit, target):
			total += _value_on(unit, ability, other) / 2
	return total


@warning_ignore("integer_division")
static func _value_on(unit: BattleUnit, ability: BattleAbility, target: BattleUnit) -> int:
	var damage := 0
	var breaks := false
	var status_value := 0
	for row in ability.executions:
		if row == null:
			continue
		var base := 0
		if row.damage_mode == ExecutionRow.DamageMode.SCALED:
			base = unit.stat("atk") * row.multiplier_x100 / 10000
		elif row.damage_mode == ExecutionRow.DamageMode.FLAT:
			base = row.flat_damage_x100
		if base > 0:
			var kind := _damage_type(row)
			if kind != "" and target.asc.has_tag_exact(StringName("Drain." + kind)):
				return 0  # never feed a drain
			if kind != "" and target.asc.has_tag_exact(StringName("Weakness." + kind)):
				base *= 2
				breaks = breaks or target.stat(Battle.TOUGHNESS) > 0
			elif kind != "" and target.asc.has_tag_exact(StringName("Resist." + kind)):
				base /= 2
			damage += base
		elif row.effect != null and row.applies_debuff():
			var missing := row.effect.granted_tags.any(func(tag) -> bool:
				return String(tag).begins_with(Battle.DEBUFF_TAG + ".") and not target.asc.has_tag_exact(tag))
			if missing:
				status_value += unit.stat("atk") * 6 / 10
	var value := damage + status_value
	if breaks:
		value = value * 3 / 2
	if damage > 0 and damage >= target.stat(BattleUnit.HP):
		value = value * 13 / 10
	return value


static func _damage_type(row: ExecutionRow) -> String:
	for tag in row.tags:
		if String(tag).begins_with("Damage.Type."):
			return String(tag).trim_prefix("Damage.Type.")
	return ""


# --- Support and ults ------------------------------------------------------------------------------------------------------

static func _is_heal(ability: BattleAbility) -> bool:
	for row in ability.executions:
		if row != null and row.effect != null:
			var path := row.effect.resource_path.get_file().to_lower()
			if HEAL_WORDS.any(func(word: String) -> bool: return path.contains(word)):
				return true
	return false


## A revive (dead: true) or a heal on the most hurt ally; {} when none applies.
func _support(battle: Battle, unit: BattleUnit, actions: Array[BattleAbility], dead: bool) -> Dictionary:
	for ability in actions:
		var revives := ability.targeting in [BattleAbility.Targeting.SINGLE_DEAD_ALLY, BattleAbility.Targeting.ALL_DEAD_ALLIES]
		if revives != dead or (not dead and (ability.targets_enemies() or not _is_heal(ability))):
			continue
		var candidates := battle.target_candidates(unit, ability)
		if candidates.is_empty() and ability.needs_target():
			continue
		if not ability.needs_target():
			return {"ability": ability.ability_tag, "target": &""}
		candidates.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return _hp_percent(a) < _hp_percent(b))
		return {"ability": ability.ability_tag, "target": candidates[0].unit_id}
	return {}


## The first ready party ult worth casting now, as an interrupt choice; {} to hold.
func _ult_worth_casting(battle: Battle) -> Dictionary:
	for unit in _party(battle):
		for ability in unit.ultimate_abilities():
			if not unit.asc.can_activate_ability(ability):
				continue
			var target := _best_ult_target(battle, unit, ability)
			if target.is_empty():
				continue
			return {"interrupt": true, "unit": unit.unit_id, "ability": ability.ability_tag, "target": target["target"]}
	return {}


func _best_ult_target(battle: Battle, unit: BattleUnit, ability: BattleAbility) -> Dictionary:
	var candidates := battle.target_candidates(unit, ability)
	if ability.targets_enemies():
		var enemies := _enemies_of(battle, unit)
		var boss := enemies.any(func(enemy: BattleUnit) -> bool: return enemy.asc.has_tag_exact(&"Enemy.Boss"))
		var best: BattleUnit = null
		var best_score := 0
		for target in (candidates if ability.needs_target() else enemies.slice(0, 1)):
			var score := score_of(battle, unit, ability, target)
			if score > best_score:
				best_score = score
				best = target
		if best == null:
			return {}
		var kills := ability.needs_target() and best_score >= best.stat(BattleUnit.HP)
		var wide := ability.targeting != BattleAbility.Targeting.SINGLE_ENEMY and enemies.size() >= 2
		if not (wide or boss or kills):
			return {}
		return {"target": best.unit_id if ability.needs_target() else &""}
	var revives := ability.targeting in [BattleAbility.Targeting.SINGLE_DEAD_ALLY, BattleAbility.Targeting.ALL_DEAD_ALLIES]
	if revives and candidates.is_empty():
		return {}
	if not revives and not _party_hurt(battle):
		return {}
	if ability.needs_target():
		if candidates.is_empty():
			return {}
		candidates.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return _hp_percent(a) < _hp_percent(b))
		return {"target": candidates[0].unit_id}
	return {"target": &""}


# --- Helpers ---------------------------------------------------------------------------------------------------------------

static func _activatable(unit: BattleUnit) -> Array[BattleAbility]:
	var result: Array[BattleAbility] = []
	for ability in unit.action_abilities():
		if unit.asc.can_activate_ability(ability):
			result.append(ability)
	return result


static func _targets(battle: Battle, unit: BattleUnit, ability: BattleAbility) -> Array[BattleUnit]:
	if ability.needs_target():
		return battle.target_candidates(unit, ability)
	var enemies := _enemies_of(battle, unit)
	var first: Array[BattleUnit] = []
	if not enemies.is_empty():
		first.append(enemies[0])  # an untargeted area move is scored once, from its first target
	return first


static func _first_legal(battle: Battle, unit: BattleUnit, actions: Array[BattleAbility]) -> Dictionary:
	for ability in actions:
		if not ability.needs_target():
			return {"ability": ability.ability_tag, "target": &""}
		var candidates := battle.target_candidates(unit, ability)
		if not candidates.is_empty():
			return {"ability": ability.ability_tag, "target": candidates[0].unit_id}
	return {"ability": &"", "target": &""}


static func _enemies_of(battle: Battle, unit: BattleUnit) -> Array[BattleUnit]:
	var result: Array[BattleUnit] = []
	for other in battle.units():
		if other.alive and other.is_party() != unit.is_party():
			result.append(other)
	result.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)
	return result


static func _neighbours(battle: Battle, unit: BattleUnit, target: BattleUnit) -> Array[BattleUnit]:
	var result: Array[BattleUnit] = []
	for other in _enemies_of(battle, unit):
		if absi(other.slot - target.slot) == 1:
			result.append(other)
	return result


static func _party(battle: Battle) -> Array[BattleUnit]:
	var result: Array[BattleUnit] = []
	for unit in battle.units():
		if unit.is_party() and unit.alive:
			result.append(unit)
	result.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)
	return result


static func _party_hurt(battle: Battle) -> bool:
	return _party(battle).any(func(unit: BattleUnit) -> bool: return _hp_percent(unit) < HEAL_BELOW)


@warning_ignore("integer_division")
static func _hp_percent(unit: BattleUnit) -> int:
	var most := unit.stat(BattleUnit.MAX_HP)
	return unit.stat(BattleUnit.HP) * 100 / most if most > 0 else 0


@warning_ignore("integer_division")
static func _mp_percent(unit: BattleUnit) -> int:
	if not unit.asc.has_attribute(BattleUnit.MAX_MP):
		return 100
	var most := unit.stat(BattleUnit.MAX_MP)
	return unit.stat(BattleUnit.MP) * 100 / most if most > 0 else 100
