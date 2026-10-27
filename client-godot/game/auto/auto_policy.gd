## Auto play (spec auto-battle): the smart policy as a player feature. The battle panel's Auto and the dev reports'
## smart policy both use it, through ActionRecorder.autopilot, so the reports measure what players get.
## Deterministic and RNG-free (the player's choices are inputs, never simulation); it never records anything itself.
##
## Each decision, in order: a ready ult worth casting (Options.ults); revive a dead ally (Ability.Role.Revive); heal the
## most hurt ally when one is under HEAL_BELOW of its max HP (Ability.Role.Heal); cleanse an ally that is controlled or
## carries CLEANSE_AT or more debuffs (Ability.Role.Cleanse); otherwise the (ability, target) with the best score: its
## estimated damage (ATK × multiplier, or flat) × 2 on a weakness, ½ on a resist, never into a drain; × 1.5 when it
## can break the target, × 1.3 when it can kill it; area moves add every target they hit; a status-only move counts
## when the target lacks the status. Then a buff (Ability.Role.Buff) whose status an ally lacks; then the first legal
## move. Costed moves wait while MP is under MP_RESERVE (heals and cleanses excepted). A ready ult is cast when it
## hits two or more enemies, hits a boss, kills its target, or (support ults) revives or heals a hurt party.
## Items whose use mode is CONSUMABLE are never used unless Options.consumables (spec auto-battle A4). Ties keep grant
## order, then slot order.
## Spec skill-points 3.4, for a unit with an Ability.Type.Basic ability (others keep MP_RESERVE): basics build SP and a
## costed move is picked over the best basic only when it scores SPEND_RATIO% of it (a free one: more than it), or when
## one more basic would overflow max SP (then a buff an ally lacks also goes before the basic); and while the party is in danger (an ally dead or under HEAL_BELOW, or under
## DANGER_BELOW in a boss fight) a unit with a costed heal or revive never spends below that move's cost.
class_name AutoPolicy
extends RefCounted

const HEAL_BELOW: int = 45      # % of max HP
const MP_RESERVE: int = 30      # % of max MP
const CLEANSE_AT: int = 2       # debuffs on one ally
const SPEND_RATIO: int = 150    # % of the best basic's score a costed move must reach (spec skill-points 3.4)
const DANGER_BELOW: int = 60    # % of max HP: in a boss fight, an ally under it puts the party in danger
const BASIC_TAG: StringName = &"Ability.Type.Basic"
const BOSS_TAG: StringName = &"Enemy.Boss"
const ROLE_PREFIX: String = "Ability.Role."
const ROLE_DAMAGE: StringName = &"Ability.Role.Damage"
const ROLE_DEBUFF: StringName = &"Ability.Role.Debuff"
const ROLE_DISPEL: StringName = &"Ability.Role.Dispel"
const ROLE_HEAL: StringName = &"Ability.Role.Heal"
const ROLE_REVIVE: StringName = &"Ability.Role.Revive"
const ROLE_BUFF: StringName = &"Ability.Role.Buff"
const ROLE_CLEANSE: StringName = &"Ability.Role.Cleanse"
## Restores MP (Ether, Honey Cake). Auto never picks it on its own.
const ROLE_RESTORE_MP: StringName = &"Ability.Role.RestoreMP"
## Spec ff7-ui F3: Block (guard until the next turn). Auto never picks it; it is the player's call.
const ROLE_GUARD: StringName = &"Ability.Role.Guard"
## Every role an ability may carry (the validator rejects others).
const ROLES: Array[StringName] = [ROLE_DAMAGE, ROLE_DEBUFF, ROLE_DISPEL, ROLE_HEAL, ROLE_REVIVE, ROLE_BUFF, ROLE_CLEANSE,
	ROLE_RESTORE_MP, ROLE_GUARD]
const BUFF_TAG: String = "Status.Buff"


class Options:
	## Cast ults worth casting (spec auto-battle A2; Settings "auto_ults").
	var ults: bool = true
	## Use CONSUMABLE items too (A4: off for players).
	var consumables: bool = false

	func _to_string() -> String:
		return "ults=%s consumables=%s" % [ults, consumables]


var options: Options
## Items by id, to tell CONSUMABLE items apart (null: every item counts as reusable).
var content: ContentIndex
## Why the last choose() picked its move ("ult", "revive", "heal", "cleanse", "ability", "cap", "basic", "best", "buff",
## "last resort", "fallback"), for BattleLog. Never read by a rule.
var last_reason: String = ""
var _fallback: bool = false


func _init(policy_options: Options = null, content_index: ContentIndex = null) -> void:
	options = policy_options if policy_options != null else Options.new()
	content = content_index


func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
	var ult := interrupt(battle)
	if not ult.is_empty():
		last_reason = "ult"
		return ult
	var actions := _activatable(unit)
	if _fallback:
		_fallback = false
		last_reason = "fallback"
		return _first_legal(battle, unit, actions)
	var revive := _support(battle, unit, actions, ROLE_REVIVE)
	if not revive.is_empty():
		last_reason = "revive"
		return revive
	if _party_hurt(battle):
		var heal := _support(battle, unit, actions, ROLE_HEAL)
		if not heal.is_empty():
			last_reason = "heal"
			return heal
	var cleanse := _cleanse(battle, unit, actions)
	if not cleanse.is_empty():
		last_reason = "cleanse"
		return cleanse
	var rhythm := has_basic(unit)
	var reserve := danger_reserve(battle, unit) if rhythm else 0
	var best := {}
	var best_score := -1
	var best_cost := 0
	var basic := {}
	var basic_score := -1
	for ability in actions:
		if not ability.targets_enemies():
			continue
		var is_basic := ability.asset_tags.has(BASIC_TAG)
		if rhythm and not is_basic and not affordable_above(unit, ability, reserve):
			continue
		if not rhythm and _saving_mp(unit, ability):
			continue
		for target in _targets(battle, unit, ability):
			var score := score_of(battle, unit, ability, target)
			var choice := {"ability": ability.ability_tag, "target": target.unit_id if ability.needs_target() else &""}
			if rhythm and is_basic:
				if score > basic_score:
					basic_score = score
					basic = choice
			elif score > best_score:
				best_score = score
				best = choice
				best_cost = CostReader.sp_cost(ability, unit.asc)
	if rhythm:
		# Spec skill-points 3.4: spend when it is worth it (or SP would be wasted), else build SP with the basic.
		@warning_ignore("integer_division")
		var needed := basic_score * (SPEND_RATIO if best_cost > 0 else 100) / 100
		var worth := best_score >= needed if best_cost > 0 else best_score > needed
		if best_score > 0 and (basic.is_empty() or worth or basic_would_overflow(unit)):
			last_reason = "ability" if worth or basic.is_empty() else "cap"
			return best
		# No waste at the cap: a buff an ally lacks (within the danger reserve) before a basic that would overflow.
		if basic_would_overflow(unit):
			var payable: Array[BattleAbility] = []
			for ability in actions:
				if affordable_above(unit, ability, reserve):
					payable.append(ability)
			var buff := _buff(battle, unit, payable)
			if not buff.is_empty():
				last_reason = "cap buff"
				return buff
		if basic_score > 0:
			last_reason = "basic"
			return basic
	if best_score > 0:
		last_reason = "best"
		return best
	var buff := _buff(battle, unit, actions)
	if not buff.is_empty():
		last_reason = "buff"
		return buff
	last_reason = "best (no score)" if not best.is_empty() else "last resort"
	return best if not best.is_empty() else _last_resort(battle, unit, actions)


## Spec skill-points (the turn-limit traces): nothing scores, so never feed a drain: the first legal move that isn't an
## enemy move every one of whose targets drains it; else Block (Ability.Role.Guard); else the first legal move.
func _last_resort(battle: Battle, unit: BattleUnit, actions: Array[BattleAbility]) -> Dictionary:
	var safe: Array[BattleAbility] = []
	for ability in actions:
		if not ability.targets_enemies() or not _targets(battle, unit, ability).all(
				func(target: BattleUnit) -> bool: return feeds_drain(ability, target)):
			safe.append(ability)
	var pick := _first_legal(battle, unit, safe)
	if not pick.is_empty():
		return pick  # a safe move with a target (a "safe" revive with nobody down has none: keep looking)
	for ability in unit.action_abilities():
		if has_role(ability, ROLE_GUARD) and unit.asc.can_activate_ability(ability):
			return {"ability": ability.ability_tag, "target": &""}
	return _first_legal(battle, unit, actions)


## True when one of the ability's damage rows is drained by `target` (the hit would heal it).
static func feeds_drain(ability: BattleAbility, target: BattleUnit) -> bool:
	for row in ability.executions:
		if row == null or row.damage_mode == ExecutionRow.DamageMode.USE_EFFECT:
			continue
		var kind := damage_type(row)
		if kind != "" and target.asc.has_tag_exact(StringName("Drain." + kind)):
			return true
	return false


## An ult worth casting now, as an interrupt choice (the BETWEEN window, and first at a decision); {} to hold.
func interrupt(battle: Battle) -> Dictionary:
	return _ult_worth_casting(battle) if options.ults else {}


## The battle refused a pick (it shouldn't: picks come from can_activate_ability and target_candidates): the next one
## is the first legal move.
func on_invalid(_battle: Battle, unit: BattleUnit, reason: String, detail: String) -> bool:
	push_warning("AutoPolicy: %s refused (%s %s); taking the first legal move" % [unit.unit_id, reason, detail])
	_fallback = true
	return true


static func has_role(ability: BattleAbility, role: StringName) -> bool:
	return ability.asset_tags.has(role)


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
			var kind := damage_type(row)
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


static func damage_type(row: ExecutionRow) -> String:
	for tag in row.tags:
		if String(tag).begins_with("Damage.Type."):
			return String(tag).trim_prefix("Damage.Type.")
	return ""


# --- Support and ults ------------------------------------------------------------------------------------------------------

## A revive (ROLE_REVIVE) or a heal (ROLE_HEAL) on the most hurt ally; {} when none applies.
func _support(battle: Battle, unit: BattleUnit, actions: Array[BattleAbility], role: StringName) -> Dictionary:
	for ability in actions:
		if not has_role(ability, role) or ability.targets_enemies():
			continue
		var candidates := battle.target_candidates(unit, ability)
		if candidates.is_empty() and (ability.needs_target() or role == ROLE_REVIVE):
			continue
		if not ability.needs_target():
			return {"ability": ability.ability_tag, "target": &""}
		candidates.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return _hp_percent(a) < _hp_percent(b))
		return {"ability": ability.ability_tag, "target": candidates[0].unit_id}
	return {}


## A cleanse on the first ally (by slot) that is controlled or carries CLEANSE_AT or more debuffs; {} when none.
func _cleanse(battle: Battle, unit: BattleUnit, actions: Array[BattleAbility]) -> Dictionary:
	for ability in actions:
		if not has_role(ability, ROLE_CLEANSE) or ability.targets_enemies():
			continue
		var candidates := battle.target_candidates(unit, ability) if ability.needs_target() else _reached(battle, unit, ability)
		candidates.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)
		for ally in candidates:
			if _afflicted(ally):
				return {"ability": ability.ability_tag, "target": ally.unit_id if ability.needs_target() else &""}
	return {}


## A buff whose Status.Buff.* tag an ally it reaches lacks (the first such ally by slot); {} when none.
func _buff(battle: Battle, unit: BattleUnit, actions: Array[BattleAbility]) -> Dictionary:
	for ability in actions:
		if not has_role(ability, ROLE_BUFF) or ability.targets_enemies() or _saving_mp(unit, ability):
			continue
		var tags := _buff_tags(ability)
		if tags.is_empty():
			continue
		var candidates := battle.target_candidates(unit, ability) if ability.needs_target() else _reached(battle, unit, ability)
		candidates.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)
		for ally in candidates:
			if tags.any(func(tag: StringName) -> bool: return not ally.asc.has_tag_exact(tag)):
				return {"ability": ability.ability_tag, "target": ally.unit_id if ability.needs_target() else &""}
	return {}


static func _buff_tags(ability: BattleAbility) -> Array[StringName]:
	var tags: Array[StringName] = []
	for row in ability.executions:
		if row == null or row.effect == null:
			continue
		for tag in row.effect.granted_tags:
			if String(tag).begins_with(BUFF_TAG + ".") and not tags.has(tag):
				tags.append(tag)
	return tags


static func _afflicted(ally: BattleUnit) -> bool:
	if ally.asc.has_tag_exact(Battle.CONTROLLED_TAG):
		return true
	var debuffs := 0
	for status in ally.statuses():
		if String(status["tag"]).begins_with(Battle.DEBUFF_TAG + "."):
			debuffs += 1
	return debuffs >= CLEANSE_AT


## The living allies an untargeted support move reaches (SELF: the unit; ALL_ALLIES: the party).
static func _reached(battle: Battle, unit: BattleUnit, ability: BattleAbility) -> Array[BattleUnit]:
	if ability.targeting == BattleAbility.Targeting.SELF:
		var own: Array[BattleUnit] = [unit]
		return own
	return _party(battle)


## The first ready party ult worth casting now, as an interrupt choice; {} to hold.
func _ult_worth_casting(battle: Battle) -> Dictionary:
	for unit in _party(battle):
		for ability in unit.ultimate_abilities():
			if not unit.asc.can_activate_ability(ability) or not _allowed(unit, ability):
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
	var revives := has_role(ability, ROLE_REVIVE)
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

## The unit's action abilities that can activate now and that the options allow.
func _activatable(unit: BattleUnit) -> Array[BattleAbility]:
	var result: Array[BattleAbility] = []
	for ability in unit.action_abilities():
		if unit.asc.can_activate_ability(ability) and _allowed(unit, ability) and not ability.asset_tags.has(ROLE_GUARD):
			result.append(ability)
	return result


## False for a CONSUMABLE item's ability unless Options.consumables (spec auto-battle A4).
func _allowed(unit: BattleUnit, ability: BattleAbility) -> bool:
	if options.consumables or content == null or not unit.item_abilities.has(ability.ability_tag):
		return true
	var item: ItemDefinition = content.items.get(unit.item_abilities[ability.ability_tag])
	return item == null or item.use_mode != ItemDefinition.UseMode.CONSUMABLE


## Spec skill-points 3.4: the rhythm rules apply to a unit that has a basic attack.
static func has_basic(unit: BattleUnit) -> bool:
	return unit.action_abilities().any(func(ability: BattleAbility) -> bool: return ability.asset_tags.has(BASIC_TAG))


## The SP (×100) a unit keeps back now: while the party is in danger, the cost of its cheapest costed heal or revive;
## otherwise 0.
static func danger_reserve(battle: Battle, unit: BattleUnit) -> int:
	if not party_in_danger(battle):
		return 0
	var cheapest := 0
	for ability in unit.action_abilities():
		if not (has_role(ability, ROLE_HEAL) or has_role(ability, ROLE_REVIVE)):
			continue
		var cost := CostReader.sp_cost(ability, unit.asc)
		if cost > 0 and (cheapest == 0 or cost < cheapest):
			cheapest = cost
	return cheapest


## An ally dead or under HEAL_BELOW, or (a boss alive) under DANGER_BELOW.
static func party_in_danger(battle: Battle) -> bool:
	var boss := false
	for other in battle.units():
		if other.alive and not other.is_party() and other.asc.has_tag(BOSS_TAG):
			boss = true
	for member in battle.units():
		if not member.is_party():
			continue
		if not member.alive:
			return true
		var percent := _hp_percent(member)
		if percent < HEAL_BELOW or (boss and percent < DANGER_BELOW):
			return true
	return false


## True when the unit can pay for `ability` and keep at least `reserve` SP (×100) afterwards.
static func affordable_above(unit: BattleUnit, ability: BattleAbility, reserve: int) -> bool:
	var cost := CostReader.sp_cost(ability, unit.asc)
	if cost == 0:
		return true
	return unit.stat(BattleUnit.MP) - cost >= reserve


## The SP (×100) one basic attack gives this unit: sp_basic × sp_gain, whole (0 without those attributes).
@warning_ignore("integer_division")
static func basic_gain(unit: BattleUnit) -> int:
	if not unit.asc.has_attribute("sp_basic"):
		return 0
	var bonus := unit.stat("sp_gain") if unit.asc.has_attribute("sp_gain") else Fixed.ONE_HUNDRED_PERCENT
	return Fixed.pct(unit.stat("sp_basic"), maxi(bonus, 0)) / 100 * 100


## True when one more basic attack would push SP past max SP (some of its gain would be lost).
static func basic_would_overflow(unit: BattleUnit) -> bool:
	var gain := basic_gain(unit)
	return gain > 0 and unit.asc.has_attribute(BattleUnit.MAX_MP) \
		and unit.stat(BattleUnit.MP) + gain > unit.stat(BattleUnit.MAX_MP)


static func _saving_mp(unit: BattleUnit, ability: BattleAbility) -> bool:
	return ability.cost_effect != null and _mp_percent(unit) < MP_RESERVE


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
	return {}


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
