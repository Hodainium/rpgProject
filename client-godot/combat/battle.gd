## The deterministic battle kernel shared by the client (record) and the verifier (replay).
## Spec: specs/combat-replay-core.md.
##
## A controller supplies party decisions (the player through presentation, or a replayed action log); enemy turns
## come from EnemyBrain. Presentation only listens to the signals and opens the presentation gate; it never changes
## combat state.
##
## Controller interface (duck-typed):
##   choose(battle, unit) -> {"ability": StringName, "target": StringName}   (may await; the client waits for input)
##   on_invalid(battle, unit, reason, detail) -> bool                         (true: ask again; false: stop)
##   after_party_turn(battle, unit, action, checkpoint) -> void
class_name Battle
extends Node

signal turn_started(unit_id: StringName, turn: int)
signal execution_resolved(unit_id: StringName, row_id: StringName, target_ids: Array[StringName])
signal unit_died(unit_id: StringName)
signal battle_ended(outcome: String, final_hash: String)

const TURN_LIMIT: int = 1000
const ONGOING: String = "Ongoing"
const VICTORY: String = "Victory"
const DEFEAT: String = "Defeat"
const TURN_LIMIT_OUTCOME: String = "TurnLimit"

## The battle's single seeded RNG. Combat draws from nothing else.
var rng := RandomNumberGenerator.new()
var gate: PresentationGate = HeadlessGate.new()
var turn_manager := TurnManager.new()
var battle_id: String = ""
var turn: int = 0
var outcome: String = ONGOING
## Set when content is broken (exit code 1 in the runner; never a verdict).
var runner_error: String = ""
## Set when a controller rejects the battle ({"reason", "turn", "detail"}); stops the battle.
var mismatch: Dictionary = {}
var final_hash: String = ""

var _units: Array[BattleUnit] = []  # sorted by unit id


## Builds the battle from a snapshot dictionary (BattleSnapshot JSON shape). Returns "" or a runner error.
func setup(snapshot: Dictionary, content: ContentIndex, presentation_gate: PresentationGate = null) -> String:
	assert(is_inside_tree(), "Battle.setup: add the Battle to the scene tree first")
	if presentation_gate != null:
		gate = presentation_gate
	if not content.problems.is_empty():
		return _fail("content problems: " + "; ".join(content.problems))
	battle_id = str(snapshot.get("battleId", ""))
	var seed_text := str(snapshot.get("seed", ""))
	if not seed_text.is_valid_int() or seed_text.begins_with("-") or seed_text.begins_with("+"):
		return _fail("seed must be a decimal string, got '%s'" % seed_text)
	rng.seed = seed_text.to_int()

	var party: Array = snapshot.get("party", [])
	for member in party:
		var definition: UnitDefinition = content.units.get(StringName(str(member.get("unitDefId", ""))))
		if definition == null:
			return _fail("unknown unitDefId '%s'" % member.get("unitDefId"))
		var slot := int(member.get("slot", 0))
		_add_unit(StringName("P%d" % slot), BattleUnit.Side.PARTY, slot, definition, int(member.get("level", 1)))

	var encounter: EncounterDefinition = content.encounters.get(StringName(str(snapshot.get("encounterId", ""))))
	if encounter == null:
		return _fail("unknown encounterId '%s'" % snapshot.get("encounterId"))
	for index in encounter.enemies.size():
		_add_unit(StringName("E%d" % (index + 1)), BattleUnit.Side.ENEMY, index + 1, encounter.enemies[index], 1)

	_units.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return String(a.unit_id) < String(b.unit_id))
	for unit in _units:
		var problem := _unit_problem(unit)
		if problem != "":
			return _fail(problem)
		turn_manager.add(unit)
		unit.asc.attribute_changed.connect(_on_attribute_changed.bind(unit))
	return runner_error


func units() -> Array[BattleUnit]:
	return _units


func unit_by_id(id: StringName) -> BattleUnit:
	for unit in _units:
		if unit.unit_id == id:
			return unit
	return null


func is_running() -> bool:
	return outcome == ONGOING and runner_error == "" and mismatch.is_empty()


## Stops the battle with a replay mismatch (verdict 2002). Only the first call counts.
func reject(reason: String, detail: String) -> void:
	if mismatch.is_empty():
		mismatch = {"reason": reason, "turn": turn, "detail": detail}


## Runs the turn loop until the battle ends or is stopped (spec "Turn order", steps 1-11).
func run(controller: Object) -> void:
	while is_running():
		var actor := turn_manager.next_actor()
		turn_manager.elapse(actor)
		turn += 1
		turn_started.emit(actor.unit_id, turn)

		actor.asc.turn_start()
		_check_deaths()
		_check_end()

		var action: Dictionary = {}
		if actor.alive and outcome == ONGOING:
			action = await _take_action(actor, controller)
			if not is_running() and outcome == ONGOING:
				break
			if actor.alive:
				actor.asc.turn_end()
		_check_deaths()
		_check_end()
		if actor.alive:
			turn_manager.reset(actor)
			var spd_problem := TurnManager.spd_problem(actor)
			if spd_problem != "":
				_fail(spd_problem)
				break
		if outcome == ONGOING and turn >= TURN_LIMIT:
			outcome = TURN_LIMIT_OUTCOME

		if actor.is_party() and not action.is_empty():
			var checkpoint := state_hash()
			if runner_error != "":
				break
			controller.after_party_turn(self, actor, action, checkpoint)

	if runner_error == "":
		final_hash = state_hash()
	battle_ended.emit(outcome, final_hash)


## Living units an ability could target, in slot order.
func target_candidates(actor: BattleUnit, ability: BattleAbility) -> Array[BattleUnit]:
	var opposing := ability.targeting in [BattleAbility.Targeting.SINGLE_ENEMY, BattleAbility.Targeting.BLAST_ENEMY,
		BattleAbility.Targeting.ALL_ENEMIES]
	var result: Array[BattleUnit] = []
	for unit in _units:
		if unit.alive and (unit.side != actor.side) == opposing:
			result.append(unit)
	result.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)
	return result


## Checks a decision. Returns [] when legal, else [reason, detail] (MismatchReason names).
func validate_action(actor: BattleUnit, choice: Dictionary) -> Array:
	var tag := StringName(str(choice.get("ability", "")))
	var ability := actor.ability_by_tag(tag)
	if ability == null:
		return ["IllegalAbility", "%s has no ability %s" % [actor.unit_id, tag]]
	if not actor.asc.can_activate_ability(ability):
		return ["IllegalAbility", "%s cannot activate %s now" % [actor.unit_id, tag]]
	var target_id := StringName(str(choice.get("target", "")))
	if ability.needs_target():
		var target := unit_by_id(target_id)
		if target == null or not target_candidates(actor, ability).has(target):
			return ["InvalidTarget", "%s is not a valid target for %s" % [target_id, tag]]
	elif target_id != &"":
		return ["InvalidTarget", "%s takes no target, got %s" % [tag, target_id]]
	return []


## Applies one execution-table row (called by BattleAbility for each entry of its execution sequence).
func resolve_execution(unit: BattleUnit, ability: BattleAbility, row: ExecutionRow, action: Dictionary) -> void:
	if row == null or row.effect == null:
		_fail("%s: execution row missing or without effect" % ability.ability_tag)
		return
	var primary: BattleUnit = action["primary"]
	var all_targets: Array[BattleUnit] = action["targets"]
	var hit: Array[BattleUnit] = []
	match row.targets:
		ExecutionRow.Targets.PRIMARY:
			var first: BattleUnit = primary if primary != null else (all_targets[0] if not all_targets.is_empty() else null)
			if first != null:
				hit.append(first)
		ExecutionRow.Targets.ADJACENT:
			for target in all_targets:
				if target != primary:
					hit.append(target)
		_:
			hit = all_targets.duplicate()
	var hit_ids: Array[StringName] = []
	for target in hit:
		if not target.is_up():
			continue
		# One spec per target: turn-based effects keep their spec, so sharing one would share the countdown.
		var context := GameplayEffectContext.new(unit, unit)
		context.target_data.append_node(target)
		var spec := GameplayEffectSpec.new(row.effect, context, ability.ability_level)
		row.apply_override(spec)
		unit.asc.apply_effect_spec_to_target(spec, target.asc)
		hit_ids.append(target.unit_id)
	execution_resolved.emit(unit.unit_id, row.id, hit_ids)


## State hash v1 of the current state. Sets runner_error when the state can't be hashed.
func state_hash() -> String:
	var result := StateHasher.compute(self)
	if result["error"] != "":
		_fail(result["error"])
	return result["hash"]


func _take_action(actor: BattleUnit, controller: Object) -> Dictionary:
	var choice: Dictionary
	if actor.is_party():
		while true:
			choice = await controller.choose(self, actor)
			if not is_running():
				return {}
			var problem := validate_action(actor, choice)
			if problem.is_empty():
				break
			if not controller.on_invalid(self, actor, problem[0], problem[1]):
				reject(problem[0], problem[1])
				return {}
	else:
		var brain: EnemyBrain = actor.definition.brain if actor.definition.brain != null else EnemyBrain.new()
		choice = brain.choose(actor, self)
		if StringName(str(choice.get("ability", ""))) == &"":
			return {}
		var problem := validate_action(actor, choice)
		if not problem.is_empty():
			_fail("enemy brain chose an illegal action: " + problem[1])
			return {}

	var ability := actor.ability_by_tag(StringName(str(choice["ability"])))
	var target_id := StringName(str(choice.get("target", "")))
	var payload := _expand_targets(actor, ability, unit_by_id(target_id))
	payload["battle"] = self
	payload["unit"] = actor
	var activated: bool = await ability.try_activate(payload)
	if not activated:
		if actor.is_party():
			reject("IllegalAbility", "%s failed to activate" % ability.ability_tag)
		else:
			_fail("enemy ability %s failed to activate" % ability.ability_tag)
		return {}
	return {"ability": ability.ability_tag, "target": target_id}


## Expands the primary target into the full target list, in canonical slot order (spec "Targeting").
func _expand_targets(actor: BattleUnit, ability: BattleAbility, target: BattleUnit) -> Dictionary:
	var targets: Array[BattleUnit] = []
	var primary: BattleUnit = null
	match ability.targeting:
		BattleAbility.Targeting.SINGLE_ENEMY, BattleAbility.Targeting.SINGLE_ALLY:
			primary = target
			targets.append(target)
		BattleAbility.Targeting.BLAST_ENEMY:
			primary = target
			for candidate in target_candidates(actor, ability):
				if absi(candidate.slot - target.slot) <= 1:
					targets.append(candidate)
		BattleAbility.Targeting.ALL_ENEMIES, BattleAbility.Targeting.ALL_ALLIES:
			targets = target_candidates(actor, ability)
		BattleAbility.Targeting.SELF:
			primary = actor
			targets.append(actor)
	return {"primary": primary, "targets": targets}


func _add_unit(id: StringName, side: BattleUnit.Side, slot: int, definition: UnitDefinition, level: int) -> void:
	_units.append(BattleUnit.create(self, id, side, slot, definition, level))


func _unit_problem(unit: BattleUnit) -> String:
	for attribute_name in [BattleUnit.HP, BattleUnit.SPD]:
		if not unit.asc.has_attribute(attribute_name):
			return "%s (%s) has no %s attribute" % [unit.unit_id, unit.definition.id, attribute_name]
	var spd_problem := TurnManager.spd_problem(unit)
	if spd_problem != "":
		return spd_problem
	for ability in unit.abilities():
		var problems := ExecutionReader.validate(ability)
		if not problems.is_empty():
			return "; ".join(problems)
	return ""


## Step 7: units at or below 0 HP die, leave the turn queue and drop their effects.
func _check_deaths() -> void:
	for unit in _units:
		if unit.alive and unit.stat(BattleUnit.HP) <= 0:
			unit.alive = false
			turn_manager.remove(unit)
			unit.asc.cleanup()
			unit_died.emit(unit.unit_id)


## Step 8: all enemies dead → Victory (checked first); all party dead → Defeat.
func _check_end() -> void:
	if outcome != ONGOING:
		return
	var enemies_left := false
	var party_left := false
	for unit in _units:
		if unit.alive:
			if unit.is_party():
				party_left = true
			else:
				enemies_left = true
	if not enemies_left:
		outcome = VICTORY
	elif not party_left:
		outcome = DEFEAT


func _on_attribute_changed(attribute_name: String, old_value: float, new_value: float, _spec: GameplayEffectSpec,
		unit: BattleUnit) -> void:
	if attribute_name == BattleUnit.SPD:
		turn_manager.on_spd_changed(unit, old_value, new_value)


func _fail(message: String) -> String:
	if runner_error == "":
		runner_error = message
	return runner_error
