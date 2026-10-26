## One-time builder for the nine new classes (spec playable-demo 3.10): Arcanist, Bard, Ranger, Cryomancer, Pyromancer,
## Bulwark, Ember Knight, Shatterweaver and Plaguewright, with their abilities, passives, ults and new effects, written
## into res://content/demo/ through ResourceSaver like build_full_descent.
##
## Same rules as build_demo, whose helpers it reuses: it never overwrites (an existing file is skipped and used), it
## writes nowhere but content/demo/, and it never touches an existing file. Values are starting values, typed as a
## designer would; tune them in the files.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_classes.tscn
extends "res://game/tools/build_full_descent.gd"

const SHARED := ["ult_charge", "ult_charge_hit", "break_physical", "break_fire", "break_ice"]


func _ready() -> void:
	if not ResourceLoader.exists(GENERATED_SET) or load(PERCENT_OF_MAX) == null:
		_quit("Needs %s and %s (run --import once first)." % [GENERATED_SET, PERCENT_OF_MAX])
		return
	_attributes = load(ATTRIBUTES)
	for key in ["queries/not_controlled"]:
		_r[key] = load(CONTENT + key + ".tres")
	for name in ["damage", "bleed", "burn", "poison", "freeze", "slow", "vulnerable", "weaken", "defense_up", "haste",
			"taunt", "ward", "rally", "ult_cost", "exposed_physical"]:
		_r["effects/" + name] = load(CONTENT + "effects/%s.tres" % name)
	for name in SHARED:
		_r["abilities/" + name] = load(CONTENT + "abilities/%s.tscn" % name)
	for key in _r:
		if _r[key] == null:
			_quit("Missing %s%s" % [CONTENT, key])
			return
	_class_effects()
	_arcanist()
	_bard()
	_ranger()
	_cryomancer()
	_pyromancer()
	_bulwark()
	_ember_knight()
	_shatterweaver()
	_plaguewright()
	print("build_classes: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _made:
		print("  made    ", path)
	for path in _skipped:
		print("  skipped ", path)
	for path in _failed:
		print("  FAILED  ", path)
	get_tree().quit(1 if not _failed.is_empty() else 0)


# --- Shared pieces -------------------------------------------------------------------------------------------------------

## A turn-based buff that adds (for attributes that start at 0: toughness_dmg, broken_dmg, debuff_turns, or flat SPD).
func _add_buff(changes: Dictionary, turns: int, granted: Array) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.TURN_BASED
	effect.duration_turns = turns
	effect.granted_tags.assign(granted)
	for attribute_name in changes:
		effect.modifiers.append(_modifier(attribute_name, ADD, changes[attribute_name]))
	return effect


## Spec 3.9 (D22): a debuff refuses units immune to it.
func _immune_to(effect: GameplayEffect, status: String) -> GameplayEffect:
	var query := GameplayTagQuery.new()
	query.ignore_tags.assign([StringName("Immune." + status), &"Immune.Debuff"])
	effect.application_query = query
	return effect


func _mp_cost(amount: int) -> String:
	var key := "mp_cost_%d" % amount
	if not _r.has("effects/" + key):
		_save("effects/" + key, _instant({"mp": -amount}))
	return key


func _ult() -> Dictionary:
	return {"cost": "ult_cost", "asset_tags": [BattleAbility.ULTIMATE_TAG], "query": _r["queries/not_controlled"]}


func _hero(name: String, title: String, color: Color, hp: float, mp: float, atk: float, def: float, spd: float,
		abilities: Array, extra: Dictionary = {}) -> void:
	var stats := {"max_hp": hp, "hp": hp, "max_mp": mp, "mp": mp, "atk": atk, "def": def, "spd": spd, "crit_rate": 5,
		"crit_dmg": 50, "energy": 0, "toughness": 0, "max_toughness": 0}.merged(extra, true)
	var character := CharacterDefinition.new()
	character.id = StringName("demo.character." + name)
	character.display_name = title
	character.display_color = color
	character.attribute_set = _attributes
	_stats(character, stats)
	for ability in abilities + SHARED:
		character.abilities.append(_r["abilities/" + ability])
	character.tags.assign([StringName("Character." + name.to_pascal_case())])  # Character.EmberKnight
	_save("characters/" + name, character)


func _class_effects() -> void:
	_save("effects/finale", _buff({"atk": 30}, 2, [&"Status.Buff.Finale"]))
	_save("effects/fury", _refresh(_buff({"atk": 10}, 2, [&"Status.Buff.Fury"]), 5))
	_save("effects/combustion", _add_buff({"spd": 30, "toughness_dmg": 50, "broken_dmg": 40}, 3,
		[&"Status.Buff.Combustion", &"State.Combustion"]))
	_save("effects/fracture", _add_buff({"toughness_dmg": 30, "broken_dmg": 25}, 3, [&"Status.Buff.Fracture"]))
	_save("effects/malady", _add_buff({"debuff_turns": 1}, 3, [&"Status.Buff.Malady"]))
	_save("effects/seared", _immune_to(_tagged([&"Weakness.Fire", &"Status.Debuff.Exposed"], 2), "Exposed"))
	_save("effects/spellweave_mp", _instant({"mp": 6}))
	for amount in [8, 10, 20]:
		_save("effects/class_charge_%d" % amount, _instant({"energy": amount}))


# --- The classes ---------------------------------------------------------------------------------------------------------

func _arcanist() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var fire := [&"Damage.Type.Fire"]
	var ice := [&"Damage.Type.Ice"]
	_ability("arcane_bolt", "Ability.Arcanebolt", B.SINGLE_ENEMY, [_row("bolt", "damage", D.SCALED, 90, T.ALL, ice)],
		_flash(0.5), [[0.25, "bolt"]], {"sound": ["Ice2", 0.2, -8.0]})
	_ability("fireburst", "Ability.Fireburst", B.BLAST_ENEMY, [_row("burst", "damage", D.SCALED, 140, T.PRIMARY, fire),
		_row("splash", "damage", D.SCALED, 60, T.ADJACENT, fire)], _jump(0.6), [[0.3, "burst"], [0.32, "splash"]],
		{"cost": _mp_cost(15), "sound": ["Fire2", 0.2, -6.0]})
	_ability("frost_nova", "Ability.Frostnova", B.ALL_ENEMIES, [_row("nova", "damage", D.SCALED, 70, T.ALL, ice)], _spin(0.7),
		[[0.35, "nova"]], {"cost": _mp_cost(20), "sound": ["Ice5", 0.3, -6.0]})
	_passive("spellweave", "Ability.Passive.Spellweave", B.SELF, [["mana", "spellweave_mp", D.USE_EFFECT, 0]], &"Event.Unit.Killed")
	var meteor := _row("meteor", "damage", D.SCALED, 200, T.ALL, fire)
	meteor.toughness_x100 = Fixed.from_typed(60)
	_ability("meteor", "Ability.Ult.Meteor", B.ALL_ENEMIES, [meteor], _spin(1.0), [[0.5, "meteor"]],
		_ult().merged({"sound": ["Explosion1", 0.4, -2.0]}))
	_hero("arcanist", "Arcanist", Color.MEDIUM_PURPLE, 700, 140, 520, 180, 105,
		["meteor", "arcane_bolt", "fireburst", "frost_nova", "spellweave"])


func _bard() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	_ability("dissonance", "Ability.Dissonance", B.SINGLE_ENEMY, [_row("chord", "damage", D.SCALED, 70, T.ALL, physical),
		_chance(_row("weaken", "weaken", D.USE_EFFECT, 0, T.ALL), 60)], _jump(0.5), [[0.25, "chord"], [0.3, "weaken"]],
		{"sound": ["Chime1", 0.1, -8.0]})
	_ability("anthem", "Ability.Anthem", B.ALL_ALLIES, [_row("rally", "rally", D.USE_EFFECT, 0, T.ALL),
		_row("haste", "haste", D.USE_EFFECT, 0, T.ALL)], _jump(0.6), [[0.3, "rally"], [0.35, "haste"]],
		{"cost": _mp_cost(15), "sound": ["Song", 0.0, -4.0]})
	_ability("discord", "Ability.Discord", B.ALL_ENEMIES, [_chance(_row("expose", "vulnerable", D.USE_EFFECT, 0, T.ALL), 80),
		_chance(_row("slow", "slow", D.USE_EFFECT, 0, T.ALL), 50)], _spin(0.6), [[0.3, "expose"], [0.35, "slow"]],
		{"cost": _mp_cost(15)})
	_passive("encore", "Ability.Passive.Encorebard", B.SELF, [["charge", "class_charge_8", D.USE_EFFECT, 0]], &"Event.Turn.Start")
	var finale := _row("finale", "finale", D.USE_EFFECT, 0, T.ALL)
	finale.delay_x100 = Fixed.from_typed(-100)  # the party acts at once (an advance, content-pass H6)
	_ability("finale", "Ability.Ult.Finale", B.ALL_ALLIES, [finale], _spin(1.0), [[0.5, "finale"]],
		_ult().merged({"sound": ["Song", 0.2, -2.0]}))
	_hero("bard", "Bard", Color.HOT_PINK, 850, 110, 380, 240, 120, ["finale", "dissonance", "anthem", "discord", "encore"])


func _ranger() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	_ability("quick_shot", "Ability.Quickshot", B.SINGLE_ENEMY, [_row("shot", "damage", D.SCALED, 100, T.ALL, physical)],
		_jump(0.5), [[0.25, "shot"]], {"sound": ["Shot1", 0.2, -8.0]})
	_ability("mark_prey", "Ability.Markprey", B.SINGLE_ENEMY, [_row("mark", "exposed_physical", D.USE_EFFECT, 0, T.ALL),
		_row("shot", "damage", D.SCALED, 80, T.ALL, physical)], _flash(0.5), [[0.25, "mark"], [0.3, "shot"]],
		{"cost": _mp_cost(10)})
	_passive("hunters_instinct", "Ability.Passive.Huntersinstinct", B.SINGLE_ENEMY, [["volley", "damage", D.SCALED, 50, physical]],
		&"Event.Damage.Dealt.Weakness", {"asset_tags": FOLLOW_UP})
	_passive("quarry", "Ability.Passive.Quarry", B.SELF, [["charge", "class_charge_10", D.USE_EFFECT, 0]], &"Event.Attack.FollowUp")
	_ability("rain_of_arrows", "Ability.Ult.Rainofarrows", B.ALL_ENEMIES, [_row("rain", "damage", D.SCALED, 130, T.ALL, physical)],
		_spin(1.0), [[0.5, "rain"]], _ult().merged({"sound": ["Shot1", 0.3, -4.0]}))
	_hero("ranger", "Ranger", Color.FOREST_GREEN, 850, 80, 480, 220, 115,
		["rain_of_arrows", "quick_shot", "mark_prey", "hunters_instinct", "quarry"], {"crit_rate": 20})


func _cryomancer() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var ice := [&"Damage.Type.Ice"]
	var jab := _row("jab", "damage", D.SCALED, 100, T.ALL, ice)
	jab.toughness_x100 = Fixed.from_typed(30)
	_ability("frost_jab", "Ability.Frostjab", B.SINGLE_ENEMY, [jab], _jump(0.5), [[0.25, "jab"]])
	_ability("glacial_spike", "Ability.Glacialspike", B.SINGLE_ENEMY, [_row("spike", "damage", D.SCALED, 160, T.ALL, ice),
		_chance(_row("freeze", "freeze", D.USE_EFFECT, 0, T.ALL), 35)], _flash(0.6), [[0.3, "spike"], [0.35, "freeze"]],
		{"cost": _mp_cost(15), "sound": ["Ice5", 0.2, -6.0]})
	_ability("blizzard", "Ability.Blizzard", B.ALL_ENEMIES, [_row("storm", "damage", D.SCALED, 70, T.ALL, ice),
		_chance(_row("slow", "slow", D.USE_EFFECT, 0, T.ALL), 100)], _spin(0.7), [[0.35, "storm"], [0.4, "slow"]],
		{"cost": _mp_cost(20)})
	_passive("cold_snap", "Ability.Passive.Coldsnap", B.SELF, [["charge", "class_charge_20", D.USE_EFFECT, 0]], &"Event.Damage.Dealt.Break")
	_ability("absolute_zero", "Ability.Ult.Absolutezero", B.ALL_ENEMIES, [_row("zero", "damage", D.SCALED, 160, T.ALL, ice),
		_chance(_row("freeze", "freeze", D.USE_EFFECT, 0, T.ALL), 50)], _spin(1.0), [[0.5, "zero"], [0.55, "freeze"]],
		_ult().merged({"sound": ["Ice5", 0.4, -2.0]}))
	_hero("cryomancer", "Cryomancer", Color.DEEP_SKY_BLUE, 800, 120, 470, 220, 105,
		["absolute_zero", "frost_jab", "glacial_spike", "blizzard", "cold_snap"])


func _pyromancer() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var fire := [&"Damage.Type.Fire"]
	_ability("ember", "Ability.Ember", B.SINGLE_ENEMY, [_row("ember", "damage", D.SCALED, 100, T.ALL, fire)], _jump(0.5),
		[[0.25, "ember"]], {"sound": ["Fire1", 0.2, -8.0]})
	_ability("ignite", "Ability.Ignite", B.SINGLE_ENEMY, [_row("flame", "damage", D.SCALED, 80, T.ALL, fire),
		_chance(_row("burn", "burn", D.FLAT, 60, T.ALL, fire), 100)], _flash(0.5), [[0.25, "flame"], [0.3, "burn"]],
		{"cost": _mp_cost(10)})
	_ability("inferno", "Ability.Inferno", B.ALL_ENEMIES, [_row("fire", "damage", D.SCALED, 60, T.ALL, fire),
		_chance(_row("burn", "burn", D.FLAT, 40, T.ALL, fire), 100)], _spin(0.7), [[0.35, "fire"], [0.4, "burn"]],
		{"cost": _mp_cost(20), "sound": ["Fire2", 0.3, -6.0]})
	_passive("kindling", "Ability.Passive.Kindling", B.SELF, [["charge", "class_charge_8", D.USE_EFFECT, 0]], &"Event.Damage.Dealt.Fire")
	_ability("supernova", "Ability.Ult.Supernova", B.ALL_ENEMIES, [_row("nova", "damage", D.SCALED, 220, T.ALL, fire),
		_chance(_row("burn", "burn", D.FLAT, 100, T.ALL, fire), 100)], _spin(1.0), [[0.5, "nova"], [0.55, "burn"]],
		_ult().merged({"sound": ["Explosion1", 0.4, -2.0]}))
	_hero("pyromancer", "Pyromancer", Color.ORANGE_RED, 780, 120, 500, 200, 110,
		["supernova", "ember", "ignite", "inferno", "kindling"], {"energy_regen": 125})


func _bulwark() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	var slam := _row("slam", "damage", D.SCALED, 80, T.ALL, physical)
	slam.toughness_x100 = Fixed.from_typed(40)
	_ability("shield_slam", "Ability.Shieldslam", B.SINGLE_ENEMY, [slam], _jump(0.5), [[0.25, "slam"]], {"sound": ["Blow4", 0.2, -6.0]})
	_ability("fortify", "Ability.Fortify", B.SELF, [_row("guard", "defense_up", D.USE_EFFECT, 0, T.ALL),
		_row("taunt", "taunt", D.USE_EFFECT, 0, T.ALL)], _jump(0.6), [[0.25, "guard"], [0.3, "taunt"]], {"cost": _mp_cost(10)})
	_passive("retaliation", "Ability.Passive.Retaliation", B.SINGLE_ENEMY, [["counter", "damage", D.SCALED, 40, physical]],
		&"Event.Damage.Taken", {"asset_tags": FOLLOW_UP})
	_passive("fury_rising", "Ability.Passive.Furyrising", B.SELF, [["fury", "fury", D.USE_EFFECT, 0],
		["charge", "class_charge_10", D.USE_EFFECT, 0]], &"Event.Damage.Taken")
	_ability("bastion", "Ability.Ult.Bastion", B.ALL_ALLIES, [_row("ward", "ward", D.USE_EFFECT, 0, T.ALL),
		_row("guard", "defense_up", D.USE_EFFECT, 0, T.ALL)], _jump(1.0), [[0.4, "ward"], [0.5, "guard"]],
		_ult().merged({"sound": ["Buff", 0.2, -2.0]}))
	_hero("bulwark", "Bulwark", Color.DARK_KHAKI, 1400, 60, 320, 420, 90,
		["bastion", "shield_slam", "fortify", "retaliation", "fury_rising"])


func _ember_knight() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var fire := [&"Damage.Type.Fire"]
	var slash := _row("slash", "damage", D.SCALED, 100, T.ALL, fire)
	slash.toughness_x100 = Fixed.from_typed(30)
	_ability("searing_slash", "Ability.Searingslash", B.SINGLE_ENEMY, [slash], _jump(0.5), [[0.25, "slash"]], {"sound": ["Fire1", 0.2, -8.0]})
	var brand := _row("brand", "damage", D.SCALED, 150, T.ALL, fire)
	brand.toughness_x100 = Fixed.from_typed(50)
	_ability("kindle_brand", "Ability.Kindlebrand", B.SINGLE_ENEMY, [_row("sear", "seared", D.USE_EFFECT, 0, T.ALL), brand],
		_jump(0.6), [[0.25, "sear"], [0.3, "brand"]], {"cost": _mp_cost(15), "sound": ["Fire2", 0.2, -6.0]})
	var strike := _row("strike", "damage", D.SCALED, 200, T.PRIMARY, fire)
	strike.toughness_x100 = Fixed.from_typed(60)
	var splash := _row("splash", "damage", D.SCALED, 80, T.ADJACENT, fire)
	_ability("fyrefly_strike", "Ability.Fyreflystrike", B.BLAST_ENEMY, [_row("sear", "seared", D.USE_EFFECT, 0, T.ALL), strike, splash],
		_spin(0.7), [[0.25, "sear"], [0.35, "strike"], [0.37, "splash"]], {"query": _query([&"State.Combustion"]),
		"sound": ["Explosion1", 0.3, -4.0]})
	_ability("complete_combustion", "Ability.Ult.Combustion", B.SELF, [_row("combust", "combustion", D.USE_EFFECT, 0, T.ALL)],
		_spin(1.0), [[0.5, "combust"]], _ult().merged({"sound": ["Fire2", 0.3, -2.0]}))
	_hero("ember_knight", "Ember Knight", Color.TOMATO, 950, 80, 500, 260, 112,
		["complete_combustion", "searing_slash", "kindle_brand", "fyrefly_strike"], {"broken_dmg": 40})


func _shatterweaver() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	var fault := _row("fault", "damage", D.SCALED, 80, T.ALL, physical)
	fault.toughness_x100 = Fixed.from_typed(40)
	_ability("fault_line", "Ability.Faultline", B.SINGLE_ENEMY, [fault], _jump(0.5), [[0.25, "fault"]])
	_ability("fracture_field", "Ability.Fracturefield", B.ALL_ALLIES, [_row("fracture", "fracture", D.USE_EFFECT, 0, T.ALL)],
		_flash(0.6), [[0.3, "fracture"]], {"cost": _mp_cost(15), "sound": ["Flash1", 0.1, -6.0]})
	var splinter := _row("splinter", "damage", D.SCALED, 60, T.ALL, physical)
	splinter.toughness_x100 = Fixed.from_typed(50)
	_ability("splinter", "Ability.Splinter", B.SINGLE_ENEMY, [splinter, _chance(_row("crack", "vulnerable", D.USE_EFFECT, 0, T.ALL), 100)],
		_jump(0.5), [[0.25, "splinter"], [0.3, "crack"]], {"cost": _mp_cost(10)})
	_passive("resonance", "Ability.Passive.Resonance", B.SELF, [["charge", "class_charge_20", D.USE_EFFECT, 0]], &"Event.Damage.Dealt.Break")
	var chorus := _row("chorus", "damage", D.SCALED, 60, T.ALL, physical)
	chorus.toughness_x100 = Fixed.from_typed(80)
	_ability("shatter_chorus", "Ability.Ult.Shatterchorus", B.ALL_ENEMIES, [chorus], _spin(1.0), [[0.5, "chorus"]],
		_ult().merged({"sound": ["Explosion1", 0.4, -4.0]}))
	# Shatter Chorus's party half: Fracture Field after each of its ults (one ability can't target both sides).
	_passive("chorus_echo", "Ability.Passive.Chorusecho", B.ALL_ALLIES, [["fracture", "fracture", D.USE_EFFECT, 0]],
		&"Event.Ability.Used.Ultimate")
	_hero("shatterweaver", "Shatterweaver", Color.LIGHT_CORAL, 820, 110, 380, 230, 118,
		["shatter_chorus", "fault_line", "fracture_field", "splinter", "resonance", "chorus_echo"])


func _plaguewright() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	var fire := [&"Damage.Type.Fire"]
	_ability("infect", "Ability.Infect", B.SINGLE_ENEMY, [_row("jab", "damage", D.SCALED, 70, T.ALL, physical),
		_chance(_row("poison", "poison", D.USE_EFFECT, 0, T.ALL), 60)], _jump(0.5), [[0.25, "jab"], [0.3, "poison"]])
	_ability("contagion", "Ability.Contagion", B.ALL_ENEMIES, [_chance(_row("poison", "poison", D.USE_EFFECT, 0, T.ALL), 80),
		_chance(_row("poison_again", "poison", D.USE_EFFECT, 0, T.ALL), 80)], _spin(0.6), [[0.3, "poison"], [0.35, "poison_again"]],
		{"cost": _mp_cost(15), "sound": ["Poison", 0.2, -6.0]})
	_ability("lingering_malady", "Ability.Lingeringmalady", B.ALL_ALLIES, [_row("malady", "malady", D.USE_EFFECT, 0, T.ALL)],
		_flash(0.6), [[0.3, "malady"]], {"cost": _mp_cost(15)})
	_passive("virulence", "Ability.Passive.Virulence", B.SELF, [["charge", "class_charge_10", D.USE_EFFECT, 0]], &"Event.Status.Resisted")
	_ability("pandemic", "Ability.Ult.Pandemic", B.ALL_ENEMIES, [_chance(_row("poison", "poison", D.USE_EFFECT, 0, T.ALL), 100),
		_chance(_row("bleed", "bleed", D.USE_EFFECT, 0, T.ALL), 100), _chance(_row("burn", "burn", D.FLAT, 60, T.ALL, fire), 100),
		_chance(_row("expose", "vulnerable", D.USE_EFFECT, 0, T.ALL), 100)], _spin(1.0),
		[[0.4, "poison"], [0.45, "bleed"], [0.5, "burn"], [0.55, "expose"]], _ult().merged({"sound": ["Poison", 0.3, -2.0]}))
	_hero("plaguewright", "Plaguewright", Color.YELLOW_GREEN, 820, 120, 400, 220, 112,
		["pandemic", "infect", "contagion", "lingering_malady", "virulence"], {"debuff_turns": 1})
