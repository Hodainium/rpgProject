## Builds the frozen fixture content under res://tests/fixtures/ (system-owned, never references res://content/).
## Run once, then commit the output; regenerating changes resource uids, so only rerun when fixtures must change:
##   godot --headless --path client-godot res://tests/tools/build_fixtures.tscn
## Values are typed as designers would (Fixed.from_typed converts them ×100), to exercise the authoring format.
extends Node

const ROOT := "res://tests/fixtures/"
const DAMAGE_SCRIPT := preload("res://tests/fixtures/exec_calcs/fixture_damage.gd")
const SLEEPY_SCRIPT := preload("res://tests/fixtures/abilities/sleepy_ability.gd")
const ATTRIBUTE_SET := preload("res://tests/fixtures/attributes/fixture_attribute_set.gd")

var _effects := {}
var _abilities := {}
var _units := {}


func _ready() -> void:
	for directory in ["effects", "animations", "abilities", "units", "encounters"]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + directory))
	_build_effects()
	_build_abilities()
	_build_units()
	_build_encounters()
	print("Fixtures built under ", ROOT)
	get_tree().quit(0)


func _build_effects() -> void:
	var damage := GameplayEffect.new()
	damage.policy = GameplayEffect.DurationPolicy.INSTANT
	damage.executions.append(DAMAGE_SCRIPT.new())
	_save_effect("damage", damage)

	_save_effect("haste", _turn_buff("SPD", 20, 2))    # +20% SPD for 2 turns
	_save_effect("guard", _turn_buff("DEF", 50, 2))    # +50% DEF for 2 turns
	_save_effect("weaken", _turn_buff("DEF", -20, 2))  # -20% DEF for 2 turns

	var poison := GameplayEffect.new()
	poison.policy = GameplayEffect.DurationPolicy.TURN_BASED
	poison.period = 1.0
	poison.duration_turns = 3
	poison.modifiers.append(_modifier("HP", GameplayEffectModifier.Operation.ADD, -30))  # 30 HP per tick
	_save_effect("poison", poison)

	var noop := GameplayEffect.new()
	noop.policy = GameplayEffect.DurationPolicy.INSTANT
	_save_effect("noop", noop)


func _turn_buff(attribute_name: String, percent: float, turns: int) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.TURN_BASED
	effect.duration_turns = turns
	effect.modifiers.append(_modifier(attribute_name, GameplayEffectModifier.Operation.PERCENT_ADD, percent))
	return effect


func _modifier(attribute_name: String, operation: GameplayEffectModifier.Operation, typed: float) -> CombatModifier:
	var modifier := CombatModifier.new()
	modifier.attribute_name = attribute_name
	modifier.operation = operation
	modifier.value_x100 = Fixed.from_typed(typed)
	return modifier


func _save_effect(name: String, effect: GameplayEffect) -> void:
	var path := ROOT + "effects/%s.tres" % name
	_check(ResourceSaver.save(effect, path), path)
	_effects[name] = load(path)


func _build_abilities() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	_ability("strike", "Fixture.Ability.Strike", B.SINGLE_ENEMY,
		[_row("hit", "damage", D.SCALED, 100, T.ALL)], [[0.3, "hit"]])
	_ability("combo", "Fixture.Ability.Combo", B.BLAST_ENEMY,
		[_row("slash_light", "damage", D.SCALED, 60, T.PRIMARY),
		 _row("slash_heavy", "damage", D.SCALED, 120, T.PRIMARY),
		 _row("shockwave", "damage", D.FLAT, 80.5, T.ADJACENT)],
		[[0.35, "slash_light"], [0.6, "slash_light"], [1.1, "slash_heavy"], [1.15, "shockwave"]],
		[[0.2, "play_sound", "swoosh"]])  # not an execute key: ignored by combat
	_ability("sweep", "Fixture.Ability.Sweep", B.ALL_ENEMIES,
		[_row("sweep", "damage", D.SCALED, 60, T.ALL)], [[0.5, "sweep"]])
	_ability("haste", "Fixture.Ability.Haste", B.SINGLE_ALLY,
		[_row("buff", "haste", D.USE_EFFECT, 0, T.ALL)], [[0.4, "buff"]])
	_ability("guard", "Fixture.Ability.Guard", B.SELF,
		[_row("buff", "guard", D.USE_EFFECT, 0, T.ALL)], [[0.4, "buff"]])
	_ability("weaken", "Fixture.Ability.Weaken", B.SINGLE_ENEMY,
		[_row("hit", "damage", D.SCALED, 50, T.ALL), _row("debuff", "weaken", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "hit"], [0.5, "debuff"]])
	_ability("poison", "Fixture.Ability.Poison", B.SINGLE_ENEMY,
		[_row("hit", "damage", D.SCALED, 40, T.ALL), _row("dot", "poison", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "hit"], [0.5, "dot"]])
	_ability("idle", "Fixture.Ability.Idle", B.SELF,
		[_row("idle", "noop", D.USE_EFFECT, 0, T.ALL)], [[0.1, "idle"]])
	_ability("claw", "Fixture.Ability.Claw", B.SINGLE_ENEMY,
		[_row("hit", "damage", D.SCALED, 100, T.ALL)], [[0.3, "hit"]])
	_ability("slam", "Fixture.Ability.Slam", B.BLAST_ENEMY,
		[_row("slam_main", "damage", D.SCALED, 80, T.PRIMARY), _row("slam_splash", "damage", D.SCALED, 40, T.ADJACENT)],
		[[0.3, "slam_main"], [0.32, "slam_splash"]])
	_ability("sleepy", "Fixture.Ability.Sleepy", B.SINGLE_ENEMY,
		[_row("hit", "damage", D.SCALED, 100, T.ALL)], [[0.3, "hit"]], [], SLEEPY_SCRIPT)


func _row(id: String, effect_name: String, mode: ExecutionRow.DamageMode, typed: float,
		targets: ExecutionRow.Targets) -> ExecutionRow:
	var row := ExecutionRow.new()
	row.id = StringName(id)
	row.effect = _effects[effect_name]
	row.damage_mode = mode
	row.targets = targets
	if mode == ExecutionRow.DamageMode.FLAT:
		row.flat_damage_x100 = Fixed.from_typed(typed)
	elif mode == ExecutionRow.DamageMode.SCALED:
		row.multiplier_x100 = Fixed.from_typed(typed)
	return row


func _ability(name: String, tag: String, targeting: BattleAbility.Targeting, rows: Array, execute_keys: Array,
		other_keys: Array = [], script: Script = null) -> void:
	var animation := Animation.new()
	animation.resource_name = name
	animation.length = 1.5
	var track := animation.add_track(Animation.TYPE_METHOD)
	animation.track_set_path(track, NodePath("."))
	for key in execute_keys:
		animation.track_insert_key(track, key[0], {"method": &"execute", "args": [StringName(key[1])]})
	for key in other_keys:
		animation.track_insert_key(track, key[0], {"method": StringName(key[1]), "args": [key[2]]})
	var animation_path := ROOT + "animations/%s.tres" % name
	_check(ResourceSaver.save(animation, animation_path), animation_path)

	var ability: BattleAbility = script.new() if script else BattleAbility.new()
	ability.name = name.to_pascal_case()
	ability.ability_tag = StringName(tag)
	ability.targeting = targeting
	var typed_rows: Array[ExecutionRow] = []
	typed_rows.assign(rows)
	ability.executions = typed_rows
	ability.animation = load(animation_path)
	var scene := PackedScene.new()
	scene.pack(ability)
	var path := ROOT + "abilities/%s.tscn" % name
	_check(ResourceSaver.save(scene, path), path)
	ability.free()
	_abilities[name] = load(path)


func _build_units() -> void:
	var standard := {"CritRate": 5, "CritDmg": 50}
	_unit("striker", {"MaxHP": 1000, "HP": 1000, "ATK": 500, "DEF": 300, "SPD": 100}, standard, ["strike", "combo", "guard"])
	_unit("sweeper", {"MaxHP": 900, "HP": 900, "ATK": 420, "DEF": 250, "SPD": 110}, {"CritRate": 10, "CritDmg": 50}, ["sweep", "strike"])
	_unit("support", {"MaxHP": 850, "HP": 850, "ATK": 300, "DEF": 280, "SPD": 120}, standard, ["haste", "weaken", "strike"])
	_unit("poisoner", {"MaxHP": 880, "HP": 880, "ATK": 380, "DEF": 260, "SPD": 95.5}, {"CritRate": 7.5, "CritDmg": 60}, ["poison", "strike"])
	_unit("dummy", {"MaxHP": 800, "HP": 800, "ATK": 300, "DEF": 200, "SPD": 90}, standard, ["claw"])
	_unit("brute", {"MaxHP": 3000, "HP": 3000, "ATK": 350, "DEF": 350, "SPD": 105}, standard, ["slam", "claw"])
	_unit("wall", {"MaxHP": 5000, "HP": 5000, "ATK": 0, "DEF": 0, "SPD": 100}, {}, ["idle"])
	_unit("pacifist", {"MaxHP": 5000, "HP": 5000, "ATK": 0, "DEF": 0, "SPD": 100}, {}, ["idle"])
	_unit("sleeper", {"MaxHP": 1000, "HP": 1000, "ATK": 500, "DEF": 300, "SPD": 100}, standard, ["sleepy"])


func _unit(name: String, core: Dictionary, extra: Dictionary, ability_names: Array) -> void:
	var unit := UnitDefinition.new()
	unit.id = StringName("fixture.unit." + name)
	unit.attribute_set = ATTRIBUTE_SET
	var stats: Dictionary[String, int] = {}
	for source in [core, extra]:
		for attribute_name in source:
			stats[attribute_name] = Fixed.from_typed(float(source[attribute_name]))
	unit.stats_x100 = stats
	var scenes: Array[PackedScene] = []
	for ability_name in ability_names:
		scenes.append(_abilities[ability_name])
	unit.abilities = scenes
	var path := ROOT + "units/%s.tres" % name
	_check(ResourceSaver.save(unit, path), path)
	_units[name] = load(path)


func _build_encounters() -> void:
	_encounter("duel", ["dummy"])
	_encounter("squad", ["dummy", "brute", "dummy"])
	_encounter("stalemate", ["wall"])


func _encounter(name: String, enemy_names: Array) -> void:
	var encounter := EncounterDefinition.new()
	encounter.id = StringName("fixture.encounter." + name)
	var enemies: Array[UnitDefinition] = []
	for enemy_name in enemy_names:
		enemies.append(_units[enemy_name])
	encounter.enemies = enemies
	var path := ROOT + "encounters/%s.tres" % name
	_check(ResourceSaver.save(encounter, path), path)


func _check(error: Error, path: String) -> void:
	if error != OK:
		push_error("build_fixtures: could not save %s (%s)" % [path, error_string(error)])
