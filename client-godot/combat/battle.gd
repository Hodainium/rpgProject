## The deterministic battle kernel shared by the client (record) and the verifier (replay).
## Spec: specs/combat-replay-core.md.
##
## A controller supplies party decisions (the player through presentation, or a replayed action log); enemy turns
## come from EnemyBrain. Presentation only listens to the signals and opens the presentation gate; it never changes
## combat state.
##
## Controller interface (duck-typed):
##   choose(battle, unit) -> {"ability": StringName, "target": StringName}   (may await; the client waits for input)
##       or, at a DECISION ult window, {"interrupt": true, "unit", "ability", "target"} (spec ult-interrupts)
##   on_invalid(battle, unit, reason, detail) -> bool                         (true: ask again; false: stop)
##   after_party_turn(battle, unit, action) -> void
##   interrupt(battle) -> {"interrupt": true, "unit", "ability", "target"} or {}   (BETWEEN window; never awaits)
##   after_interrupt(battle, unit, action) -> void
## A battle is hashed once, at its end (spec atomic-battles); attach a BattleTrace to hash after every action.
class_name Battle
extends Node

signal turn_started(unit_id: StringName, turn: int)
signal execution_resolved(unit_id: StringName, row_id: StringName, target_ids: Array[StringName])
signal unit_died(unit_id: StringName)
signal unit_revived(unit_id: StringName)
signal battle_ended(outcome: String, final_hash: String)
## Spec item-pass: a damaging hit with its Hit.* tags (Critical, Weakness, Break, FollowUp…), for presentation.
## `hit_tags` are the hit's Hit.* tags (sorted) followed by the row's Damage.Type.<X> tags (spec vfx-content-pass 3.3): the
## presentation reads the type from here. The log, the trace and the hash never read this signal.
signal damage_dealt(source_id: StringName, target_id: StringName, amount: int, hit_tags: Array[StringName])
## Spec vfx-content-pass 2.5: an HP change that is not already a row hit's damage (a heal, a DoT / HoT tick, a cost, a dev
## effect). `delta_x100` is negative for a loss; `cause_tags` are the Status.* tags the effect grants (empty for a plain
## heal). Presentation only: nothing in the kernel listens.
signal hp_changed(unit_id: StringName, delta_x100: int, cause_tags: Array[StringName])
## A triggered passive activated (logged by the dev report so a headless check can see it fire).
signal trigger_activated(unit_id: StringName, ability_tag: StringName, event_tag: StringName)
signal unit_broken(unit_id: StringName, breaker_id: StringName)
signal unit_recovered(unit_id: StringName)
signal one_more_started(unit_id: StringName)
## Spec ult-interrupts: a unit (party or enemy) casts its ult out of turn.
signal interrupt_started(unit_id: StringName, ability_tag: StringName)
## Spec content-pass (read-only, for presentation and the dev report): a controlled unit lost its turn (H1); a status
## roll missed (H2); a hit was drained and healed its target (2.4); a boss entered a phase (H5); an action value moved (H6).
signal turn_skipped(unit_id: StringName)
signal status_resisted(source_id: StringName, target_id: StringName, effect_path: String)
## `tags`: Hit.Drained plus the row's Damage.Type.<X> tags (spec vfx-content-pass: the presentation shows what the target absorbed). Never read by the log, the trace or the hash.
signal damage_drained(source_id: StringName, target_id: StringName, amount: int, tags: Array[StringName])
signal phase_changed(unit_id: StringName, phase: int)
signal action_delayed(unit_id: StringName, percent: int)
## Spec content-pass H7: an enemy hit a party unit's weakness (the attacker is owed a One More).
signal unit_downed(unit_id: StringName, by_id: StringName)
## Spec ff7-ui 2.2 (read-only, for the battle feed): an action ability was activated by a unit, at a target ("" when
## it has none). Emitted after activation; nothing in combat listens.
signal ability_activated(unit_id: StringName, ability_tag: StringName, target_id: StringName)

## Spec skill-points D15: a battle with no outcome after this many turns ends as TurnLimit, a loss for the run.
const TURN_LIMIT: int = 500
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
## Sent to a unit after it uses an ability as its action in battle (not triggered passives, not on the map).
## Payload: {"source", "target": the unit, "ability": the ability tag}. Ult charge listens to it.
const EVENT_ABILITY_USED: StringName = &"Event.Ability.Used"
## A row tagged Damage.Type.<X> also sends Event.Damage.Dealt.<X> / Event.Damage.Taken.<X>.
const DAMAGE_TYPE_PREFIX: String = "Damage.Type."
## Spec item-pass 3.1: every Hit.<X> tag on a hit's spec (injected by the ExecCalc or the battle) also sends
## Event.Damage.Dealt.<X> / Event.Damage.Taken.<X>. The battle never keeps a list of hit kinds.
const HIT_TAG_PREFIX: String = "Hit."
const HIT_BREAK: StringName = &"Hit.Break"
const HIT_FOLLOW_UP: StringName = &"Hit.FollowUp"
## Sent to a follow-up's unit after it fires. Payload: {"source", "target": its primary target, "ability"}.
const EVENT_ATTACK_FOLLOW_UP: StringName = &"Event.Attack.FollowUp"
## Sent to the unit whose effect last lowered a dead unit's HP. Payload: {"source": killer, "target": the dead unit}.
const EVENT_UNIT_KILLED: StringName = &"Event.Unit.Killed"
## Sent to a unit as its One More action starts. Payload: {"source", "target": the unit}.
const EVENT_ONE_MORE: StringName = &"Event.Battle.OneMore"
## Spec item-pass 3.2 (HSR break): a unit whose toughness a hit empties is Broken until its next turn starts.
const BROKEN_TAG: StringName = &"State.Broken"
const TOUGHNESS: String = "toughness"
const MAX_TOUGHNESS: String = "max_toughness"
## A Broken unit's action is delayed by this share of its full action value (25.00%).
const BREAK_DELAY: int = 2500
## Loose tag on every unit in field mode; abilities use it in their activation_query (map-only / battle-only).
const IN_FIELD_TAG: StringName = &"State.Infield"
## Spec content-pass H1: a unit with this rule tag (granted by Freeze, Stun… beside their Status.Debuff.* tag) loses
## its turn: no action, nothing logged, but its turn ticks and countdowns still run.
const CONTROLLED_TAG: StringName = &"State.Controlled"
## Sent to a controlled unit whose turn was skipped. Payload: {"source", "target": the unit}.
const EVENT_TURN_SKIPPED: StringName = &"Event.Turn.Skipped"
## Spec content-pass H2: a status roll missed. Sent to source and target. Payload: {"source", "target", "row", "tags",
## "effect": the effect's resource path}.
const EVENT_STATUS_RESISTED: StringName = &"Event.Status.Resisted"
## Spec content-pass 2.4: a hit the target drains (Hit.Drained, from the damage ExecCalc) heals it instead.
const HIT_DRAINED: StringName = &"Hit.Drained"
## Spec content-pass H4: a breaking hit also sends Event.Damage.Dealt/Taken.Break.<DamageType>; an action also sends
## Event.Ability.Used.<X> for each Ability.Type.<X> asset tag; an out-of-turn ult sends Event.Battle.Interrupt to its
## caster ({"source", "target": the caster, "ability"}).
const ABILITY_TYPE_PREFIX: String = "Ability.Type."
const EVENT_BATTLE_INTERRUPT: StringName = &"Event.Battle.Interrupt"
## Spec content-pass H5: sent to a boss as it enters a phase. Payload: {"source", "target": the unit, "phase": n (1-based)}.
const EVENT_PHASE_CHANGED: StringName = &"Event.Unit.PhaseChanged"
## Spec content-pass 2.2: while a party unit has this rule tag (Taunt), enemies' single-target actions must target a
## taunting unit.
const TAUNTING_TAG: StringName = &"State.Taunting"
## Prefix of the debuff tags a boss phase's clear_debuffs removes.
const DEBUFF_TAG: StringName = &"Status.Debuff"
## Spec content-pass H7 (Persona): party units are never Broken. An enemy hit on a party unit's weakness downs it
## (this rule tag) and gives the attacker a One More; a Downed unit grants no other until its next turn starts.
const DOWNED_TAG: StringName = &"State.Downed"
## Spec content-pass H8: extra turns (whole turns, ×100) on the turn-based debuffs a unit's rows apply.
const DEBUFF_TURNS: String = "debuff_turns"
const HIT_WEAKNESS: StringName = &"Hit.Weakness"

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
## Dev decisions (spec dev-tools 3.6) are applied only when set: the run sets it in local mode; replay never does, so a
## logged dev decision is an IllegalAbility (2002) there.
var allow_dev: bool = false
## Spec item-pass 3.2: units owed a One More (they broke a unit), in break order; each acts once more before the turn
## queue moves on. Hashed (only when not empty).
var one_more_queue: Array[BattleUnit] = []
## True while the current decision is a One More action; the log entry carries "extra": true.
var extra_action: bool = false
## True while an ult cast out of turn resolves (spec ult-interrupts).
var in_interrupt: bool = false
## Spec atomic-battles: the determinism trace (tests and dev tools only). null = no trace and no hashing before the end.
var trace: BattleTrace = null

var _units: Array[BattleUnit] = []  # sorted by unit id
## unit_id -> how many rows are applying their effect to it right now: an HP loss of THAT unit then is the row's own hit
## (damage_dealt carries it), not an hp_changed. Any other unit's loss in that moment (a side effect of the row) is reported.
var _row_targets: Dictionary = {}
## unit_id -> {sum, cause}: the HP changes of the periodic effect that is ticking on that unit, reported as one hp_changed.
var _tick_open: Dictionary = {}
## Instant effect that refills a recovering unit's toughness (amount by SetByCaller); built in code, never persisted.
var _refill_effect: GameplayEffect
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
## every unit State.Infield. Run single actions with perform().
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
		var item: ItemDefinition = content.items.get(StringName(str(item_id)))
		if item == null:
			_fail("unknown item '%s'" % item_id)
			return {}
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
	# Spec playable-demo 3.11 (D28): the class's growth, once per level above 1, from the snapshot's level.
	var growth: Array = []
	var character := definition as CharacterDefinition
	if character != null and character.level_effect != null:
		for count in maxi(int(member.get("level", 1)) - 1, 0):
			growth.append(character.level_effect)
	return {
		"skills": skills,
		"grants": grants,
		"extra_effects": growth,
		"carry": {
			BattleUnit.HP: member.get("hp"),
			BattleUnit.MP: member.get("mp"),
			BattleUnit.ENERGY: member.get("energy"),
		},
	}


func _add_enemies_v2(snapshot: Dictionary, encounter: EncounterDefinition, content: ContentIndex) -> String:
	var scaling_effect: GameplayEffect = null
	var depth_level := 1  # spec skill-points D19: the enemies' level before variant and slot bonuses
	if snapshot.get("scalingId") != null:
		var rules: ScalingRules = content.scaling.get(StringName(str(snapshot["scalingId"])))
		if rules == null:
			return _fail("unknown scaling '%s'" % snapshot["scalingId"])
		scaling_effect = rules.effect_for_depth(int(snapshot.get("depth", 0)))
		depth_level = rules.level_for_depth(int(snapshot.get("depth", 0)))
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
	var mirrored := entries.any(func(entry: Dictionary) -> bool:
		return entry["definition"] is EnemyDefinition and entry["definition"].mirror_party_items)
	# Spec skill-points D14: the pieces a mirror boss of this encounter never copies.
	var skip: Array[StringName] = []
	var limit := 0  # spec skill-points D13 (b): the smallest mirror_limit set in the encounter (0 = none)
	for entry in entries:
		if entry["definition"] is EnemyDefinition and entry["definition"].mirror_party_items:
			for tag in entry["definition"].mirror_skip_tags:
				if not skip.has(tag):
					skip.append(tag)
			var own: int = entry["definition"].mirror_limit
			if own > 0 and (limit == 0 or own < limit):
				limit = own
	var mirror := _mirror_of_party(snapshot, content, skip, limit)
	if runner_error != "":
		return runner_error
	for entry in entries:
		var kit := _enemy_kit(entry["loadout"], entry["variant"], scaling_effect)
		# Spec playable-demo 3.8: H9 a mirror boss takes every held item's and armor piece's passives (party-wide ones
		# go to every enemy of its encounter); H10 its per-item effect once per piece held.
		var enemy := entry["definition"] as EnemyDefinition
		if mirrored:
			kit["grants"].append_array(mirror["party"])
		if enemy != null and enemy.mirror_party_items:
			kit["grants"].append_array(mirror["holder"])
		if enemy != null and enemy.per_item_effect != null:
			for count in mirror["count"]:
				kit["extra_effects"].append(enemy.per_item_effect)
		# Spec playable-demo 3.7: the encounter's grants, then its slot's (from content, by encounter id and slot number).
		var encounter_slot: EncounterSlot = null
		var number: int = entry["slot"]
		if number >= 1 and number <= encounter.slots.size():
			encounter_slot = encounter.slots[number - 1]
		for ability_set in [encounter.grants, encounter_slot.grants if encounter_slot != null else null]:
			if ability_set != null:
				kit["grants"].append({"set": ability_set})
		var id := StringName("E%d" % number)
		# Spec skill-points D19, D21: the enemy's level (secret skills) from depth, variant and slot; its GAS level stays 1.
		var enemy_level := depth_level
		if entry["variant"] != null:
			enemy_level += (entry["variant"] as EnemyVariant).level_bonus
		if encounter_slot != null:
			enemy_level += encounter_slot.level_bonus
		_add_unit(id, BattleUnit.Side.ENEMY, number, entry["definition"], maxi(enemy_level, 1), kit, 1)
		if encounter_slot != null and encounter_slot.brain != null:
			unit_by_id(id).brain_override = encounter_slot.brain
	return ""


## Spec playable-demo 3.8 (H9, H10): the party's held items and armor from the snapshot, in party slot order, then
## each member's items, armor (by slot tag) and use slots. {"holder": grants of holder items, armor and use slots,
## "party": grants of party-wide items, "count": pieces held}. Use abilities are never copied.
func _mirror_of_party(snapshot: Dictionary, content: ContentIndex, skip: Array[StringName] = [], limit: int = 0) -> Dictionary:
	var result := {"holder": [], "party": [], "count": 0}
	var by_slot: Array = snapshot.get("party", []).duplicate()
	by_slot.sort_custom(func(a, b) -> bool: return int(a.get("slot", 0)) < int(b.get("slot", 0)))
	for member in by_slot:
		for item_id in _list(member, "items"):
			var item: ItemDefinition = content.items.get(StringName(str(item_id)))
			if item == null:
				_fail("unknown item '%s'" % item_id)
				return result
			if limit > 0 and result["count"] >= limit:
				continue
			result["count"] += 1
			if item.grants != null and not _carries(item.grants, skip):
				result["party" if item.applies_to == ItemDefinition.AppliesTo.PARTY else "holder"].append({"set": item.grants})
		var gear: Array[EquipmentDefinition] = []
		for equipment_id in _list(member, "equipmentIds"):
			var piece: EquipmentDefinition = content.equipment.get(StringName(str(equipment_id)))
			if piece == null:
				_fail("unknown equipment '%s'" % equipment_id)
				return result
			gear.append(piece)
		gear.sort_custom(func(a, b) -> bool: return String(a.slot) < String(b.slot))
		for piece in gear:
			if limit > 0 and result["count"] >= limit:
				continue
			result["count"] += 1
			if piece.grants != null and not _carries(piece.grants, skip):
				result["holder"].append({"set": piece.grants})
		for use_slot in _list(member, "useSlots"):
			var usable: ItemDefinition = content.items.get(StringName(str(use_slot.get("itemId", ""))))
			if usable == null:
				_fail("unknown item '%s'" % use_slot.get("itemId"))
				return result
			if limit > 0 and result["count"] >= limit:
				continue
			result["count"] += 1
			if usable.grants != null and not _carries(usable.grants, skip):
				result["holder"].append({"set": usable.grants})
	return result


## Spec skill-points D14: true when the set's tags or its effects' granted tags hold one of `tags` or a tag under one.
static func _carries(grants: AbilitySet, tags: Array[StringName]) -> bool:
	if tags.is_empty():
		return false
	var carried: Array[StringName] = grants.tags.duplicate()
	for effect in grants.effects:
		if effect != null:
			carried.append_array(effect.granted_tags)
	for tag in carried:
		for wanted in tags:
			if tag == wanted or String(tag).begins_with(String(wanted) + "."):
				return true
	return false


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
		(unit.asc as CombatASC).tick_started.connect(_on_tick_started.bind(unit))
		(unit.asc as CombatASC).tick_finished.connect(_on_tick_finished.bind(unit))
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
		_trace_point("start")
	while is_running():
		await _ult_window(controller)
		if not is_running():
			break
		while not one_more_queue.is_empty() and not one_more_queue[0].alive:
			one_more_queue.pop_front()
		if not one_more_queue.is_empty():
			await _extra_action(one_more_queue.pop_front(), controller)
			continue
		var actor := turn_manager.next_actor()
		turn_manager.elapse(actor)
		turn += 1
		turn_started.emit(actor.unit_id, turn)

		if actor.asc.has_tag_exact(BROKEN_TAG):
			_recover(actor)
		if actor.asc.has_tag_exact(DOWNED_TAG):
			actor.asc.clear_tag(DOWNED_TAG)
		actor.asc.turn_start()
		# Spec skill-points: a soft enrage. An enemy past its overtime turn grows stronger at each of its turns.
		var enemy_def := actor.definition as EnemyDefinition
		if actor.alive and enemy_def != null and enemy_def.overtime_turn > 0 and turn >= enemy_def.overtime_turn:
			if enemy_def.overtime_effect != null:
				actor.asc.apply_gameplay_effect(enemy_def.overtime_effect, actor.asc, actor.effect_level)
			if enemy_def.overtime_party_effect != null:
				for unit in _units:
					if unit.is_party() and unit.alive:
						unit.asc.apply_gameplay_effect(enemy_def.overtime_party_effect, actor.asc, actor.effect_level)
			BattleLog.line(self, "%s is in overtime" % actor.unit_id)
		actor.asc.send_gameplay_event(EVENT_TURN_START, {"source": actor, "target": actor})
		await _drain_triggers()
		_check_deaths()
		_check_end()

		var action: Dictionary = {}
		if actor.alive and outcome == ONGOING:
			if actor.asc.has_tag_exact(CONTROLLED_TAG):
				# Spec content-pass H1: no decision is asked for (nothing logged); the turn's ticks still run below.
				turn_skipped.emit(actor.unit_id)
				BattleLog.line(self, "%s is controlled: turn skipped" % actor.unit_id)
				actor.asc.send_gameplay_event(EVENT_TURN_SKIPPED, {"source": actor, "target": actor})
			else:
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
			controller.after_party_turn(self, actor, action)
		_trace_point("turn", actor.unit_id, action)

	if runner_error == "":
		final_hash = state_hash()
		_trace_point("end")
	BattleLog.line(self, "ended: %s%s" % [outcome, " (%s)" % runner_error if runner_error != "" else ""])
	for unit in _units:  # playtest-fixes B22: the teardown after this plays no removal cues
		unit.asc.cues_closed = true
	battle_ended.emit(outcome, final_hash)


## Playtest-fixes B22: a battle (a fight or a field battle) is deleted before its units' ability system components, which then
## remove every effect and would play its removal cue; close their cues first. Presentation only.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for unit in _units:
			if unit != null and is_instance_valid(unit.asc):
				unit.asc.cues_closed = true


## Spec item-pass 3.2 (One More): the unit acts again at once, outside the turn order. It gets its own turn number (so
## the log entry is unique), no turn_start/turn_end ticks and no action value change; it can take any action.
func _extra_action(unit: BattleUnit, controller: Object) -> void:
	turn += 1
	extra_action = true
	turn_started.emit(unit.unit_id, turn)
	one_more_started.emit(unit.unit_id)
	unit.asc.begin_extra_action()
	unit.asc.send_gameplay_event(EVENT_ONE_MORE, {"source": unit, "target": unit})
	await _drain_triggers()
	_check_deaths()
	_check_end()
	var action: Dictionary = {}
	if unit.alive and outcome == ONGOING:
		action = await _take_action(unit, controller)
		if is_running() or outcome != ONGOING:
			await _drain_triggers()
	unit.asc.end_extra_action()
	if not is_running() and outcome == ONGOING:
		extra_action = false
		return
	_check_deaths()
	_check_end()
	if outcome == ONGOING and turn >= TURN_LIMIT:
		outcome = TURN_LIMIT_OUTCOME
	if unit.is_party() and not action.is_empty():
		controller.after_party_turn(self, unit, action)
	_trace_point("extra", unit.unit_id, action)
	extra_action = false


## A hit emptied the target's toughness: Broken (a GAS tag content can query), its action delayed, and the unit that
## broke it owed a One More.
func _break(target: BattleUnit, breaker: BattleUnit) -> void:
	target.asc.add_tag(BROKEN_TAG)
	turn_manager.delay(target, BREAK_DELAY)
	if not one_more_queue.has(breaker):
		one_more_queue.append(breaker)
	unit_broken.emit(target.unit_id, breaker.unit_id)


## Spec content-pass H7: a party unit hit on its weakness is Downed and the enemy that hit it is owed a One More.
func _down(target: BattleUnit, attacker: BattleUnit) -> void:
	target.asc.add_tag(DOWNED_TAG)
	if not one_more_queue.has(attacker):
		one_more_queue.append(attacker)
	unit_downed.emit(target.unit_id, attacker.unit_id)


## At a Broken unit's next turn start: toughness back to its maximum (through an instant effect), Broken removed.
func _recover(unit: BattleUnit) -> void:
	var missing := unit.stat(MAX_TOUGHNESS) - unit.stat(TOUGHNESS)
	if missing > 0:
		if _refill_effect == null:
			_refill_effect = GameplayEffect.new()
			_refill_effect.policy = GameplayEffect.DurationPolicy.INSTANT
			var modifier := GameplayEffectModifier.new()
			modifier.attribute_name = TOUGHNESS
			modifier.magnitude_calculation = GameplayEffectModifier.MagnitudeCalculationType.SET_BY_CALLER
			modifier.set_by_caller_tag = ExecutionRow.TOUGHNESS_TAG
			_refill_effect.modifiers.append(modifier)
		var spec := GameplayEffectSpec.new(_refill_effect, GameplayEffectContext.new(unit, unit), unit.effect_level)
		spec.set_set_by_caller_magnitude(ExecutionRow.TOUGHNESS_TAG, float(missing))
		unit.asc.apply_effect_spec(spec)
	unit.asc.clear_tag(BROKEN_TAG)
	unit_recovered.emit(unit.unit_id)


## Units an ability could target, in slot order: living ones, or for the dead-ally modes only dead allies.
func target_candidates(actor: BattleUnit, ability: BattleAbility) -> Array[BattleUnit]:
	var result := _side_candidates(actor, ability)
	# Spec content-pass 2.2 (Taunt): an enemy's single-target or blast ability may only aim at taunting party units
	# while one is alive. (A blast still splashes onto the taunter's neighbours: _expand_targets reads every unit.)
	if not actor.is_party() and ability.targets_enemies() and ability.needs_target():
		var taunting := result.filter(func(unit: BattleUnit) -> bool: return unit.asc.has_tag_exact(TAUNTING_TAG))
		if not taunting.is_empty():
			result.assign(taunting)
	return result


## Living units on the side an ability reaches (or dead allies for the dead-ally modes), in slot order.
func _side_candidates(actor: BattleUnit, ability: BattleAbility) -> Array[BattleUnit]:
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
	if ability.is_ultimate():
		return ["IllegalAbility", "%s is an ult: it is cast out of turn, never as a turn action" % tag]
	if not actor.asc.can_activate_ability(ability):
		return ["IllegalAbility", "%s cannot activate %s now" % [actor.unit_id, tag]]
	return _target_problem(actor, ability, StringName(str(choice.get("target", ""))))


## Checks an ult cast out of turn (spec ult-interrupts). `party`: the caster must be a party unit (log entries and
## presses), otherwise an enemy (brains). Returns [] when legal, else [reason, detail].
func validate_interrupt(caster: BattleUnit, choice: Dictionary, party: bool) -> Array:
	if caster == null or not caster.alive or caster.is_party() != party:
		return ["ActorMismatch", "%s can't cast an ult now (not a living %s unit)" % [choice.get("unit", ""),
			"party" if party else "enemy"]]
	var tag := StringName(str(choice.get("ability", "")))
	var ability := caster.ability_by_tag(tag)
	if ability == null:
		return ["IllegalAbility", "%s has no ability %s" % [caster.unit_id, tag]]
	if not ability.is_ultimate():
		return ["IllegalAbility", "%s is not an ult (Ability.Type.Ultimate), so it can't interrupt" % tag]
	if not caster.asc.can_activate_ability(ability):
		return ["IllegalAbility", "%s cannot activate %s now" % [caster.unit_id, tag]]
	return _target_problem(caster, ability, StringName(str(choice.get("target", ""))))


func _target_problem(actor: BattleUnit, ability: BattleAbility, target_id: StringName) -> Array:
	var tag := ability.ability_tag
	if ability.needs_target():
		var target := unit_by_id(target_id)
		if target == null or not target_candidates(actor, ability).has(target):
			return ["InvalidTarget", "%s is not a valid target for %s" % [target_id, tag]]
	elif target_id != &"":
		return ["InvalidTarget", "%s takes no target, got %s" % [tag, target_id]]
	return []


## Spec ult-interrupts, retargeting: the unit a single-target ult queued for `wanted` hits now: `wanted` if still
## valid, else the candidate nearest to its slot (ties: the lower slot), else null. Only for abilities that need a target.
func retarget(caster: BattleUnit, ability: BattleAbility, wanted: BattleUnit) -> BattleUnit:
	var candidates := target_candidates(caster, ability)
	if candidates.has(wanted):
		return wanted
	if candidates.is_empty():
		return null
	if wanted == null:
		return candidates[0]
	var best: BattleUnit = null
	for candidate in candidates:  # slot order, so the first of two equally near is the lower slot
		if best == null or absi(candidate.slot - wanted.slot) < absi(best.slot - wanted.slot):
			best = candidate
	return best


## Turns a player's ult press into an interrupt choice at the current window (client side, spec ult-interrupts):
## retargets a lost target, then checks it. Returns {"choice": {...}} or {"problem": [reason, detail]}.
func resolve_press(press: Dictionary) -> Dictionary:
	var unit_id := StringName(str(press.get("unit", "")))
	var caster := unit_by_id(unit_id)
	var choice := {"interrupt": true, "unit": unit_id, "ability": StringName(str(press.get("ability", ""))),
		"target": StringName(str(press.get("target", "")))}
	var ability := caster.ability_by_tag(choice["ability"]) if caster != null else null
	if ability != null and ability.needs_target():
		var target := retarget(caster, ability, unit_by_id(choice["target"]))
		if target == null:
			return {"problem": ["InvalidTarget", "no valid target left for %s" % choice["ability"]]}
		choice["target"] = target.unit_id
	var problem := validate_interrupt(caster, choice, true)
	return {"problem": problem} if not problem.is_empty() else {"choice": choice}


## Spec ult-interrupts, BETWEEN window (after an action, before the next turn or One More): first each living enemy
## in slot order may cast one ult (its brain decides from battle state, so replay re-simulates it; never logged), then
## the controller's party interrupts, one after another, until it has none.
func _ult_window(controller: Object) -> void:
	var enemies: Array[BattleUnit] = []
	for unit in _units:
		if not unit.is_party() and not unit.ultimate_abilities().is_empty():
			enemies.append(unit)
	enemies.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)
	for enemy in enemies:
		if not is_running():
			return
		if not enemy.alive:
			continue
		var choice := _brain_of(enemy).choose_interrupt(enemy, self)
		if StringName(str(choice.get("ability", ""))) == &"":
			continue
		var problem := validate_interrupt(enemy, choice, false)
		if not problem.is_empty():
			_fail("enemy brain chose an illegal interrupt: " + problem[1])
			return
		await _interrupt(enemy, choice, controller)
	if not controller.has_method("interrupt"):
		return
	while is_running():
		var choice: Dictionary = controller.interrupt(self)
		if choice.is_empty():
			return
		if not await _party_interrupt(choice, controller):
			return


## A party interrupt from the controller (either window): checked, then cast. False when the battle stopped.
func _party_interrupt(choice: Dictionary, controller: Object) -> bool:
	var caster := unit_by_id(StringName(str(choice.get("unit", ""))))
	var problem := validate_interrupt(caster, choice, true)
	if not problem.is_empty():
		if caster == null or not controller.on_invalid(self, caster, problem[0], problem[1]):
			reject(problem[0], problem[1])
			return false
		return true
	await _interrupt(caster, choice, controller)
	return runner_error == "" and mismatch.is_empty()


## Casts an ult out of turn: no turn number, no turn ticks, no action value change. A break it causes queues a One
## More as any action does. A party cast is logged ("interrupt": true).
func _interrupt(caster: BattleUnit, choice: Dictionary, controller: Object) -> void:
	var ability := caster.ability_by_tag(StringName(str(choice["ability"])))
	var target_id := StringName(str(choice.get("target", "")))
	in_interrupt = true
	interrupt_started.emit(caster.unit_id, ability.ability_tag)
	var activated := await _activate(caster, ability, unit_by_id(target_id))
	if not activated:
		in_interrupt = false
		if caster.is_party():
			reject("IllegalAbility", "%s failed to activate" % ability.ability_tag)
		else:
			_fail("enemy ult %s failed to activate" % ability.ability_tag)
		return
	caster.asc.send_gameplay_event(EVENT_BATTLE_INTERRUPT, {"source": caster, "target": caster,
		"ability": ability.ability_tag})
	await _drain_triggers()
	_check_deaths()
	_check_end()
	in_interrupt = false
	if caster.is_party() and runner_error == "" and mismatch.is_empty():
		controller.after_interrupt(self, caster, {"ability": ability.ability_tag, "target": target_id})
	if runner_error == "" and mismatch.is_empty():
		_trace_point("interrupt", caster.unit_id, {"ability": ability.ability_tag, "target": target_id})


## A dev decision (spec dev-tools 3.6): its GameplayEffect on the chosen living units through GAS, then the usual
## trigger, death and end handling. Logged as an ordinary action entry ({"ability": Dev.*, "target": targets}); it
## doesn't use up the actor's turn.
func _apply_dev(actor: BattleUnit, choice: Dictionary, controller: Object) -> void:
	var targets := str(choice.get("targets", "enemies"))
	var ids: Array[StringName] = []
	for unit in _units:
		if not unit.alive:
			continue
		if (targets == "enemies" and not unit.is_party()) or (targets == "party" and unit.is_party()) \
				or (targets.is_valid_int() and unit.unit_id == StringName("P" + targets)):
			ids.append(unit.unit_id)
	if choice.get("effect") is GameplayEffect:
		apply_to_units(choice["effect"], ids)
	await _drain_triggers()
	_check_deaths()
	_check_end()
	controller.after_party_turn(self, actor, {"ability": StringName(str(choice["dev"])), "target": StringName(targets)})
	_trace_point("dev", actor.unit_id, {"ability": StringName(str(choice["dev"])), "target": StringName(targets)})


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
		var toughness_before := target.stat(TOUGHNESS)
		# One spec per target: turn-based effects keep their spec, so sharing one would share the countdown.
		var context := GameplayEffectContext.new(unit, unit)
		context.target_data.append_node(target)
		var spec := GameplayEffectSpec.new(row.effect, context, ability.ability_level)
		row.apply_override(spec)
		if ability.is_follow_up():
			spec.inject_tag(HIT_FOLLOW_UP)
		hit_ids.append(target.unit_id)
		if not _status_lands(unit, target, row):
			continue
		_extend_debuff(unit, row, spec)
		_row_targets[target.unit_id] = int(_row_targets.get(target.unit_id, 0)) + 1
		var landed := unit.asc.apply_effect_spec_to_target(spec, target.asc)
		_row_targets[target.unit_id] -= 1
		if _row_targets[target.unit_id] <= 0:
			_row_targets.erase(target.unit_id)
		# Spec content-pass H6: a landed row with a delay moves the target's action value (negative = advance).
		if landed != null and row.delay_x100 != 0 and not field_mode and target.is_up():
			turn_manager.delay(target, row.delay_x100)
			action_delayed.emit(target.unit_id, row.delay_x100)
		# A break needs the target to survive the hit (a killing blow is just a kill). Party units never break (H7).
		if toughness_before > 0 and target.stat(TOUGHNESS) <= 0 and target.stat(BattleUnit.HP) > 0 \
				and not target.asc.has_tag_exact(BROKEN_TAG) and not field_mode and not target.is_party():
			_break(target, unit)
			spec.inject_tag(HIT_BREAK)
		if target.is_party() and not unit.is_party() and spec.dynamic_tags.has(HIT_WEAKNESS) \
				and target.stat(BattleUnit.HP) > 0 and not target.asc.has_tag_exact(DOWNED_TAG) and not field_mode:
			_down(target, unit)
		var damage := hp_before - target.stat(BattleUnit.HP)
		if spec.dynamic_tags.has(HIT_DRAINED):
			_send_drain_events(unit, target, -damage, row, spec)
		elif damage > 0:
			_send_damage_events(unit, target, damage, row, spec)
	execution_resolved.emit(unit.unit_id, row.id, hit_ids)
	if schema_version >= 2:
		_check_revives()


## Spec content-pass H2 / D13: whether a row's status lands on `target`. A row without a chance, or with 100% or more,
## always lands and draws nothing; below 100% it takes one battle-RNG roll. An effect whose application_query refuses
## the target (immunity) draws nothing either (GodotGAS then refuses it). A miss sends Event.Status.Resisted to both units.
func _status_lands(source: BattleUnit, target: BattleUnit, row: ExecutionRow) -> bool:
	# Field mode never rolls: run-level randomness comes from RunSeeds streams only (client-godot/CLAUDE.md 3).
	if row.chance_x100 <= 0 or row.chance_x100 >= Fixed.ONE_HUNDRED_PERCENT or field_mode:
		return true
	if row.effect.application_query != null and not row.effect.application_query.matches(target.asc):
		return true
	if rng.randi_range(0, 9999) < row.chance_x100:
		return true
	var payload := {"source": source, "target": target, "row": row.id, "tags": row.tags,
		"effect": row.effect.resource_path}
	source.asc.send_gameplay_event(EVENT_STATUS_RESISTED, payload)
	if target != source:
		target.asc.send_gameplay_event(EVENT_STATUS_RESISTED, payload)
	status_resisted.emit(source.unit_id, target.unit_id, row.effect.resource_path)
	return false


## Spec content-pass H8: a turn-based debuff applied by a row lasts the source's debuff_turns more turns (whole turns
## only). Set on the spec before it lands, so a GodotGAS refresh copies the longer count.
@warning_ignore("integer_division")
func _extend_debuff(source: BattleUnit, row: ExecutionRow, spec: GameplayEffectSpec) -> void:
	if field_mode or row.effect.policy != GameplayEffect.DurationPolicy.TURN_BASED or not row.applies_debuff():
		return
	var extra := source.stat(DEBUFF_TURNS) / 100
	if extra > 0:
		spec.remaining_turns += extra


## Spec content-pass 2.4: a drained hit healed its target by `amount`. Only Event.Damage.Dealt.Drained (source) and
## Event.Damage.Taken.Drained (target): the plain Dealt/Taken events need damage, so "when hit" passives stay silent.
func _send_drain_events(source: BattleUnit, target: BattleUnit, amount: int, row: ExecutionRow,
		spec: GameplayEffectSpec) -> void:
	var payload := {"source": source, "target": target, "amount": amount, "row": row.id, "tags": row.tags,
		"hit_tags": Battle.hit_tags_of(spec)}
	source.asc.send_gameplay_event(StringName("%s.Drained" % EVENT_DAMAGE_DEALT), payload)
	target.asc.send_gameplay_event(StringName("%s.Drained" % EVENT_DAMAGE_TAKEN), payload)
	var tags: Array[StringName] = [HIT_DRAINED]
	for damage_type in row.damage_types():
		tags.append(StringName(DAMAGE_TYPE_PREFIX + damage_type))
	damage_drained.emit(source.unit_id, target.unit_id, amount, tags)


## Event.Damage.Dealt (source) and Event.Damage.Taken (target), plus .<X> for each Damage.Type.<X> row tag, then
## .<X> for each Hit.<X> tag on the spec (sorted), then (a breaking hit) .Break.<X> per damage type. Only queues
## triggers; they run when the battle drains the queue.
func _send_damage_events(source: BattleUnit, target: BattleUnit, damage: int, row: ExecutionRow,
		spec: GameplayEffectSpec) -> void:
	var hit_tags := Battle.hit_tags_of(spec)
	var payload := {"source": source, "target": target, "amount": damage, "row": row.id, "tags": row.tags,
		"hit_tags": hit_tags}
	source.asc.send_gameplay_event(EVENT_DAMAGE_DEALT, payload)
	target.asc.send_gameplay_event(EVENT_DAMAGE_TAKEN, payload)
	for tag in row.tags:
		if String(tag).begins_with(DAMAGE_TYPE_PREFIX):
			var damage_type := String(tag).trim_prefix(DAMAGE_TYPE_PREFIX)
			source.asc.send_gameplay_event(StringName("%s.%s" % [EVENT_DAMAGE_DEALT, damage_type]), payload)
			target.asc.send_gameplay_event(StringName("%s.%s" % [EVENT_DAMAGE_TAKEN, damage_type]), payload)
	for tag in hit_tags:
		var hit_kind := String(tag).trim_prefix(HIT_TAG_PREFIX)
		source.asc.send_gameplay_event(StringName("%s.%s" % [EVENT_DAMAGE_DEALT, hit_kind]), payload)
		target.asc.send_gameplay_event(StringName("%s.%s" % [EVENT_DAMAGE_TAKEN, hit_kind]), payload)
	# Spec content-pass H4: per-type break effects listen to Event.Damage.Dealt.Break.<DamageType>.
	if hit_tags.has(HIT_BREAK):
		for damage_type in row.damage_types():
			source.asc.send_gameplay_event(StringName("%s.Break.%s" % [EVENT_DAMAGE_DEALT, damage_type]), payload)
			target.asc.send_gameplay_event(StringName("%s.Break.%s" % [EVENT_DAMAGE_TAKEN, damage_type]), payload)
	var signal_tags: Array[StringName] = []
	signal_tags.assign(hit_tags)
	for damage_type in row.damage_types():
		signal_tags.append(StringName(DAMAGE_TYPE_PREFIX + damage_type))
	damage_dealt.emit(source.unit_id, target.unit_id, damage, signal_tags)


## The spec's Hit.* tags in sorted order (the order their events are sent in).
static func hit_tags_of(spec: GameplayEffectSpec) -> Array[StringName]:
	var result: Array[StringName] = []
	for tag in spec.dynamic_tags:
		if String(tag).begins_with(HIT_TAG_PREFIX):
			result.append(tag)
	result.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return result


## Spec atomic-battles: one trace point (kind start, turn, extra, interrupt, dev or end), only when a trace is attached.
## A hashing error there is a runner error, as it would be at the final hash.
func _trace_point(kind: String, actor: StringName = &"", action: Dictionary = {}) -> void:
	if trace == null:
		return
	var problem := trace.point(self, kind, actor, StringName(str(action.get("ability", ""))),
		StringName(str(action.get("target", ""))))
	if problem != "":
		_fail(problem)


## State hash v1 of the current state. Sets runner_error when the state can't be hashed.
func state_hash() -> String:
	var result := StateHasher.compute(self)
	if result["error"] != "":
		_fail(result["error"])
	return result["hash"]


## An enemy's brain: its encounter slot's override, else its definition's, else the default (spec playable-demo 3.7).
static func _brain_of(unit: BattleUnit) -> EnemyBrain:
	if unit.brain_override != null:
		return unit.brain_override
	return unit.definition.brain if unit.definition.brain != null else EnemyBrain.new()


func _take_action(actor: BattleUnit, controller: Object) -> Dictionary:
	var choice: Dictionary
	if actor.is_party():
		while true:
			choice = await controller.choose(self, actor)
			if not is_running():
				return {}
			# Spec ult-interrupts, DECISION window: any living party member's ult fires now; the turn isn't spent.
			if bool(choice.get("interrupt", false)):
				if not await _party_interrupt(choice, controller):
					return {}
				if not is_running() or not actor.alive:
					return {}
				continue
			if choice.has("dev") and allow_dev:
				await _apply_dev(actor, choice, controller)
				if not is_running():
					return {}
				continue
			var problem := validate_action(actor, choice)
			if problem.is_empty():
				break
			if not controller.on_invalid(self, actor, problem[0], problem[1]):
				reject(problem[0], problem[1])
				return {}
	else:
		choice = _brain_of(actor).choose(actor, self)
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
	# Before activation, so the feed's "X used Y" comes before the hits it causes (activation awaits the animation).
	if actor.asc.can_activate_ability(ability):
		ability_activated.emit(actor.unit_id, tag, target.unit_id if target != null else &"")
	var activated: bool = await ability.try_activate(payload)
	BattleLog.line(self, "%s %s -> %s%s" % [actor.unit_id, tag, target.unit_id if target != null else "-",
		"" if activated else " (refused)"])
	if activated and not field_mode:
		var used := {"source": actor, "target": actor, "ability": tag}
		actor.asc.send_gameplay_event(EVENT_ABILITY_USED, used)
		# Spec content-pass H4: Event.Ability.Used.<X> per Ability.Type.<X> asset tag (sorted), e.g. Used.Ultimate.
		var types: Array[String] = []
		for asset_tag in ability.asset_tags:
			if String(asset_tag).begins_with(ABILITY_TYPE_PREFIX):
				types.append(String(asset_tag).trim_prefix(ABILITY_TYPE_PREFIX))
		types.sort()
		for type in types:
			actor.asc.send_gameplay_event(StringName("%s.%s" % [EVENT_ABILITY_USED, type]), used)
	if activated and actor.item_abilities.has(tag):
		used_items.append({"unit": actor.unit_id, "item": actor.item_abilities[tag]})
		actor.item_abilities.erase(tag)
		actor.revoke_ability(ability)
	return activated


## Field mode: applies one effect to each listed unit (event outcomes such as heals or revives), then settles deaths
## and revives. Effects come from content .tres files, never built in code.
func apply_to_units(effect: GameplayEffect, unit_ids: Array[StringName]) -> void:
	_field_cues(true)
	for id in unit_ids:
		var unit := unit_by_id(id)
		if unit != null:
			unit.asc.apply_gameplay_effect(effect, unit.asc, unit.effect_level)
	_check_revives()
	_check_deaths()
	_field_cues(false)


## Playtest-fixes B22: a field battle's cues are open only while it carries out an explicit action (perform, apply_to_units),
## so a heal on the map still shows and the bookkeeping around it does not. Fights are untouched.
func _field_cues(open: bool) -> void:
	if not field_mode:
		return
	for unit in _units:
		unit.asc.cues_closed = not open


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
	_field_cues(true)
	var activated := await _activate(actor, ability, unit_by_id(target_id))
	if not activated:
		_field_cues(false)
		return ["IllegalAbility", "%s failed to activate" % ability_tag]
	await _drain_triggers()
	_check_revives()
	_check_deaths()
	_field_cues(false)
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
			for candidate in _side_candidates(actor, ability):
				if absi(candidate.slot - target.slot) <= 1:
					targets.append(candidate)
		BattleAbility.Targeting.ALL_ENEMIES, BattleAbility.Targeting.ALL_ALLIES:
			targets = target_candidates(actor, ability)
		BattleAbility.Targeting.SELF:
			primary = actor
			targets.append(actor)
	return {"primary": primary, "targets": targets}


## `effect_level` -1: the same as `level` (spec skill-points D21; enemies pass 1).
func _add_unit(id: StringName, side: BattleUnit.Side, slot: int, definition: UnitDefinition, level: int,
		kit: Dictionary = {}, effect_level: int = -1) -> void:
	_units.append(BattleUnit.create(self, id, side, slot, definition, level, kit, effect_level))


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
			var killer := _killer_of(dead)
			for unit in _units:
				if unit.alive:
					unit.asc.send_gameplay_event(EVENT_UNIT_DIED, {"source": dead, "target": dead, "instigator": killer})
		# Spec item-pass 3.1: then each living killer gets Event.Unit.Killed, in unit order.
		for dead in died:
			var killer := _killer_of(dead)
			if killer != null and killer.alive:
				killer.asc.send_gameplay_event(EVENT_UNIT_KILLED, {"source": killer, "target": dead})
	_check_phases()


## Spec content-pass H5: each living enemy with boss phases enters every phase whose threshold its HP is now below, in
## order, once each (after deaths, so a killing blow starts no phase). Triggers queued here run at the next drain.
func _check_phases() -> void:
	if field_mode:
		return
	for unit in _units:
		var enemy := unit.definition as EnemyDefinition
		if enemy == null or enemy.phases.is_empty() or not unit.alive:
			continue
		while unit.phase_index < enemy.phases.size():
			var phase: BossPhase = enemy.phases[unit.phase_index]
			if phase == null or not phase.reached(unit.stat(BattleUnit.HP), unit.stat(BattleUnit.MAX_HP)):
				break
			unit.phase_index += 1
			if phase.clear_debuffs:
				unit.asc.remove_effects_with_tag(DEBUFF_TAG)
			if phase.ability_set != null:
				unit.grant_set(phase.ability_set)
			phase_changed.emit(unit.unit_id, unit.phase_index)
			unit.asc.send_gameplay_event(EVENT_PHASE_CHANGED, {"source": unit, "target": unit, "phase": unit.phase_index})


## The unit whose effect last lowered `dead`'s HP, or null (none, or the unit itself, e.g. a dev kill).
static func _killer_of(dead: BattleUnit) -> BattleUnit:
	var killer := dead.last_hit_by
	return killer if killer != null and killer != dead else null


## v2 death: State.Dead, and temporary effects (buffs, debuffs, DoTs) are dropped. Infinite effects from items and
## equipment stay, so a revived unit has them again.
func _lay_down(unit: BattleUnit) -> void:
	for i in range(unit.asc._active_effects.size() - 1, -1, -1):
		var active_effect: ActiveGameplayEffect = unit.asc._active_effects[i]
		if active_effect.get_effect_def().policy != GameplayEffect.DurationPolicy.INFINITE:
			unit.asc.remove_active_effect(active_effect)
	if not unit.asc.has_tag_exact(BattleUnit.DEAD_TAG):
		unit.asc.add_tag(BattleUnit.DEAD_TAG)
	unit.asc.clear_tag(BROKEN_TAG)
	unit.asc.clear_tag(DOWNED_TAG)


## v2: a dead unit whose HP an effect raised above 0 comes back, with a fresh action value.
func _check_revives() -> void:
	for unit in _units:
		if not unit.alive and unit.stat(BattleUnit.HP) > 0:
			unit.alive = true
			unit.last_hit_by = null
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
		# Spec item-pass 3.1 (HSR): a follow-up never fires from a follow-up's own hit, so follow-ups can't feed each other.
		if ability.is_follow_up() and entry["payload"] is Dictionary \
				and Array(entry["payload"].get("hit_tags", [])).has(HIT_FOLLOW_UP):
			continue
		var target := _trigger_target(unit, ability, entry["payload"])
		if ability.needs_target() and target == null:
			continue
		var payload := _expand_targets(unit, ability, target)
		payload["battle"] = self
		payload["unit"] = unit
		payload["event"] = entry["payload"]
		var activated: bool = await ability.try_activate(payload)
		BattleLog.line(self, "  trigger %s %s on %s%s" % [unit.unit_id, ability.ability_tag, entry["event_tag"],
			"" if activated else " (did not activate)"])
		if not activated:
			continue
		trigger_activated.emit(unit.unit_id, ability.ability_tag, StringName(entry["event_tag"]))
		if ability.is_follow_up():
			var aimed: BattleUnit = payload["primary"] if payload["primary"] != null else unit
			unit.asc.send_gameplay_event(EVENT_ATTACK_FOLLOW_UP, {"source": unit, "target": aimed, "ability": ability.ability_tag})
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


func _on_attribute_changed(attribute_name: String, old_value: float, new_value: float, spec: GameplayEffectSpec,
		unit: BattleUnit) -> void:
	if attribute_name == BattleUnit.SPD:
		turn_manager.on_spd_changed(unit, old_value, new_value)
	elif attribute_name == BattleUnit.HP and new_value < old_value and spec != null and spec.context != null:
		# The unit itself counts too (a dev kill, an HP cost), so an earlier attacker isn't credited with that death.
		unit.last_hit_by = spec.context.instigator as BattleUnit
	if attribute_name == BattleUnit.HP and not field_mode and new_value != old_value \
			and not (new_value < old_value and _row_targets.has(unit.unit_id)):
		var cause := _status_tags_of(spec)
		if _tick_open.has(unit.unit_id):
			# Inside a periodic tick: the stacks are one event, reported once when the tick ends.
			_tick_open[unit.unit_id]["sum"] += int(new_value - old_value)
			_tick_open[unit.unit_id]["cause"] = cause
		else:
			hp_changed.emit(unit.unit_id, int(new_value - old_value), cause)


func _status_tags_of(spec: GameplayEffectSpec) -> Array[StringName]:
	var cause: Array[StringName] = []
	if spec != null and spec.effect_def != null:
		for tag in spec.effect_def.granted_tags:
			if String(tag).begins_with("Status."):
				cause.append(tag)
	return cause


func _on_tick_started(effect: GameplayEffect, unit: BattleUnit) -> void:
	_tick_open[unit.unit_id] = {"sum": 0, "cause": _status_tags_of_effect(effect)}


func _on_tick_finished(_effect: GameplayEffect, unit: BattleUnit) -> void:
	var tick: Dictionary = _tick_open.get(unit.unit_id, {})
	_tick_open.erase(unit.unit_id)
	if int(tick.get("sum", 0)) != 0 and not field_mode:
		hp_changed.emit(unit.unit_id, int(tick["sum"]), tick["cause"])


func _status_tags_of_effect(effect: GameplayEffect) -> Array[StringName]:
	var cause: Array[StringName] = []
	if effect != null:
		for tag in effect.granted_tags:
			if String(tag).begins_with("Status."):
				cause.append(tag)
	return cause


func _fail(message: String) -> String:
	if runner_error == "":
		runner_error = message
	return runner_error
