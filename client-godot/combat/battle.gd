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
signal unit_revived(unit_id: StringName)
signal battle_ended(outcome: String, final_hash: String)

const TURN_LIMIT: int = 1000
const ONGOING: String = "Ongoing"
const VICTORY: String = "Victory"
const DEFEAT: String = "Defeat"
const TURN_LIMIT_OUTCOME: String = "TurnLimit"

## Events the battle sends (spec game-skeleton 3.4). Triggered passives listen with GodotGAS's trigger_event_tag.
const EVENT_BATTLE_START: StringName = &"Event.Battle.Start"
const EVENT_TURN_START: StringName = &"Event.Turn.Start"
const EVENT_TURN_END: StringName = &"Event.Turn.End"
const EVENT_DAMAGE_DEALT: StringName = &"Event.Damage.Dealt"
const EVENT_DAMAGE_TAKEN: StringName = &"Event.Damage.Taken"
const EVENT_UNIT_DIED: StringName = &"Event.Unit.Died"
## A row tagged Damage.Type.<X> also sends Event.Damage.Dealt.<X> / Event.Damage.Taken.<X>.
const DAMAGE_TYPE_PREFIX: String = "Damage.Type."
## Loose tag on every unit in field mode; abilities use it in their activation_query (map-only / battle-only).
const IN_FIELD_TAG: StringName = &"State.InField"

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
## 1 or 2. v2 adds the run fields (spec game-skeleton 3.4/3.5): inventory capture, enemy loadouts, scaling, death and
## revive. A v1 snapshot runs exactly the slice 1 path.
var schema_version: int = 1
## Field mode: party only, no turn loop; perform() runs single out-of-battle actions.
var field_mode: bool = false
var triggers := TriggerQueue.new()
## Content warnings (duplicate ability grants, trigger chains cut short). Never a verdict.
var content_warnings := PackedStringArray()
## Usable items used in this battle, in order: [{"unit": unit id, "item": item id}].
var used_items: Array[Dictionary] = []

var _units: Array[BattleUnit] = []  # sorted by unit id
var _started: bool = false


## Builds the battle from a snapshot dictionary (BattleSnapshot JSON shape). Returns "" or a runner error.
func setup(snapshot: Dictionary, content: ContentIndex, presentation_gate: PresentationGate = null) -> String:
	assert(is_inside_tree(), "Battle.setup: add the Battle to the scene tree first")
	var error := _setup_common(snapshot, content, presentation_gate)
	if error != "":
		return error

	var party_error := _add_party(snapshot.get("party", []), content)
	if party_error != "":
		return party_error

	var encounter: EncounterDefinition = content.encounters.get(StringName(str(snapshot.get("encounterId", ""))))
	if encounter == null:
		return _fail("unknown encounterId '%s'" % snapshot.get("encounterId"))
	if schema_version < 2:
		var enemies := encounter.enemies()
		for index in enemies.size():
			_add_unit(StringName("E%d" % (index + 1)), BattleUnit.Side.ENEMY, index + 1, enemies[index], 1)
	else:
		var enemy_error := _add_enemies_v2(snapshot, encounter, content)
		if enemy_error != "":
			return enemy_error
	return _finish_setup()


## Field mode (spec game-skeleton 3.4): builds only the party from a v2 snapshot (no encounter, no turn loop) and tags
## every unit State.InField. Run single actions with perform().
func setup_field(snapshot: Dictionary, content: ContentIndex, presentation_gate: PresentationGate = null) -> String:
	assert(is_inside_tree(), "Battle.setup_field: add the Battle to the scene tree first")
	field_mode = true
	var error := _setup_common(snapshot, content, presentation_gate)
	if error != "":
		return error
	schema_version = maxi(schema_version, 2)
	var party_error := _add_party(snapshot.get("party", []), content)
	if party_error != "":
		return party_error
	for unit in _units:
		unit.asc.add_tag(IN_FIELD_TAG)
	return _finish_setup()


func _setup_common(snapshot: Dictionary, content: ContentIndex, presentation_gate: PresentationGate) -> String:
	if presentation_gate != null:
		gate = presentation_gate
	if not content.problems.is_empty():
		return _fail("content problems: " + "; ".join(content.problems))
	battle_id = str(snapshot.get("battleId", ""))
	schema_version = int(snapshot.get("schemaVersion", 1))
	var seed_text := str(snapshot.get("seed", ""))
	if not seed_text.is_valid_int() or seed_text.begins_with("-") or seed_text.begins_with("+"):
		return _fail("seed must be a decimal string, got '%s'" % seed_text)
	rng.seed = seed_text.to_int()
	return ""


func _add_party(party: Array, content: ContentIndex) -> String:
	# Party-wide passives from every member, in slot order (spec 3.4 step 2).
	var party_sets: Array = []
	if schema_version >= 2:
		var by_slot := party.duplicate()
		by_slot.sort_custom(func(a, b) -> bool: return int(a.get("slot", 0)) < int(b.get("slot", 0)))
		for member in by_slot:
			for item_id in _list(member, "items"):
				var item: ItemDefinition = content.items.get(StringName(str(item_id)))
				if item == null:
					return _fail("unknown item '%s'" % item_id)
				if item.applies_to == ItemDefinition.AppliesTo.PARTY and item.grants != null:
					party_sets.append({"set": item.grants})
	for member in party:
		var definition: UnitDefinition = content.units.get(StringName(str(member.get("unitDefId", ""))))
		if definition == null:
			return _fail("unknown unitDefId '%s'" % member.get("unitDefId"))
		var kit := {}
		if schema_version >= 2:
			kit = _party_kit(member, definition, content, party_sets)
			if runner_error != "":
				return runner_error
		var slot := int(member.get("slot", 0))
		_add_unit(StringName("P%d" % slot), BattleUnit.Side.PARTY, slot, definition, int(member.get("level", 1)), kit)
	return ""


## v2 party member: the capture of its run state (skills, equipment, passives, use slots, carried HP/MP/Energy).
func _party_kit(member: Dictionary, definition: UnitDefinition, content: ContentIndex, party_sets: Array) -> Dictionary:
	var skills: Array[PackedScene] = []
	for tag in _list(member, "skills"):
		var character := definition as CharacterDefinition
		var scene: PackedScene = character.skill_scene(StringName(str(tag))) if character != null else null
		if scene == null:
			_fail("%s cannot know skill '%s'" % [definition.id, tag])
			return {}
		skills.append(scene)
	var grants: Array = []
	var gear: Array[EquipmentDefinition] = []
	for equipment_id in _list(member, "equipmentIds"):
		var piece: EquipmentDefinition = content.equipment.get(StringName(str(equipment_id)))
		if piece == null:
			_fail("unknown equipment '%s'" % equipment_id)
			return {}
		gear.append(piece)
	gear.sort_custom(func(a, b) -> bool: return String(a.slot) < String(b.slot))
	for piece in gear:
		grants.append({"set": piece.grants})
	grants.append_array(party_sets)
	for item_id in _list(member, "items"):
		var item: ItemDefinition = content.items[StringName(str(item_id))]
		if item.applies_to == ItemDefinition.AppliesTo.HOLDER:
			grants.append({"set": item.grants})
	for use_slot in _list(member, "useSlots"):
		var usable: ItemDefinition = content.items.get(StringName(str(use_slot.get("itemId", ""))))
		if usable == null or not usable.is_usable():
			_fail("'%s' is not a usable item" % use_slot.get("itemId"))
			return {}
		grants.append({"set": usable.grants})
		if bool(use_slot.get("ready", false)):
			grants.append({"ability": usable.use_ability, "item": usable.id})
	return {
		"skills": skills,
		"grants": grants,
		"carry": {
			BattleUnit.HP: member.get("hp"),
			BattleUnit.MP: member.get("mp"),
			BattleUnit.ENERGY: member.get("energy"),
		},
	}


func _add_enemies_v2(snapshot: Dictionary, encounter: EncounterDefinition, content: ContentIndex) -> String:
	var scaling_effect: GameplayEffect = null
	if snapshot.get("scalingId") != null:
		var rules: ScalingRules = content.scaling.get(StringName(str(snapshot["scalingId"])))
		if rules == null:
			return _fail("unknown scaling '%s'" % snapshot["scalingId"])
		scaling_effect = rules.effect_for_depth(int(snapshot.get("depth", 0)))
	var entries: Array = []
	if snapshot.get("enemies") != null:
		for entry in snapshot["enemies"]:
			var definition: UnitDefinition = content.units.get(StringName(str(entry.get("unitDefId", ""))))
			if definition == null:
				return _fail("unknown unitDefId '%s'" % entry.get("unitDefId"))
			var loadout: Loadout = null
			if entry.get("loadoutRef") != null:
				loadout = content.resolve_loadout(str(entry["loadoutRef"]))
				if loadout == null:
					return _fail("unknown loadoutRef '%s'" % entry["loadoutRef"])
			var variant: EnemyVariant = null
			if entry.get("variantId") != null:
				variant = content.variants.get(StringName(str(entry["variantId"])))
				if variant == null:
					return _fail("unknown variant '%s'" % entry["variantId"])
			entries.append({"slot": int(entry.get("slot", 0)), "definition": definition, "loadout": loadout, "variant": variant})
	else:
		for index in encounter.slots.size():
			var slot: EncounterSlot = encounter.slots[index]
			var loadout: Loadout = slot.loadout if slot.loadout != null else slot.enemy.default_loadout
			entries.append({"slot": index + 1, "definition": slot.enemy, "loadout": loadout, "variant": slot.variant})
	for entry in entries:
		var kit := _enemy_kit(entry["loadout"], entry["variant"], scaling_effect)
		_add_unit(StringName("E%d" % entry["slot"]), BattleUnit.Side.ENEMY, entry["slot"], entry["definition"], 1, kit)
	return ""


## v2 enemy: its loadout (stats, skills, items, equipment), variant and floor scaling.
static func _enemy_kit(loadout: Loadout, variant: EnemyVariant, scaling_effect: GameplayEffect) -> Dictionary:
	var grants: Array = []
	var skills: Array[PackedScene] = []
	var stats := {}
	if loadout != null:
		skills = loadout.skills
		stats = loadout.stats_x100
		for piece in loadout.equipment:
			if piece != null:
				grants.append({"set": piece.grants})
		for item in loadout.items:
			if item == null:
				continue
			grants.append({"set": item.grants})
			if item.is_usable():
				grants.append({"ability": item.use_ability, "item": item.id})
	if variant != null:
		grants.append({"set": variant.grants})
	return {"stats": stats, "skills": skills, "grants": grants, "extra_effects": [scaling_effect], "carry": {}}


func _finish_setup() -> String:
	_units.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return String(a.unit_id) < String(b.unit_id))
	for unit in _units:
		content_warnings.append_array(unit.warnings)
		var problem := _unit_problem(unit)
		if problem != "":
			return _fail(problem)
		if not field_mode:
			turn_manager.add(unit)
		unit.asc.attribute_changed.connect(_on_attribute_changed.bind(unit))
	if schema_version >= 2:
		for unit in _units:
			if unit.stat(BattleUnit.HP) <= 0:
				unit.alive = false
				turn_manager.remove(unit)
				_lay_down(unit)
	return runner_error


static func _list(source: Dictionary, key: String) -> Array:
	var value: Variant = source.get(key)
	return value if value is Array else []


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


## Runs the turn loop until the battle ends or is stopped (spec "Turn order", steps 1-11). Triggered passives
## (spec game-skeleton 3.4) are drained after battle start, turn start, the action and turn end.
func run(controller: Object) -> void:
	if not _started:
		_started = true
		for unit in _units:
			if unit.alive:
				unit.asc.send_gameplay_event(EVENT_BATTLE_START, {"source": unit, "target": unit})
		await _drain_triggers()
		_check_deaths()
		_check_end()
	while is_running():
		var actor := turn_manager.next_actor()
		turn_manager.elapse(actor)
		turn += 1
		turn_started.emit(actor.unit_id, turn)

		actor.asc.turn_start()
		actor.asc.send_gameplay_event(EVENT_TURN_START, {"source": actor, "target": actor})
		await _drain_triggers()
		_check_deaths()
		_check_end()

		var action: Dictionary = {}
		if actor.alive and outcome == ONGOING:
			action = await _take_action(actor, controller)
			if not is_running() and outcome == ONGOING:
				break
			await _drain_triggers()
			if actor.alive:
				actor.asc.turn_end()
				actor.asc.send_gameplay_event(EVENT_TURN_END, {"source": actor, "target": actor})
				await _drain_triggers()
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


## Units an ability could target, in slot order: living ones, or for the dead-ally modes only dead allies.
func target_candidates(actor: BattleUnit, ability: BattleAbility) -> Array[BattleUnit]:
	var opposing := ability.targets_enemies()
	var want_dead := ability.targets_dead()
	var result: Array[BattleUnit] = []
	for unit in _units:
		if unit.alive != want_dead and (unit.side != actor.side) == opposing:
			result.append(unit)
	result.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)
	return result


## Checks a decision. Returns [] when legal, else [reason, detail] (MismatchReason names).
func validate_action(actor: BattleUnit, choice: Dictionary) -> Array:
	var tag := StringName(str(choice.get("ability", "")))
	var ability := actor.ability_by_tag(tag)
	if ability == null:
		return ["IllegalAbility", "%s has no ability %s" % [actor.unit_id, tag]]
	if ability.is_triggered():
		return ["IllegalAbility", "%s is a triggered passive, not an action" % tag]
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
		if ability.targets_dead():
			if target.alive:
				continue
		elif not target.is_up():
			continue
		var hp_before := target.stat(BattleUnit.HP)
		# One spec per target: turn-based effects keep their spec, so sharing one would share the countdown.
		var context := GameplayEffectContext.new(unit, unit)
		context.target_data.append_node(target)
		var spec := GameplayEffectSpec.new(row.effect, context, ability.ability_level)
		row.apply_override(spec)
		unit.asc.apply_effect_spec_to_target(spec, target.asc)
		hit_ids.append(target.unit_id)
		var damage := hp_before - target.stat(BattleUnit.HP)
		if damage > 0:
			_send_damage_events(unit, target, damage, row)
	execution_resolved.emit(unit.unit_id, row.id, hit_ids)
	if schema_version >= 2:
		_check_revives()


## Event.Damage.Dealt (source) and Event.Damage.Taken (target), plus .<X> for each Damage.Type.<X> row tag.
## Only queues triggers; they run when the battle drains the queue.
func _send_damage_events(source: BattleUnit, target: BattleUnit, damage: int, row: ExecutionRow) -> void:
	var payload := {"source": source, "target": target, "amount": damage, "row": row.id, "tags": row.tags}
	source.asc.send_gameplay_event(EVENT_DAMAGE_DEALT, payload)
	target.asc.send_gameplay_event(EVENT_DAMAGE_TAKEN, payload)
	for tag in row.tags:
		if String(tag).begins_with(DAMAGE_TYPE_PREFIX):
			var damage_type := String(tag).trim_prefix(DAMAGE_TYPE_PREFIX)
			source.asc.send_gameplay_event(StringName("%s.%s" % [EVENT_DAMAGE_DEALT, damage_type]), payload)
			target.asc.send_gameplay_event(StringName("%s.%s" % [EVENT_DAMAGE_TAKEN, damage_type]), payload)


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
	var activated := await _activate(actor, ability, unit_by_id(target_id))
	if not activated:
		if actor.is_party():
			reject("IllegalAbility", "%s failed to activate" % ability.ability_tag)
		else:
			_fail("enemy ability %s failed to activate" % ability.ability_tag)
		return {}
	return {"ability": ability.ability_tag, "target": target_id}


## Activates an action ability. A usable item's ability works once per battle: afterwards it is revoked and recorded
## in used_items, so the game can consume the item or start its cooldown.
func _activate(actor: BattleUnit, ability: BattleAbility, target: BattleUnit) -> bool:
	var tag := ability.ability_tag
	var payload := _expand_targets(actor, ability, target)
	payload["battle"] = self
	payload["unit"] = actor
	var activated: bool = await ability.try_activate(payload)
	if activated and actor.item_abilities.has(tag):
		used_items.append({"unit": actor.unit_id, "item": actor.item_abilities[tag]})
		actor.item_abilities.erase(tag)
		actor.revoke_ability(ability)
	return activated


## Field mode: applies one effect to each listed unit (event outcomes such as heals or revives), then settles deaths
## and revives. Effects come from content .tres files, never built in code.
func apply_to_units(effect: GameplayEffect, unit_ids: Array[StringName]) -> void:
	for id in unit_ids:
		var unit := unit_by_id(id)
		if unit != null:
			unit.asc.apply_gameplay_effect(effect, unit.asc, unit.level)
	_check_revives()
	_check_deaths()


## Field mode: one out-of-battle action (spec game-skeleton 3.4). Returns [] on success, else [reason, detail].
## Only ally targeting works in the field; the actor must be alive.
func perform(actor_id: StringName, ability_tag: StringName, target_id: StringName = &"") -> Array:
	var actor := unit_by_id(actor_id)
	if actor == null or not actor.alive:
		return ["DeadActor", "%s can't act" % actor_id]
	var ability := actor.ability_by_tag(ability_tag)
	if ability != null and ability.targets_enemies():
		return ["InvalidTarget", "%s targets enemies; there are none outside battle" % ability_tag]
	var problem := validate_action(actor, {"ability": ability_tag, "target": target_id})
	if not problem.is_empty():
		return problem
	if not await _activate(actor, ability, unit_by_id(target_id)):
		return ["IllegalAbility", "%s failed to activate" % ability_tag]
	await _drain_triggers()
	_check_revives()
	_check_deaths()
	return []


## Expands the primary target into the full target list, in canonical slot order (spec "Targeting").
func _expand_targets(actor: BattleUnit, ability: BattleAbility, target: BattleUnit) -> Dictionary:
	var targets: Array[BattleUnit] = []
	var primary: BattleUnit = null
	match ability.targeting:
		BattleAbility.Targeting.SINGLE_ENEMY, BattleAbility.Targeting.SINGLE_ALLY, BattleAbility.Targeting.SINGLE_DEAD_ALLY:
			primary = target
			targets.append(target)
		BattleAbility.Targeting.ALL_DEAD_ALLIES:
			targets = target_candidates(actor, ability)
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


func _add_unit(id: StringName, side: BattleUnit.Side, slot: int, definition: UnitDefinition, level: int,
		kit: Dictionary = {}) -> void:
	_units.append(BattleUnit.create(self, id, side, slot, definition, level, kit))


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


## Step 7: units at or below 0 HP die and leave the turn queue. v1: their ASC is cleaned up (slice 1). v2: they keep
## their node and ASC so they can be revived (spec game-skeleton 3.4), and every living unit gets Event.Unit.Died.
func _check_deaths() -> void:
	if schema_version >= 2:
		_check_revives()
	var died: Array[BattleUnit] = []
	for unit in _units:
		if unit.alive and unit.stat(BattleUnit.HP) <= 0:
			unit.alive = false
			turn_manager.remove(unit)
			if schema_version >= 2:
				_lay_down(unit)
			else:
				unit.asc.cleanup()
			unit_died.emit(unit.unit_id)
			died.append(unit)
	if schema_version >= 2:
		for dead in died:
			for unit in _units:
				if unit.alive:
					unit.asc.send_gameplay_event(EVENT_UNIT_DIED, {"source": dead, "target": dead})


## v2 death: State.Dead, and temporary effects (buffs, debuffs, DoTs) are dropped. Infinite effects from items and
## equipment stay, so a revived unit has them again.
func _lay_down(unit: BattleUnit) -> void:
	for i in range(unit.asc._active_effects.size() - 1, -1, -1):
		var active_effect: ActiveGameplayEffect = unit.asc._active_effects[i]
		if active_effect.get_effect_def().policy != GameplayEffect.DurationPolicy.INFINITE:
			unit.asc.remove_active_effect(active_effect)
	if not unit.asc.has_tag_exact(BattleUnit.DEAD_TAG):
		unit.asc.add_tag(BattleUnit.DEAD_TAG)


## v2: a dead unit whose HP an effect raised above 0 comes back, with a fresh action value.
func _check_revives() -> void:
	for unit in _units:
		if not unit.alive and unit.stat(BattleUnit.HP) > 0:
			unit.alive = true
			unit.asc.clear_tag(BattleUnit.DEAD_TAG)
			if not field_mode:
				turn_manager.add(unit)
			unit_revived.emit(unit.unit_id)


## Runs queued triggered passives in FIFO order, awaiting each (spec game-skeleton 3.4, decision 10).
func _drain_triggers() -> void:
	triggers.draining = true
	while is_running() and not triggers.is_empty():
		var entry := triggers.pop()
		if int(entry["depth"]) > TriggerQueue.MAX_DEPTH:
			content_warnings.append("trigger chain deeper than %d stopped at %s" % [TriggerQueue.MAX_DEPTH, entry["event_tag"]])
			triggers.clear()
			break
		triggers.current_depth = int(entry["depth"])
		var unit: BattleUnit = entry["unit"]
		var ability: BattleAbility = entry["ability"]
		if not is_instance_valid(ability) or not unit.is_up() or not unit.asc.can_activate_ability(ability):
			continue
		var target := _trigger_target(unit, ability, entry["payload"])
		if ability.needs_target() and target == null:
			continue
		var payload := _expand_targets(unit, ability, target)
		payload["battle"] = self
		payload["unit"] = unit
		payload["event"] = entry["payload"]
		await ability.try_activate(payload)
	triggers.draining = false
	triggers.current_depth = 0


## A triggered single-target ability aims at the event's other unit when that is a valid target, else the first valid
## candidate by slot (no RNG).
func _trigger_target(unit: BattleUnit, ability: BattleAbility, event_payload: Variant) -> BattleUnit:
	if not ability.needs_target():
		return null
	var other: BattleUnit = null
	if event_payload is Dictionary:
		other = event_payload.get("target") if event_payload.get("source") == unit else event_payload.get("source")
	elif event_payload is GameplayEffectSpec and event_payload.context != null:
		other = event_payload.context.instigator as BattleUnit
	var candidates := target_candidates(unit, ability)
	if other != null and candidates.has(other):
		return other
	return candidates[0] if not candidates.is_empty() else null


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
