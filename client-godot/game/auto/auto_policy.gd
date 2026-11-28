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
## Spec auto-support: the heal step also runs when SPREAD_HURT or more allies are under SPREAD_BELOW, and picks the heal
## with the most effective healing (RestoreReader, overhealing counts for nothing) unless a cheaper one comes within
## HEAL_STEP% (a heal that also cleanses an afflicted ally it reaches only needs to match it); a unit with a basic casts
## a party buff (ALL_ALLIES) that BUFF_LACKING or more allies lack before the spend-or-build comparison, when it can pay
## above the danger reserve, the party is not in danger and some enemy is still at BUFF_SKIP_BELOW% HP or more.
class_name AutoPolicy
extends RefCounted

const HEAL_STEP: int = 125      # % of a cheaper heal's effective healing a costlier one must reach (spec auto-support 3.2)
const SPREAD_BELOW: int = 70    # % of max HP: an ally under it counts as hurt for the spread rule
const SPREAD_HURT: int = 2      # allies under SPREAD_BELOW that make the party spread hurt
const BUFF_LACKING: int = 2     # living allies that must lack a party buff's status (spec auto-support 3.3)
const BUFF_SKIP_BELOW: int = 25 # % of max HP: no party buff when every enemy is under it
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
	## Spec second-pack 2.7: an HP-cost move is refused while it would leave the caster under this share of its max HP (×100),
	## unless its lifesteal on the expected damage would bring it back above.
	var danger_hp_x100: int = 2500

	func _to_string() -> String:
		return "ults=%s consumables=%s danger_hp=%d" % [ults, consumables, danger_hp_x100]


var options: Options
## Items by id, to tell CONSUMABLE items apart (null: every item counts as reusable).
var content: ContentIndex
## Why the last choose() picked its move ("ult", "revive", "heal", "cleanse", "ability", "cap", "basic", "best", "buff",
## "last resort", "fallback", "party buff", "cap buff"), for BattleLog. Never read by a rule.
var last_reason: String = ""
## Spec auto-support 5: more about the last pick for BattleLog ("E=<n>" for a heal: its effective healing, whole HP).
var last_detail: String = ""
## The last heal pick's effective healing (×100; 0 for any other pick). Never read by a rule.
var last_healing: int = 0
## Spec auto-support 3.4 (dev reports only): when set, every pick is counted here per class, {class id: {"reasons":
## {reason: n}, "abilities": {reason: {ability tag: n}}, "healingX100": Σ effective healing of the heal picks}} (abilities
## only for the support reasons). Never read by a rule.
var tally: Variant = null
## The last pick counted in the tally: [class row, reason, ability key, healing ×100] ([] = none), for _uncount.
var _counted: Array = []
var _fallback: bool = false

## The reasons whose picked abilities the tally lists (spec auto-support 3.4).
const TALLIED_ABILITIES: Array[String] = ["heal", "party buff", "cap buff", "buff"]


func _init(policy_options: Options = null, content_index: ContentIndex = null) -> void:
	options = policy_options if policy_options != null else Options.new()
	content = content_index


func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
	last_detail = ""
	last_healing = 0
	var pick := _choose(battle, unit)
	if last_reason != "ult":  # an ult was counted by interrupt()
		_count(battle, unit, pick, last_reason)
	return pick


## Spec auto-support 3.4: counts one pick in the tally (when set) under the class of the unit that casts it (an ult
## interrupt's own unit), and remembers it so a refused pick (on_invalid) is taken back out.
func _count(battle: Battle, unit: BattleUnit, pick: Dictionary, reason: String) -> void:
	_counted = []
	var picker: BattleUnit = battle.unit_by_id(pick["unit"]) if pick.has("unit") else unit
	if not tally is Dictionary or pick.is_empty() or picker == null or picker.definition == null:
		return
	var by_class: Dictionary = tally.get_or_add(String(picker.definition.id), {"reasons": {}, "abilities": {}})
	by_class["reasons"][reason] = int(by_class["reasons"].get(reason, 0)) + 1
	var key := String(pick.get("ability", ""))
	if reason in TALLIED_ABILITIES:
		var abilities: Dictionary = by_class["abilities"].get_or_add(reason, {})
		abilities[key] = int(abilities.get(key, 0)) + 1
	var healing := last_healing if reason == "heal" else 0
	if healing > 0:
		by_class["healingX100"] = int(by_class.get("healingX100", 0)) + healing
	_counted = [by_class, reason, key, healing]


## Takes the last counted pick back out of the tally (the battle refused it; its fallback is counted instead).
func _uncount() -> void:
	if _counted.is_empty():
		return
	var by_class: Dictionary = _counted[0]
	var reason: String = _counted[1]
	by_class["reasons"][reason] = int(by_class["reasons"][reason]) - 1
	if int(by_class["reasons"][reason]) <= 0:
		by_class["reasons"].erase(reason)
	if reason in TALLIED_ABILITIES:
		var abilities: Dictionary = by_class["abilities"][reason]
		abilities[_counted[2]] = int(abilities[_counted[2]]) - 1
		if int(abilities[_counted[2]]) <= 0:
			abilities.erase(_counted[2])
		if abilities.is_empty():
			by_class["abilities"].erase(reason)
	if int(_counted[3]) > 0:
		by_class["healingX100"] = int(by_class["healingX100"]) - int(_counted[3])
	_counted = []


func _choose(battle: Battle, unit: BattleUnit) -> Dictionary:
	var ult := interrupt(battle)
	if not ult.is_empty():
		last_reason = "ult"
		return ult
	var actions := _activatable(unit, battle)
	if actions.is_empty():
		actions = _activatable(unit)  # review fix: every move costs HP it cannot spare: still a move (Auto always returns one)
	if _fallback:
		_fallback = false
		last_reason = "fallback"
		return _first_legal(battle, unit, actions)
	var revive := _support(battle, unit, actions, ROLE_REVIVE)
	if not revive.is_empty():
		last_reason = "revive"
		return revive
	if _party_hurt(battle) or _spread_hurt(battle):
		var heal := _heal(battle, unit, actions)
		if not heal.is_empty():
			last_reason = "heal"
			return heal
	var cleanse := _cleanse(battle, unit, actions)
	if not cleanse.is_empty():
		last_reason = "cleanse"
		return cleanse
	var rhythm := has_basic(unit)
	var reserve := danger_reserve(battle, unit) if rhythm else 0
	if rhythm:
		var party_buff := _party_buff(battle, unit, actions, reserve)
		if not party_buff.is_empty():
			last_reason = "party buff"
			return party_buff
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
	var ult := _ult_worth_casting(battle) if options.ults else {}
	if not ult.is_empty():
		_count(battle, null, ult, "ult")  # both windows: BETWEEN (the recorder asks here) and DECISION (choose)
	return ult


## The battle refused a pick (it shouldn't: picks come from can_activate_ability and target_candidates): the next one
## is the first legal move.
func on_invalid(_battle: Battle, unit: BattleUnit, reason: String, detail: String) -> bool:
	push_warning("AutoPolicy: %s refused (%s %s); taking the first legal move" % [unit.unit_id, reason, detail])
	_uncount()
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
	var neighbours: Array[BattleUnit] = []
	if ability.targeting == BattleAbility.Targeting.BLAST_ENEMY:
		neighbours = _neighbours(battle, unit, target)
	var pool := maxi(hit.size() + neighbours.size(), 1)  # spec second-pack: a RANDOM row lands on one of these
	var total := 0
	for index in hit.size():
		var other := hit[index]
		var value := _value_on(unit, ability, other, pool)
		if ability.targeting == BattleAbility.Targeting.BLAST_ENEMY and other != target:
			value /= 2
		total += value
	for other in neighbours:
		total += _value_on(unit, ability, other, pool) / 2
	return total


@warning_ignore("integer_division")
## `pool`: how many units the score is summed over; a RANDOM row (spec second-pack: one draw among them) counts 1/pool on each.
static func _value_on(unit: BattleUnit, ability: BattleAbility, target: BattleUnit, pool: int = 1) -> int:
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
		if row.targets == ExecutionRow.Targets.RANDOM:
			base /= maxi(pool, 1)
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

## A revive (ROLE_REVIVE) on the most hurt candidate; {} when none applies (heals: _heal, spec auto-support).
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
		candidates.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)  # sort-ok: slot is an int
		for ally in candidates:
			if _afflicted(ally):
				return {"ability": ability.ability_tag, "target": ally.unit_id if ability.needs_target() else &""}
	return {}


## A buff whose Status.Buff.* tag an ally it reaches lacks, aimed at the first such ally by slot; {} when none. Spec
## auto-support 3.3 step 4: the buff most allies lack first, then the higher SP cost, then grant order.
func _buff(battle: Battle, unit: BattleUnit, actions: Array[BattleAbility]) -> Dictionary:
	var best := {}
	var best_lacking := 0
	var best_cost := 0
	for ability in actions:
		if not has_role(ability, ROLE_BUFF) or ability.targets_enemies() or _saving_mp(unit, ability):
			continue
		if has_role(ability, ROLE_HEAL):
			continue  # a heal that also buffs (Benediction, Ballad, a HoT) is the heal step's: never cast on a full-HP party
		var tags := _buff_tags(ability)
		if tags.is_empty():
			continue
		var candidates := battle.target_candidates(unit, ability) if ability.needs_target() else _reached(battle, unit, ability)
		candidates.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)  # sort-ok: slot is an int
		var lacking := 0
		var first: BattleUnit = null
		for ally in candidates:
			if _lacks_any(ally, tags):
				lacking += 1
				if first == null:
					first = ally
		if first == null:
			continue
		if ability.needs_target():
			lacking = 1  # a targeted buff reaches one ally
		var cost := CostReader.sp_cost(ability, unit.asc)
		if best.is_empty() or lacking > best_lacking or (lacking == best_lacking and cost > best_cost):
			best = {"ability": ability.ability_tag, "target": first.unit_id if ability.needs_target() else &""}
			best_lacking = lacking
			best_cost = cost
	return best


## Spec auto-support 3.3: a party buff (Ability.Role.Buff on ALL_ALLIES) that BUFF_LACKING or more living allies lack,
## payable above `reserve`; none while the party is in danger or when every enemy is under BUFF_SKIP_BELOW% HP. A move
## that also heals (Benediction) is a heal, not a party buff: the heal step decides it. Most allies lacking first, then
## the higher SP cost, then grant order; {} when none.
func _party_buff(battle: Battle, unit: BattleUnit, actions: Array[BattleAbility], reserve: int) -> Dictionary:
	if party_in_danger(battle) or _nearly_won(battle, unit):
		return {}
	var party := _party(battle)
	var best := {}
	var best_lacking := 0
	var best_cost := 0
	for ability in actions:
		if not has_role(ability, ROLE_BUFF) or has_role(ability, ROLE_HEAL) \
				or ability.targeting != BattleAbility.Targeting.ALL_ALLIES or ability.is_ultimate():
			continue
		if not affordable_above(unit, ability, reserve):
			continue
		var tags := _buff_tags(ability, true)
		if tags.is_empty():
			continue
		var lacking := 0
		for ally in party:
			if _lacks_any(ally, tags):
				lacking += 1
		if lacking < BUFF_LACKING:
			continue
		var cost := CostReader.sp_cost(ability, unit.asc)
		if best.is_empty() or lacking > best_lacking or (lacking == best_lacking and cost > best_cost):
			best = {"ability": ability.ability_tag, "target": &""}
			best_lacking = lacking
			best_cost = cost
	return best


static func _lacks_any(ally: BattleUnit, tags: Array[StringName]) -> bool:
	return tags.any(func(tag: StringName) -> bool: return not ally.asc.has_tag_exact(tag))


## Every living enemy under BUFF_SKIP_BELOW% of its max HP (the fight is nearly won).
static func _nearly_won(battle: Battle, unit: BattleUnit) -> bool:
	var enemies := _enemies_of(battle, unit)
	return not enemies.is_empty() and enemies.all(func(enemy: BattleUnit) -> bool:
		return _hp_percent(enemy) < BUFF_SKIP_BELOW)


## Spec auto-support 3.2: the heal with the most effective healing (Σ min(restored HP, HP missing) over the living allies
## it reaches); a costlier heal must reach HEAL_STEP% of every cheaper one's (the most of them), or (D6) only match it when it also
## cleanses an afflicted ally it reaches. Ties: the lower SP cost, the most hurt target, grant order, slot. Sets
## last_detail to "E=<whole HP>"; {} when no heal restores anything.
@warning_ignore("integer_division")
func _heal(battle: Battle, unit: BattleUnit, actions: Array[BattleAbility]) -> Dictionary:
	var candidates: Array[Dictionary] = []
	for order in actions.size():
		var ability := actions[order]
		if not has_role(ability, ROLE_HEAL) or ability.targets_enemies() or ability.targets_dead():
			continue
		var cost := heal_cost(ability, unit)
		var cleanses := has_role(ability, ROLE_CLEANSE)
		if ability.needs_target():
			for target in battle.target_candidates(unit, ability):
				if target.alive:
					var single: Array[BattleUnit] = [target]
					_add_heal(candidates, unit, ability, order, cost, cleanses, single, target, true)
		else:
			var reached: Array[BattleUnit] = []
			for ally in _reached(battle, unit, ability):
				if ally.is_up():  # as Battle applies rows: a unit at 0 HP whose death isn't settled gets nothing
					reached.append(ally)
			if not reached.is_empty():
				_add_heal(candidates, unit, ability, order, cost, cleanses, reached, null,
					ability.targeting == BattleAbility.Targeting.SELF)
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:  # ints only: SP cost, grant order, slot
		if a["cost"] != b["cost"]:
			return a["cost"] < b["cost"]
		if a["order"] != b["order"]:
			return a["order"] < b["order"]
		return a["slot"] < b["slot"])
	var best: Dictionary = candidates[0]
	var cheaper := 0  # the most healing among the candidates cheaper than the one being compared
	var level_cost: int = candidates[0]["cost"]
	var level_most: int = candidates[0]["healing"]
	for index in range(1, candidates.size()):
		var other: Dictionary = candidates[index]
		if other["cost"] != level_cost:
			cheaper = maxi(cheaper, level_most)
			level_cost = other["cost"]
			level_most = 0
		level_most = maxi(level_most, other["healing"])
		# Spec auto-support 3.2: a heal costlier than others must reach HEAL_STEP% of every cheaper heal (their best), or
		# (D6) only match it when it also cleanses; one that doesn't may not win, even against a pick at its own cost.
		var qualifies: bool = other["healing"] * 100 >= cheaper * HEAL_STEP \
			or (other["cleanses"] and other["afflicted"] and other["healing"] >= cheaper)
		var wins := false
		if not qualifies:
			wins = false
		elif other["cost"] > best["cost"]:
			wins = true
		elif other["healing"] != best["healing"]:
			wins = other["healing"] > best["healing"]
		else:
			wins = other["hurt"] < best["hurt"]  # same cost and healing: the most hurt target (then grant order, slot)
		if wins:
			best = other
	last_healing = int(best["healing"])
	last_detail = "E=%d" % (last_healing / 100)
	return {"ability": best["ability"], "target": best["target"]}


## Spec second-pack 2.7: what a heal costs its caster for the heal choice, on one scale: its SP cost as a share of max SP plus its
## HP cost as a share of max HP (×100 percent each; review fix: raw SP and HP are different units), so a heal paid in HP (the
## Bloodbinder's Transfusion) is weighed by what it takes, like an SP heal, and a costlier one must still reach HEAL_STEP.
@warning_ignore("integer_division")
static func heal_cost(ability: BattleAbility, unit: BattleUnit) -> int:
	var costs := CostReader.cost_of(ability, unit.asc)
	var share := 0
	for pair in [[BattleUnit.MP, "max_mp"], [BattleUnit.HP, BattleUnit.MAX_HP]]:
		var cost := int(costs.get(pair[0], 0))
		var most := unit.stat(pair[1]) if unit.asc.has_attribute(pair[1]) else 0
		if cost > 0:
			share += cost * Fixed.ONE_HUNDRED_PERCENT / most if most > 0 else cost
	return share


## One heal candidate: `reached` the living allies it heals (the first is its primary, or its first target), `target` its
## target (null when untargeted), `has_primary` as RestoreReader.restore_of. Dropped when it heals nothing.
static func _add_heal(candidates: Array[Dictionary], unit: BattleUnit, ability: BattleAbility, order: int, cost: int,
		cleanses: bool, reached: Array[BattleUnit], target: BattleUnit, has_primary: bool) -> void:
	var healing := 0
	var hurt := 100
	var afflicted := false
	for index in reached.size():
		var ally := reached[index]
		var missing := maxi(ally.stat(BattleUnit.MAX_HP) - ally.stat(BattleUnit.HP), 0)
		healing += mini(RestoreReader.hp_restore(ability, unit, ally, index == 0, has_primary), missing)
		hurt = mini(hurt, _hp_percent(ally))
		afflicted = afflicted or _afflicted(ally)
	if healing <= 0:
		return
	candidates.append({"ability": ability.ability_tag, "target": target.unit_id if target != null else &"",
		"healing": healing, "cost": cost, "order": order, "slot": target.slot if target != null else 0, "hurt": hurt,
		"cleanses": cleanses, "afflicted": afflicted})


## Spec auto-support D2: SPREAD_HURT or more living allies under SPREAD_BELOW% of their max HP.
static func _spread_hurt(battle: Battle) -> bool:
	var hurt := 0
	for ally in _party(battle):
		if _hp_percent(ally) < SPREAD_BELOW:
			hurt += 1
	return hurt >= SPREAD_HURT


## `party_wide`: only rows that reach every target (not a PRIMARY-only row, no chance, no application query), so a party
## buff never counts a status that cannot land on the whole party (spec auto-support 3.3, review fix).
static func _buff_tags(ability: BattleAbility, party_wide: bool = false) -> Array[StringName]:
	var tags: Array[StringName] = []
	for row in ability.executions:
		if row == null or row.effect == null:
			continue
		if party_wide and (row.targets == ExecutionRow.Targets.PRIMARY
				or (row.chance_x100 > 0 and row.chance_x100 < Fixed.ONE_HUNDRED_PERCENT)
				or row.effect.application_query != null):
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
	if ability.targeting == BattleAbility.Targeting.LOWEST_ALLY:  # review fix: only the most hurt living ally (slot order on ties)
		var lowest: Array[BattleUnit] = []
		for ally in _party(battle):
			if ally.is_up() and (lowest.is_empty() or Battle._hp_share(ally) < Battle._hp_share(lowest[0])):
				lowest.clear()
				lowest.append(ally)
		return lowest
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

## The unit's action abilities that can activate now and that the options allow; with `battle`, also only those whose HP cost
## it survives (spec second-pack 2.7).
func _activatable(unit: BattleUnit, battle: Battle = null) -> Array[BattleAbility]:
	var result: Array[BattleAbility] = []
	for ability in unit.action_abilities():
		if unit.asc.can_activate_ability(ability) and _allowed(unit, ability) and not ability.asset_tags.has(ROLE_GUARD) \
				and (battle == null or hp_cost_survivable(battle, unit, ability, options.danger_hp_x100)):
			result.append(ability)
	return result


## Spec second-pack 2.7: true unless paying the ability's HP cost would leave the caster under `danger_x100` of its max HP
## and the lifesteal on its best expected damage (damage_estimate over its targets) would not bring it back above.
static func hp_cost_survivable(battle: Battle, unit: BattleUnit, ability: BattleAbility, danger_x100: int) -> bool:
	var cost := int(CostReader.cost_of(ability, unit.asc).get(BattleUnit.HP, 0))
	if cost <= 0:
		return true
	var line := Fixed.pct(unit.stat(BattleUnit.MAX_HP), danger_x100)
	var after := unit.stat(BattleUnit.HP) - cost
	if after >= line:
		return true
	if not ability.targets_enemies() or not unit.asc.has_attribute("lifesteal"):
		return false
	var lifesteal := maxi(unit.stat("lifesteal"), 0)
	if lifesteal == 0 or battle == null:
		return false
	var best := 0
	for target in _targets(battle, unit, ability):
		best = maxi(best, damage_estimate(battle, unit, ability, target))
	return after + Fixed.pct(best, lifesteal) >= line


## Review fix (spec second-pack 2.7): the damage a move is expected to deal aimed at `target`, for its lifesteal: its damage
## rows only (no debuff value, break or kill bonus), weakness ×2 and resist ÷2, a RANDOM row once over its pool, each target's
## share capped at its HP (no overkill), blast neighbours at half. Before defence, so still an upper bound.
@warning_ignore("integer_division")
static func damage_estimate(battle: Battle, unit: BattleUnit, ability: BattleAbility, target: BattleUnit) -> int:
	var hit: Array[BattleUnit] = [target]
	if ability.targeting == BattleAbility.Targeting.ALL_ENEMIES:
		hit = _enemies_of(battle, unit)
	var neighbours: Array[BattleUnit] = []
	if ability.targeting == BattleAbility.Targeting.BLAST_ENEMY:
		neighbours = _neighbours(battle, unit, target)
	var pool := maxi(hit.size() + neighbours.size(), 1)
	var total := 0
	for other in hit + neighbours:
		var damage := 0
		for row in ability.executions:
			if row == null:
				continue
			var base := 0
			if row.damage_mode == ExecutionRow.DamageMode.SCALED:
				base = unit.stat("atk") * row.multiplier_x100 / 10000
			elif row.damage_mode == ExecutionRow.DamageMode.FLAT:
				base = row.flat_damage_x100
			if row.targets == ExecutionRow.Targets.RANDOM:
				base /= pool
			var kind := damage_type(row)
			if kind != "" and other.asc.has_tag_exact(StringName("Drain." + kind)):
				base = 0
			elif kind != "" and other.asc.has_tag_exact(StringName("Weakness." + kind)):
				base *= 2
			elif kind != "" and other.asc.has_tag_exact(StringName("Resist." + kind)):
				base /= 2
			damage += base
		if neighbours.has(other):
			damage /= 2
		total += mini(damage, other.stat(BattleUnit.HP))
	return total


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
	result.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)  # sort-ok: slot is an int
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
	result.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)  # sort-ok: slot is an int
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
