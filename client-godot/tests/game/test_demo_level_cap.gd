## Spec level-cap, content test on res://content/: every demo class's kit at each of its learn levels up to 50 (ranks replace, the
## new moves can be cast and their rows land), the taper, the 49-threshold curve and enemy levels that rise with the party's.
extends TestCase

const CONTENT: String = "res://content/"
const DESCENT: StringName = &"demo.run.descent"

static var _demo_index: ContentIndex


func _demo() -> ContentIndex:
	if _demo_index == null:
		_demo_index = ContentIndex.new(CONTENT)
	return _demo_index if _demo_index.runs.has(DESCENT) else null


func _classes(content: ContentIndex) -> Array:
	return content.characters.values().filter(func(character: CharacterDefinition) -> bool:
		return String(character.id).begins_with("demo.character.") and not character.growth_bands.is_empty())


func _skip(content: ContentIndex) -> bool:
	if content == null or _classes(content).is_empty():
		print("    skipped: no demo class has growth bands")
		return true
	return false


func _battle(content: ContentIndex, character: StringName, level: int) -> Battle:
	var golem := [{"slot": 1, "unitDefId": "demo.enemy.golem", "loadoutRef": null, "variantId": null},
		{"slot": 2, "unitDefId": "demo.enemy.golem", "loadoutRef": null, "variantId": null}]
	var party := []
	for id in [String(character), "demo.character.cleric"]:
		party.append({"slot": party.size() + 1, "unitDefId": id, "level": level, "skills": [], "equipmentIds": [], "items": [],
			"useSlots": []})
	var battle := Battle.new()
	host.add_child(battle)
	eq(battle.setup({"schemaVersion": 2, "battleId": "demo-level-cap", "seed": "3", "encounterId": "demo.encounter.golem",
		"party": party, "enemies": golem, "scalingId": "demo.scaling.descent", "depth": 9}, content), "",
		"%s builds at level %d" % [character, level])
	return battle


func test_every_class_learns_to_the_cap() -> void:
	var content := _demo()
	if _skip(content):
		return
	for character: CharacterDefinition in _classes(content):
		var levels := character.level_skills.map(func(row: LevelSkill) -> int: return row.level)
		eq(levels.max(), 50, "%s learns up to 50" % character.id)
		var passives := 0
		var actives := 0
		for row in character.level_skills:
			if row.level >= 12:
				var ability := row.ability.instantiate() as BattleAbility
				passives += 1 if ability.is_triggered() else 0
				actives += 0 if ability.is_triggered() else 1
				check(ability.description != "", "%s describes itself" % ability.ability_tag)
				ability.free()
		check(passives >= 3 and actives >= 3, "%s: 3 or more passives and actives from 12 (%d, %d)" % [character.id, passives, actives])
		var battle := _battle(content, character.id, 50)
		var unit := battle.unit_by_id(&"P1")
		var learned := character.level_skills_at(50)
		for row in character.level_skills:
			var tag := SkillTags.tag_of(row.ability)
			eq(unit.ability_by_tag(tag) != null, not learned["replaced"].has(tag), "%s at 50: %s" % [character.id, tag])
		battle.free()


## Every action learned from 12 on can be cast at its level with a full bar (a revive is not cast: nobody is dead), and every new
## ability's rows, passives too, are fired by its animation.
func test_the_new_actions_can_be_cast() -> void:
	var content := _demo()
	if _skip(content):
		return
	for character: CharacterDefinition in _classes(content):
		for row in character.level_skills:
			if row.level < 12:
				continue
			var battle := _battle(content, character.id, row.level)
			var unit := battle.unit_by_id(&"P1")
			var ability := unit.ability_by_tag(SkillTags.tag_of(row.ability))
			var keys: Array = ExecutionReader.sequence_for(ability.animation) if ability.animation != null else []
			for execution in ability.executions:
				check(keys.has(execution.id), "%s: its animation fires %s" % [ability.ability_tag, execution.id])
			if not ability.is_triggered() and not ability.targets_dead():
				check(CostReader.sp_cost(ability, unit.asc) <= unit.stat("max_mp"),
					"%s: a full SP bar pays it at level %d" % [ability.ability_tag, row.level])
				var energy := GameplayEffect.new()
				energy.policy = GameplayEffect.DurationPolicy.INSTANT
				var fill := CombatModifier.new()
				fill.attribute_name = "energy"
				fill.value_x100 = unit.stat("max_energy")
				energy.modifiers.append(fill)
				unit.asc.apply_gameplay_effect(energy, unit.asc, 1)
				var query := ability.activation_query
				if query == null or (query.require_any_tags.is_empty() and query.require_all_tags.is_empty() and query.require_exact_tags.is_empty()):
					var target := battle.unit_by_id(&"E1" if ability.targets_enemies() else &"P1")
					check(await battle._activate(unit, ability, target), "%s can be cast at level %d" % [ability.ability_tag, row.level])
					await battle._drain_triggers()
			battle.free()


## Every passive learned from 12 on fires on its own trigger at its level and changes the battle: the event is sent with the
## payload the battle itself sends (a DoT tick from a real Burn, an ally's or the own ult, a skill, a hit), a death goes through
## the death check, the tags its activation query requires are granted first, a chance passive is made certain, and the unit
## starts at half HP and no SP so a heal or a restore shows.
func test_the_new_passives_fire() -> void:
	var content := _demo()
	if _skip(content):
		return
	var burn: GameplayEffect = load("res://content/demo/effects/burn.tres")
	var tested := 0
	for character: CharacterDefinition in _classes(content):
		for row in character.level_skills:
			if row.level < 12:
				continue
			var battle := _battle(content, character.id, row.level)
			var unit := battle.unit_by_id(&"P1")
			var ability := unit.ability_by_tag(SkillTags.tag_of(row.ability))
			if not ability.is_triggered():
				battle.free()
				continue
			var fired := []
			battle.trigger_activated.connect(func(unit_id: StringName, tag: StringName, _event: StringName) -> void:
				if unit_id == &"P1":
					fired.append(tag))
			var query := ability.activation_query
			if query != null and not query.require_all_tags.is_empty():
				var grant := GameplayEffect.new()
				grant.policy = GameplayEffect.DurationPolicy.INFINITE
				grant.granted_tags.assign(query.require_all_tags)
				unit.asc.apply_gameplay_effect(grant, unit.asc, 1)
			ability.trigger_chance_x100 = 0  # this battle's copy only: a chance passive fires every time (0 = always)
			var half: Dictionary[String, float] = {"hp": float(unit.stat("max_hp") / 2), "mp": 0.0}  # room for a heal or SP to show
			unit.asc.initialize_attribute_overrides(half)
			battle.unit_by_id(&"P2").asc.initialize_attribute_overrides({"hp": float(battle.unit_by_id(&"P2").stat("max_hp") / 2)}
				as Dictionary[String, float])  # and the ally, for a heal on the one that was hit
			var before := battle.state_hash()
			var event := ability.trigger_event_tag
			if event == Battle.EVENT_UNIT_DYING:
				unit.asc.initialize_attribute_overrides({"hp": 0.0} as Dictionary[String, float])
				await battle._settle_deaths()
				check(unit.alive, "%s: saved" % ability.ability_tag)
			else:
				var payload := _trigger_payload(battle, unit, event, burn)
				unit.asc.send_gameplay_event(event, payload)
			await battle._drain_triggers()
			check(fired.has(ability.ability_tag), "%s fires on %s at level %d" % [ability.ability_tag, event, row.level])
			check(battle.state_hash() != before, "%s changes the battle" % ability.ability_tag)
			tested += 1
			battle.free()
	check(tested >= 3 * _classes(content).size(), "every class's new passives were fired (%d)" % tested)
	print("    %d passives fired" % tested)


## What the battle sends with `event` to P1 (spec item-power payloads), against E1 and with the Cleric as the ally.
static func _trigger_payload(battle: Battle, unit: BattleUnit, event: StringName, burn: GameplayEffect) -> Dictionary:
	var enemy := battle.unit_by_id(&"E1")
	var ally := battle.unit_by_id(&"P2")
	var text := String(event)
	if text.begins_with("Event.Ally.Ability.Used") or text.begins_with("Event.Ability.Used"):
		var caster := ally if text.begins_with("Event.Ally.") else unit
		var used: BattleAbility = null
		for candidate in caster.abilities():
			var fits := candidate.is_ultimate() if text.ends_with(".Ultimate") \
				else (not candidate.is_triggered() and not candidate.targets_dead() and Battle._is_skill(caster, candidate))
			if fits and used == null and (not candidate.needs_target() or not battle.target_candidates(caster, candidate).is_empty()):
				used = candidate  # never a revive with nobody dead
		var candidates := battle.target_candidates(caster, used)
		var aimed := battle._expand_targets(caster, used, candidates[0] if used.needs_target() else null)
		return {"source": caster, "target": caster, "ability": used.ability_tag, "primary": aimed["primary"],
			"targets": aimed["targets"]}
	if text.begins_with("Event.Damage.Dealt.Dot"):
		var active := enemy.asc.apply_gameplay_effect(burn, unit.asc, 1)
		return {"source": unit, "target": enemy, "amount": 1000, "effect": burn, "spec": active.spec, "turns": 1}
	if text.begins_with("Event.Damage.Taken") or text.begins_with("Event.Ally.Damage.Taken"):
		var hit := ally if text.begins_with("Event.Ally.") else unit
		return {"source": enemy, "target": hit, "amount": 1000, "row": &"hit", "tags": [], "hit_tags": []}
	if text.begins_with("Event.Damage.Dealt"):
		var tags: Array[StringName] = []
		var hit_tags: Array[StringName] = []
		var kind := text.trim_prefix("Event.Damage.Dealt").trim_prefix(".").trim_prefix("Break").trim_prefix(".")
		if kind in ["Weakness", "Critical"]:
			hit_tags.append(StringName("Hit." + kind))
		elif kind != "":
			tags.append(StringName("Damage.Type." + kind))
		return {"source": unit, "target": enemy, "amount": 1000, "row": &"hit", "tags": tags, "hit_tags": hit_tags}
	if event in [Battle.EVENT_BATTLE_START, Battle.EVENT_TURN_START]:
		return {"source": unit, "target": unit}
	return {"source": unit, "target": enemy}  # Unit.Killed, Status.Resisted, Attack.FollowUp


## A rank keeps the place of the ult it replaced, so the chooser never reorders on a level-up.
func test_ult_ranks_keep_their_place() -> void:
	var content := _demo()
	if _skip(content):
		return
	for pair in [[&"demo.character.warrior", ["Cleave", "Execute"]], [&"demo.character.cleric", ["Sanctuary", "Resurrection"]]]:
		for level in [1, 15, 16, 22, 24, 50]:
			var battle := _battle(content, pair[0], level)
			var names := battle.unit_by_id(&"P1").ultimate_abilities().map(func(ult: BattleAbility) -> String:
				return String(ult.ability_tag).trim_prefix("Ability.Ult.").rstrip("23"))
			eq(names, pair[1], "%s at level %d" % [pair[0], level])
			battle.free()


func test_growth_tapers_and_stays_small() -> void:
	var content := _demo()
	if _skip(content):
		return
	for character: CharacterDefinition in _classes(content):
		var stats := {}
		for level in [1, 15, 30, 50]:
			var battle := _battle(content, character.id, level)
			var unit := battle.unit_by_id(&"P1")
			stats[level] = unit.stat("max_hp")
			for attribute_name in StateHasher._attribute_names(unit.asc):
				var value: float = unit.asc.get_attribute(attribute_name).current_value
				check(Fixed.is_whole(value) and absf(value) < 100000000.0,
					"%s level %d: %s stays small (%s)" % [character.id, level, attribute_name, value])
			battle.free()
		check(stats[15] - stats[1] > stats[30] - stats[15] and stats[30] - stats[15] > stats[50] - stats[30],
			"%s: each band gives less than the one before (%s)" % [character.id, stats])


func test_the_descent_curve() -> void:
	var content := _demo()
	if _skip(content):
		return
	var structure: RunStructure = content.runs[DESCENT]
	eq(structure.xp_to_level.size(), 49, "a cap of 50")
	var rules: ScalingRules = content.scaling[&"demo.scaling.descent"]
	for depth in range(1, structure.floors.size()):
		check(rules.level_for_depth(depth) >= rules.level_for_depth(depth - 1), "enemy levels rise with depth (floor %d)" % (depth + 1))
