## One-time builder for the full Descent (spec playable-demo 3.8): the Ember Forge, the Hollow, the Silent Cathedral,
## the Black Coven, the Vault and the Void (chapters, floor rules, boss rooms, the Void's altars), their enemies, bosses
## and encounters, the Rat King and the Bone Warden for the Cellar and the Crypt, 24 themed items, 15 corrupted items,
## Void Scar and the ten-floor depth scaling, written into res://content/demo/ through ResourceSaver like
## build_demo_run.
##
## Same rules as build_demo, whose helpers it reuses: it never overwrites (an existing file is skipped and used), it
## writes nowhere but content/demo/, and it never touches an existing file. The edits to existing files (the run's ten
## floors, the Cellar's and the Crypt's rotation and scaling, the Golem's and the Lich's rewards, the rarity retags) are
## made by hand with your approval. Values are starting values, typed as a designer would; tune them in the files.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_full_descent.tscn
extends "res://game/tools/build_demo_run.gd"

const COMMON := &"Item.Rarity.Common"
const RARE := &"Item.Rarity.Rare"
const EPIC := &"Item.Rarity.Epic"
const LEGENDARY := &"Item.Rarity.Legendary"
const CORRUPTED := &"Item.Corrupted"
const VOID_POOL := &"Pool.Void"
const CORE := {"crit_rate": 5, "crit_dmg": 50, "energy": 0, "weakness_dmg": 150}


func _ready() -> void:
	if not ResourceLoader.exists(GENERATED_SET) or load(PERCENT_OF_MAX) == null:
		_quit("Needs %s and %s (run --import once first)." % [GENERATED_SET, PERCENT_OF_MAX])
		return
	_attributes = load(ATTRIBUTES)
	for key in ["rooms/boss", "floor_rules/small", "items/stale_bread", "queries/not_controlled", "variants/elite"]:
		_r[key] = load(CONTENT + key + ".tres")
	for name in ["damage", "bleed", "burn", "poison", "freeze", "stun", "slow", "vulnerable", "weaken", "defense_up",
			"haste", "taunt", "ward", "regen", "dispel", "cleanse", "rally", "entangle", "ult_cost", "heal"]:
		_r["effects/" + name] = load(CONTENT + "effects/%s.tres" % name)
	for name in ["ult_charge_hit", "fire_bolt", "shield_bash", "hex", "mend", "dispel", "hex_all", "doom", "provoke",
			"thorn_mail", "entangle_lash"]:
		_r["abilities/" + name] = load(CONTENT + "abilities/%s.tscn" % name)
	for key in _r:
		if _r[key] == null:
			_quit("Missing %s%s" % [CONTENT, key])
			return
	_scaling()
	_enemy_moves()
	_enemies_and_encounters()
	_themed_items()
	_corrupted_items()
	_chapters()
	print("build_full_descent: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _made:
		print("  made    ", path)
	for path in _skipped:
		print("  skipped ", path)
	for path in _failed:
		print("  FAILED  ", path)
	get_tree().quit(1 if not _failed.is_empty() else 0)


# --- Depth scaling (ten floors) ------------------------------------------------------------------------------------------

func _scaling() -> void:
	var hp := [0, 10, 10, 20, 30, 45, 80, 70, 80, 90]  # floors 3-6 softened (spec 3.9), 8-10 (3.11 tuning)
	var atk := [10, 20, 30, 40, 50, 60, 70, 70, 75, 80]
	var def := [0, 10, 15, 20, 30, 40, 50, 60, 70, 80]
	var steps: Array[GameplayEffect] = []
	for depth in 10:
		var changes := {}
		for pair in [["max_hp", hp[depth]], ["atk", atk[depth]], ["def", def[depth]]]:
			if pair[1] != 0:
				changes[pair[0]] = pair[1]
		steps.append(_save("effects/descent_depth_%d" % depth, _infinite(changes, true)))
	var rules := ScalingRules.new()
	rules.id = &"demo.scaling.descent"
	rules.enemy_effects_by_depth = steps
	rules.elite_chance_x100 = Fixed.from_typed(20)
	rules.coin_drop_chance_x100 = Fixed.from_typed(80)
	_save("scaling/descent", rules)


# --- Enemy moves ---------------------------------------------------------------------------------------------------------

func _enemy_moves() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	var fire := [&"Damage.Type.Fire"]
	var ice := [&"Damage.Type.Ice"]
	var ult := {"cost": "ult_cost", "asset_tags": [BattleAbility.ULTIMATE_TAG], "query": _r["queries/not_controlled"]}
	var phase_two := {"query": _query([&"State.Phase.Two"])}
	var phase_three := {"query": _query([&"State.Phase.Three"])}
	# The Cellar's and the Crypt's second bosses.
	_ability("gnaw", "Ability.Gnaw", B.SINGLE_ENEMY, [_row("bite", "damage", D.SCALED, 110, T.ALL, physical),
		_chance(_row("bleed", "bleed", D.USE_EFFECT, 0, T.ALL), 60)], _jump(0.5), [[0.25, "bite"], [0.3, "bleed"]],
		{"sound": ["Bite", 0.2, -8.0]})
	_ability("swarm", "Ability.Swarm", B.ALL_ENEMIES, [_row("swarm", "damage", D.SCALED, 50, T.ALL, physical)], _spin(0.7),
		[[0.35, "swarm"]], phase_two)
	_ability("bone_wall", "Ability.Bonewall", B.SELF, [_row("guard", "defense_up", D.USE_EFFECT, 0, T.ALL),
		_row("taunt", "taunt", D.USE_EFFECT, 0, T.ALL)], _jump(0.6), [[0.25, "guard"], [0.3, "taunt"]])
	_ability("ossuary", "Ability.Ult.Ossuary", B.ALL_ENEMIES, [_row("bones", "damage", D.SCALED, 120, T.ALL, physical)],
		_spin(1.0), [[0.5, "bones"]], ult.merged({"sound": ["Explosion1", 0.4, -4.0]}))
	# The Ember Forge.
	_ability("searing_bite", "Ability.Searingbite", B.SINGLE_ENEMY, [_row("bite", "damage", D.SCALED, 100, T.ALL, fire),
		_chance(_row("burn", "burn", D.FLAT, 40, T.ALL, fire), 100)], _jump(0.5), [[0.25, "bite"], [0.3, "burn"]],
		{"sound": ["Fire1", 0.2, -8.0]})
	var hammer := _row("hammer", "damage", D.SCALED, 120, T.ALL, physical)
	hammer.toughness_x100 = Fixed.from_typed(40)
	_ability("hammer_down", "Ability.Hammerdown", B.SINGLE_ENEMY, [hammer], _jump(0.7), [[0.35, "hammer"]],
		{"sound": ["Blow4", 0.3, -6.0]})
	_ability("brace", "Ability.Brace", B.SELF, [_row("brace", "defense_up", D.USE_EFFECT, 0, T.ALL)], _still(0.4), [[0.2, "brace"]])
	_ability("stoke", "Ability.Stoke", B.ALL_ALLIES, [_row("stoke", "rally", D.USE_EFFECT, 0, T.ALL)], _flash(0.5), [[0.25, "stoke"]])
	_ability("slag", "Ability.Slag", B.SINGLE_ENEMY, [_row("slag", "damage", D.SCALED, 80, T.ALL, fire),
		_chance(_row("slow", "slow", D.USE_EFFECT, 0, T.ALL), 100)], _jump(0.5), [[0.25, "slag"], [0.3, "slow"]])
	var forge := _row("forge", "damage", D.SCALED, 130, T.ALL, physical)
	forge.toughness_x100 = Fixed.from_typed(30)
	_ability("forge_hammer", "Ability.Forgehammer", B.SINGLE_ENEMY, [forge], _jump(0.7), [[0.35, "forge"]])
	_ability("meltdown", "Ability.Meltdown", B.ALL_ENEMIES, [_row("melt", "damage", D.SCALED, 90, T.ALL, fire),
		_chance(_row("burn", "burn", D.FLAT, 50, T.ALL, fire), 100)], _spin(0.8), [[0.4, "melt"], [0.45, "burn"]], phase_three)
	_ability("crucible", "Ability.Ult.Crucible", B.ALL_ENEMIES, [_row("crucible", "damage", D.SCALED, 150, T.ALL, fire)],
		_spin(1.0), [[0.5, "crucible"]], ult.merged({"sound": ["Fire2", 0.4, -2.0]}))
	var piston := _row("piston", "damage", D.SCALED, 140, T.ALL, physical)
	piston.toughness_x100 = Fixed.from_typed(30)
	_ability("piston", "Ability.Piston", B.SINGLE_ENEMY, [piston], _jump(0.7), [[0.35, "piston"]])
	_ability("overheat", "Ability.Ult.Overheat", B.ALL_ENEMIES, [_row("steam", "damage", D.SCALED, 160, T.ALL, fire)],
		_spin(1.0), [[0.5, "steam"]], ult)
	# The Hollow.
	_ability("latch", "Ability.Latch", B.SINGLE_ENEMY, [_row("latch", "damage", D.SCALED, 90, T.ALL, physical),
		_chance(_row("bleed", "bleed", D.USE_EFFECT, 0, T.ALL), 100)], _jump(0.5), [[0.25, "latch"], [0.3, "bleed"]])
	_ability("bile", "Ability.Bile", B.SINGLE_ENEMY, [_chance(_row("poison", "poison", D.USE_EFFECT, 0, T.ALL), 100),
		_chance(_row("poison_again", "poison", D.USE_EFFECT, 0, T.ALL), 100)], _flash(0.5), [[0.25, "poison"], [0.3, "poison_again"]])
	_ability("devour", "Ability.Devour", B.SINGLE_ENEMY, [_row("devour", "damage", D.SCALED, 180, T.ALL, physical)], _jump(0.8),
		[[0.4, "devour"]], {"sound": ["Bite", 0.3, -4.0]})
	_ability("hemorrhage", "Ability.Hemorrhage", B.ALL_ENEMIES, [_row("cut", "damage", D.SCALED, 40, T.ALL, physical),
		_chance(_row("bleed", "bleed", D.USE_EFFECT, 0, T.ALL), 50)], _spin(0.6), [[0.3, "cut"], [0.35, "bleed"]])
	_ability("pulse", "Ability.Pulse", B.ALL_ENEMIES, [_row("pulse", "damage", D.SCALED, 70, T.ALL, physical)], _flash(0.6),
		[[0.3, "pulse"]])
	_ability("heart_regen", "Ability.Heartregen", B.SELF, [_row("regen", "regen", D.USE_EFFECT, 0, T.ALL)], _still(0.4), [[0.2, "regen"]])
	_ability("bleeding_out", "Ability.Bleedingout", B.ALL_ENEMIES, [_chance(_row("bleed", "bleed", D.USE_EFFECT, 0, T.ALL), 100),
		_chance(_row("expose", "vulnerable", D.USE_EFFECT, 0, T.ALL), 100)], _spin(0.7), [[0.3, "bleed"], [0.35, "expose"]], phase_two)
	_ability("systole", "Ability.Ult.Systole", B.ALL_ENEMIES, [_row("beat", "damage", D.SCALED, 180, T.ALL, physical)],
		_jump(1.0), [[0.5, "beat"]], ult)
	_ability("twin_beat", "Ability.Ult.Twinbeat", B.SINGLE_ENEMY, [_row("beat", "damage", D.SCALED, 200, T.ALL, physical)],
		_jump(0.9), [[0.45, "beat"]], ult)
	# The Silent Cathedral.
	_ability("hymn", "Ability.Hymn", B.ALL_ALLIES, [_row("regen", "regen", D.USE_EFFECT, 0, T.ALL)], _flash(0.6), [[0.3, "regen"]],
		{"sound": ["Chime1", 0.1, -6.0]})
	_ability("bless", "Ability.Bless", B.SINGLE_ALLY, [_row("ward", "ward", D.USE_EFFECT, 0, T.ALL)], _flash(0.5), [[0.25, "ward"]])
	_ability("smite", "Ability.Smite", B.SINGLE_ENEMY, [_row("smite", "damage", D.SCALED, 150, T.ALL, physical)], _jump(0.7),
		[[0.35, "smite"]], {"sound": ["Flash1", 0.3, -4.0]})
	_ability("purify_self", "Ability.Purifyself", B.SELF, [_row("cleanse", "cleanse", D.USE_EFFECT, 0, T.ALL)], _flash(0.5),
		[[0.25, "cleanse"]])
	_ability("judgement", "Ability.Ult.Judgement", B.SINGLE_ENEMY, [_row("judge", "damage", D.SCALED, 260, T.ALL, physical)],
		_spin(1.0), [[0.5, "judge"]], ult.merged({"sound": ["Flash1", 0.4, -2.0]}))
	# The Vault.
	_ability("snap", "Ability.Snap", B.SINGLE_ENEMY, [_row("snap", "damage", D.SCALED, 120, T.ALL, physical)], _jump(0.5), [[0.25, "snap"]])
	_ability("lockdown", "Ability.Lockdown", B.SINGLE_ENEMY, [_row("lock", "damage", D.SCALED, 80, T.ALL, ice),
		_chance(_row("freeze", "freeze", D.USE_EFFECT, 0, T.ALL), 50)], _flash(0.6), [[0.3, "lock"], [0.35, "freeze"]])
	_ability("appraise", "Ability.Appraise", B.SINGLE_ENEMY, [_row("appraise", "damage", D.SCALED, 60, T.ALL, physical),
		_chance(_row("expose", "vulnerable", D.USE_EFFECT, 0, T.ALL), 100)], _flash(0.5), [[0.25, "appraise"], [0.3, "expose"]])
	_ability("gilded_ray", "Ability.Gildedray", B.ALL_ENEMIES, [_row("ray", "damage", D.SCALED, 90, T.ALL, ice)], _spin(0.8),
		[[0.4, "ray"]])
	_ability("liquidate", "Ability.Ult.Liquidate", B.SINGLE_ENEMY, [_row("liquidate", "damage", D.SCALED, 300, T.ALL, physical)],
		_spin(1.0), [[0.5, "liquidate"]], ult.merged({"sound": ["Explosion1", 0.4, -2.0]}))
	# The Black Coven.
	_ability("curse", "Ability.Curse", B.SINGLE_ENEMY, [_chance(_row("weaken", "weaken", D.USE_EFFECT, 0, T.ALL), 100)],
		_flash(0.5), [[0.25, "weaken"]])
	_ability("hellfire", "Ability.Hellfire", B.SINGLE_ENEMY, [_row("fire", "damage", D.SCALED, 120, T.ALL, fire),
		_chance(_row("burn", "burn", D.FLAT, 60, T.ALL, fire), 100)], _jump(0.6), [[0.3, "fire"], [0.35, "burn"]],
		{"sound": ["Fire2", 0.2, -6.0]})
	_ability("rend", "Ability.Rend", B.SINGLE_ENEMY, [_row("rend", "damage", D.SCALED, 110, T.ALL, physical),
		_chance(_row("bleed", "bleed", D.USE_EFFECT, 0, T.ALL), 100)], _jump(0.6), [[0.3, "rend"], [0.35, "bleed"]])
	_ability("witch_bolt", "Ability.Witchbolt", B.SINGLE_ENEMY, [_row("bolt", "damage", D.SCALED, 110, T.ALL, ice)], _flash(0.5),
		[[0.25, "bolt"]], {"sound": ["Ice2", 0.2, -8.0]})
	_ability("black_mass", "Ability.Ult.Blackmass", B.ALL_ENEMIES, [_row("mass", "damage", D.SCALED, 150, T.ALL, ice)],
		_spin(1.0), [[0.5, "mass"]], ult)
	# The Void.
	_ability("chill_touch", "Ability.Chilltouch", B.SINGLE_ENEMY, [_row("touch", "damage", D.SCALED, 90, T.ALL, ice),
		_chance(_row("freeze", "freeze", D.USE_EFFECT, 0, T.ALL), 40)], _flash(0.5), [[0.25, "touch"], [0.3, "freeze"]])
	_ability("fade", "Ability.Fade", B.SELF, [_row("fade", "defense_up", D.USE_EFFECT, 0, T.ALL)], _still(0.4), [[0.2, "fade"]])
	var crush := _row("crush", "damage", D.SCALED, 160, T.ALL, physical)
	crush.toughness_x100 = Fixed.from_typed(40)
	_ability("abyss_crush", "Ability.Abysscrush", B.SINGLE_ENEMY, [crush], _jump(0.8), [[0.4, "crush"]])
	_ability("tremor", "Ability.Tremor", B.ALL_ENEMIES, [_row("tremor", "damage", D.SCALED, 70, T.ALL, physical)], _jump(0.7),
		[[0.35, "tremor"]])
	_ability("unmake", "Ability.Unmake", B.SINGLE_ENEMY, [_row("unmake", "damage", D.SCALED, 250, T.ALL, physical)], _spin(0.9),
		[[0.45, "unmake"]], {"sound": ["Explosion1", 0.3, -4.0]})
	_ability("entropy", "Ability.Entropy", B.ALL_ENEMIES, [_row("decay", "damage", D.SCALED, 50, T.ALL, physical),
		_chance(_row("bleed", "bleed", D.USE_EFFECT, 0, T.ALL), 100), _chance(_row("slow", "slow", D.USE_EFFECT, 0, T.ALL), 100)],
		_spin(0.8), [[0.3, "decay"], [0.35, "bleed"], [0.4, "slow"]])
	_ability("silence", "Ability.Silence", B.SINGLE_ENEMY, [_row("hush", "damage", D.SCALED, 60, T.ALL, ice),
		_chance(_row("stun", "stun", D.USE_EFFECT, 0, T.ALL), 50)], _flash(0.6), [[0.3, "hush"], [0.35, "stun"]])
	_ability("oblivion", "Ability.Ult.Oblivion", B.ALL_ENEMIES, [_row("void", "damage", D.SCALED, 220, T.ALL, physical)],
		_spin(1.2), [[0.6, "void"]], ult.merged({"sound": ["Explosion1", 0.5, -2.0]}))


# --- Enemies, bosses and encounters --------------------------------------------------------------------------------------

func _pattern(steps: Array) -> PatternBrain:
	var brain := PatternBrain.new()
	brain.pattern.assign(steps)
	return brain


func _tactical(ult_below: float) -> TacticalBrain:
	var brain := TacticalBrain.new()
	brain.ult_when_party_down = true
	brain.ult_when_ally_hp_below_x100 = Fixed.from_typed(ult_below)
	return brain


func _phase_set(name: String, tags: Array, abilities: Array, effects: Array) -> void:
	var phase := AbilitySet.new()
	phase.tags.assign(tags)
	for ability in abilities:
		phase.abilities.append(_r["abilities/" + ability])
	for effect in effects:
		phase.effects.append(_r["effects/" + effect])
	_save("loadouts/" + name, phase)


func _stats_of(hp: float, atk: float, def: float, spd: float, toughness: float, extra: Dictionary = {}) -> Dictionary:
	return CORE.merged({"max_hp": hp, "hp": hp, "atk": atk, "def": def, "spd": spd, "max_toughness": toughness,
		"toughness": toughness}).merged(extra, true)


## A boss encounter that rewards one Pool.Boss item (spec 3.8: the item source where there are no item rooms).
func _boss_encounter(name: String, title: String, chapter: StringName, slot_specs: Array) -> void:
	var encounter := _built_encounter(name, title, [&"Encounter.Boss", chapter], slot_specs)
	var reward := GiveItem.new()
	reward.item_query = _query([&"Pool.Boss"])
	encounter.rewards.assign([reward])
	_save("encounters/" + name, encounter)


func _enemies_and_encounters() -> void:
	var boss := &"Enemy.Boss"
	var cellar := &"Chapter.Cellar"
	var crypt := &"Chapter.Crypt"
	var forge := &"Chapter.Forge"
	var hollow := &"Chapter.Hollow"
	var cathedral := &"Chapter.Cathedral"
	var vault := &"Chapter.Vault"
	var coven := &"Chapter.Coven"
	var void_tag := &"Chapter.Void"
	# The Cellar: the Rat King.
	_phase_set("rat_king_frenzy", [&"State.Phase.Two"], [], ["haste"])
	_brained("rat_king", "Rat King", Color.SADDLE_BROWN, _stats_of(2400, 300, 180, 115, 120), ["gnaw", "swarm"],
		[boss, &"Enemy.Type.Rat", &"Weakness.Fire"], _pattern([&"Ability.Gnaw", &"Ability.Gnaw", &"Ability.Swarm"]),
		[_phase(50, "rat_king_frenzy", false)])
	_boss_encounter("rat_king", "The Rat King", cellar, [["rat_king", false]])
	# The Crypt: the Bone Warden.
	_phase_set("bone_warden_ward", [&"State.Phase.Two"], [], ["ward", "defense_up"])
	_brained("bone_warden", "Bone Warden", Color.ANTIQUE_WHITE, _stats_of(2600, 280, 240, 85, 200),
		["shield_bash", "bone_wall", "ossuary", "ult_charge_hit"], [boss, &"Enemy.Type.Warden",
		&"Weakness.Fire", &"Immune.Control"], _tactical(40), [_phase(40, "bone_warden_ward", false)])
	_boss_encounter("bone_warden", "The Bone Warden", crypt, [["bone_warden", false]])
	# The Ember Forge.
	_brained("cinder_hound", "Cinder Hound", Color.ORANGE, _stats_of(380, 300, 90, 130, 40), ["searing_bite"],
		[&"Enemy.Type.Hound", &"Resist.Fire", &"Weakness.Ice"], null, [])
	_brained("anvil_guard", "Anvil Guard", Color.DIM_GRAY, _stats_of(700, 260, 300, 80, 120), ["hammer_down", "brace"],
		[&"Enemy.Type.Anvil", &"Resist.Fire", &"Weakness.Ice"], _pattern([&"Ability.Hammerdown", &"Ability.Brace",
		&"Ability.Hammerdown"]), [])
	_brained("smelter", "Smelter", Color.CHOCOLATE, _stats_of(420, 200, 120, 105, 40), ["stoke", "slag"],
		[&"Enemy.Type.Smelter", &"Weakness.Physical"], _pattern([&"Ability.Stoke", &"Ability.Slag", &"Ability.Slag"]), [])
	_phase_set("forgemaster_molten", [&"State.Phase.Two", &"Resist.Fire"], [], ["defense_up"])
	_phase_set("forgemaster_meltdown", [&"State.Phase.Three"], ["meltdown"], [])
	_brained("forgemaster", "Forgemaster", Color.FIREBRICK, _stats_of(4200, 340, 240, 100, 180),
		["forge_hammer", "fire_bolt", "crucible", "ult_charge_hit"], [boss, &"Enemy.Type.Forgemaster", &"Resist.Fire",
		&"Weakness.Ice"], _tactical(50), [_phase(60, "forgemaster_molten", false), _phase(30, "forgemaster_meltdown", true)])
	_brained("brass_colossus", "Brass Colossus", Color.GOLDENROD, _stats_of(6400, 360, 360, 75, 300),
		["piston", "overheat", "ult_charge_hit"], [boss, &"Enemy.Type.Colossus", &"Weakness.Ice", &"Weakness.Physical"],
		_tactical(50), [])
	_encounter("hound_pack", "Hound pack", [forge], [["cinder_hound", null], ["cinder_hound", null], ["cinder_hound", null]])
	_encounter("forge_line", "Forge line", [forge], [["anvil_guard", null], ["smelter", null]])
	_encounter("foundry", "Foundry", [forge], [["cinder_hound", null], ["smelter", null], ["cinder_hound", null]])
	_elite_encounter("iron_anvil", "Iron anvil", [forge], [["anvil_guard", true], ["cinder_hound", false]])
	_boss_encounter("forgemaster", "The Forgemaster", forge, [["forgemaster", false]])
	_boss_encounter("brass_colossus", "The Brass Colossus", forge, [["brass_colossus", false]])
	# The Hollow.
	_brained("leech", "Leech", Color.DARK_RED, _stats_of(360, 260, 80, 120, 30), ["latch"],
		[&"Enemy.Type.Leech", &"Resist.Physical", &"Weakness.Fire"], null, [])
	_brained("gutter_maw", "Gutter Maw", Color.OLIVE_DRAB, _stats_of(900, 300, 140, 80, 60), ["bile", "devour"],
		[&"Enemy.Type.Maw", &"Weakness.Ice"], _pattern([&"Ability.Bile", &"Ability.Devour"]), [])
	_brained("vein_weaver", "Vein Weaver", Color.CRIMSON, _stats_of(440, 240, 100, 115, 40), ["entangle_lash", "hemorrhage"],
		[&"Enemy.Type.Weaver", &"Resist.Ice", &"Weakness.Fire"], _pattern([&"Ability.Entanglelash", &"Ability.Hemorrhage"]), [])
	_phase_set("mother_heart_bleeding", [&"State.Phase.Two"], ["bleeding_out"], [])
	_brained("mother_heart", "Mother Heart", Color.MEDIUM_VIOLET_RED, _stats_of(5500, 320, 220, 90, 200),
		["pulse", "heart_regen", "systole", "ult_charge_hit"], [boss, &"Enemy.Type.Heart", &"Weakness.Fire"],
		_pattern([&"Ability.Pulse", &"Ability.Bleedingout", &"Ability.Pulse", &"Ability.Heartregen"]),
		[_phase(50, "mother_heart_bleeding", false)])
	_brained("heart_left", "Left Heart", Color.INDIAN_RED, _stats_of(3600, 340, 200, 100, 120),
		["pulse", "mend", "twin_beat", "ult_charge_hit"], [boss, &"Enemy.Type.Heart", &"Weakness.Fire"], _tactical(50), [])
	_brained("heart_right", "Right Heart", Color.ROYAL_BLUE, _stats_of(3600, 340, 200, 100, 120),
		["pulse", "mend", "twin_beat", "ult_charge_hit"], [boss, &"Enemy.Type.Heart", &"Weakness.Ice"], _tactical(50), [])
	_encounter("leech_nest", "Leech nest", [hollow], [["leech", null], ["leech", null], ["leech", null]])
	_encounter("gullet", "Gullet", [hollow], [["gutter_maw", null], ["vein_weaver", null]])
	_encounter("vein_knot", "Vein knot", [hollow], [["leech", null], ["vein_weaver", null], ["leech", null]])
	_elite_encounter("great_maw", "Great maw", [hollow], [["gutter_maw", true], ["leech", false]])
	_boss_encounter("mother_heart", "The Mother Heart", hollow, [["mother_heart", false]])
	_boss_encounter("twin_hearts", "The Twin Hearts", hollow, [["heart_left", false], ["heart_right", false]])
	# The Silent Cathedral.
	_brained("choir_seraph", "Choir Seraph", Color.LIGHT_YELLOW, _stats_of(520, 260, 160, 120, 60), ["hymn", "bless"],
		[&"Enemy.Type.Seraph", &"Resist.Ice"], _pattern([&"Ability.Hymn", &"Ability.Bless"]), [])
	_brained("penitent_knight", "Penitent Knight", Color.SLATE_GRAY, _stats_of(900, 360, 340, 85, 120),
		["shield_bash", "provoke"], [&"Enemy.Type.Knight", &"Resist.Physical", &"Immune.Control"],
		_pattern([&"Ability.Provoke", &"Ability.Shieldbash", &"Ability.Shieldbash"]), [])
	_phase_set("judge_two", [&"State.Phase.Two"], [], ["ward"])
	_phase_set("judge_three", [&"State.Phase.Three"], [], ["haste", "defense_up"])
	_brained("hallowed_judge", "Hallowed Judge", Color.WHITE_SMOKE, _stats_of(9000, 400, 300, 105, 240),
		["smite", "dispel", "purify_self", "judgement", "ult_charge_hit"], [boss, &"Enemy.Type.Judge", &"Resist.Fire",
		&"Weakness.Physical"], _tactical(50), [_phase(60, "judge_two", false), _phase(25, "judge_three", true)])
	_encounter("choir", "Choir", [cathedral], [["choir_seraph", null], ["penitent_knight", null]])
	_encounter("penance", "Penance", [cathedral], [["penitent_knight", null], ["choir_seraph", null], ["penitent_knight", null]])
	_elite_encounter("high_penitent", "High penitent", [cathedral], [["penitent_knight", true], ["choir_seraph", false]])
	_boss_encounter("hallowed_judge", "The Hallowed Judge", cathedral, [["hallowed_judge", false]])
	# The Vault.
	_brained("gilded_mimic", "Gilded Mimic", Color.GOLD, _stats_of(600, 420, 150, 125, 60, {"crit_rate": 30}), ["snap"],
		[&"Enemy.Type.Mimic", &"Weakness.Physical"], null, [])
	_brained("vault_sentry", "Vault Sentry", Color.STEEL_BLUE, _stats_of(1100, 360, 380, 80, 160), ["lockdown", "thorn_mail"],
		[&"Enemy.Type.Sentry", &"Drain.Ice", &"Weakness.Fire"], null, [])
	_save("effects/collector_per_item", _infinite({"max_hp": 2, "atk": 2, "def": 2}, true))  # +2% per piece held
	_phase_set("collector_hoard", [&"State.Phase.Two"], [], ["ward", "haste"])
	# The final boss of the light route mirrors the build (H9) and grows per piece held (H10).
	var collector := EnemyDefinition.new()
	collector.id = &"demo.enemy.collector"
	collector.display_name = "The Collector"
	collector.display_color = Color.DARK_GOLDENROD
	collector.attribute_set = _attributes
	_stats(collector, _stats_of(5000, 380, 300, 110, 260))
	for ability in ["appraise", "dispel", "gilded_ray", "liquidate", "ult_charge_hit"]:
		collector.abilities.append(_r["abilities/" + ability])
	collector.tags.assign([boss, &"Enemy.Type.Collector", &"Weakness.Physical"])
	collector.brain = _pattern([&"Ability.Appraise", &"Ability.Gildedray", &"Ability.Dispel"])
	collector.phases.assign([_phase(50, "collector_hoard", false)])
	collector.mirror_party_items = true
	collector.per_item_effect = _r["effects/collector_per_item"]
	_save("enemies/collector", collector)
	_encounter("mimic_den", "Mimic den", [vault], [["gilded_mimic", null], ["gilded_mimic", null]])
	_encounter("strongroom", "Strongroom", [vault], [["vault_sentry", null], ["gilded_mimic", null]])
	_elite_encounter("iron_sentry", "Iron sentry", [vault], [["vault_sentry", true], ["gilded_mimic", false]])
	_boss_encounter("collector", "The Collector", vault, [["collector", false]])
	# The Black Coven.
	_brained("cultist", "Cultist", Color.DARK_MAGENTA, _stats_of(480, 300, 120, 115, 40), ["hex", "curse"],
		[&"Enemy.Type.Cultist", &"Weakness.Physical"], _pattern([&"Ability.Hex", &"Ability.Curse"]), [])
	_brained("bound_demon", "Bound Demon", Color.DARK_RED, _stats_of(1200, 420, 240, 90, 140), ["hellfire", "rend"],
		[&"Enemy.Type.Demon", &"Drain.Fire", &"Weakness.Ice"], _pattern([&"Ability.Hellfire", &"Ability.Rend"]), [])
	_phase_set("witch_two", [&"State.Phase.Two"], [], ["ward"])
	_phase_set("witch_three", [&"State.Phase.Three"], ["hellfire"], ["haste"])
	_brained("high_witch", "High Witch", Color.INDIGO, _stats_of(5500, 400, 260, 110, 220),
		["witch_bolt", "hex_all", "dispel", "doom", "black_mass", "ult_charge_hit"], [boss, &"Enemy.Type.Witch",
		&"Resist.Ice", &"Weakness.Fire"], _tactical(50), [_phase(60, "witch_two", false), _phase(25, "witch_three", true)])
	_encounter("coven", "Coven", [coven], [["cultist", null], ["cultist", null], ["cultist", null]])
	_encounter("summoning", "Summoning", [coven], [["bound_demon", null], ["cultist", null]])
	_elite_encounter("archdemon", "Archdemon", [coven], [["bound_demon", true], ["cultist", false]])
	_boss_encounter("high_witch", "The High Witch", coven, [["high_witch", false]])
	# The Void.
	_brained("void_wraith", "Void Wraith", Color.MIDNIGHT_BLUE, _stats_of(800, 440, 160, 130, 60), ["chill_touch", "fade"],
		[&"Enemy.Type.Wraith", &"Drain.Ice", &"Resist.Physical"], _pattern([&"Ability.Chilltouch", &"Ability.Chilltouch",
		&"Ability.Fade"]), [])
	_brained("abyssal_hulk", "Abyssal Hulk", Color.BLACK, _stats_of(1800, 480, 360, 80, 200), ["abyss_crush", "tremor"],
		[&"Enemy.Type.Hulk", &"Weakness.Fire"], _pattern([&"Ability.Abysscrush", &"Ability.Tremor"]), [])
	_phase_set("nameless_two", [&"State.Phase.Two"], [], ["haste"])
	_phase_set("nameless_three", [&"State.Phase.Three"], [], ["ward", "defense_up"])
	_brained("nameless", "The Nameless", Color.DARK_SLATE_GRAY, _stats_of(9000, 460, 340, 115, 300),
		["unmake", "entropy", "silence", "oblivion", "ult_charge_hit"], [boss, &"Enemy.Type.Nameless", &"Resist.Physical",
		&"Resist.Ice", &"Weakness.Fire"], _tactical(50), [_phase(66, "nameless_two", true), _phase(33, "nameless_three", true)])
	_encounter("wraiths", "Wraiths", [void_tag], [["void_wraith", null], ["void_wraith", null]])
	_encounter("abyss", "Abyss", [void_tag], [["abyssal_hulk", null], ["void_wraith", null]])
	_elite_encounter("deep_hulk", "Deep hulk", [void_tag], [["abyssal_hulk", true], ["void_wraith", false]])
	_boss_encounter("nameless", "The Nameless", void_tag, [["nameless", false]])


# --- Themed items (24) ---------------------------------------------------------------------------------------------------

func _passive(name: String, tag: String, targeting: BattleAbility.Targeting, row_specs: Array, trigger: StringName,
		extras: Dictionary = {}) -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var rows: Array = []
	var keys: Array = []
	for index in row_specs.size():
		var spec: Array = row_specs[index]  # [row id, effect name, mode, typed, damage tags]
		rows.append(_row(spec[0], spec[1], spec[2], spec[3], T.ALL, spec[4] if spec.size() > 4 else []))
		keys.append([0.1 + 0.05 * index, spec[0]])
	_ability(name, tag, targeting, rows, _flash(0.3), keys, extras.merged({"trigger": trigger}))


func _themed_items() -> void:
	var D := ExecutionRow.DamageMode
	var B := BattleAbility.Targeting
	var t := &"Pool.Treasure"
	var s := &"Pool.Shop"
	var b := &"Pool.Boss"
	var party := {"applies_to": ItemDefinition.AppliesTo.PARTY}
	var consumable := ItemDefinition.UseMode.CONSUMABLE
	var cooldown := ItemDefinition.UseMode.COOLDOWN
	var fire := [&"Damage.Type.Fire"]
	var ice := [&"Damage.Type.Ice"]
	# The Ember Forge.
	_save("effects/tempered_edge", _mixed_infinite([["atk", PERCENT, 15], ["toughness_dmg", ADD, 20]]))
	_described("tempered_edge", "Tempered Edge", [t, s, RARE], 7, _ability_set([], ["tempered_edge"]), "+15% ATK, +20% toughness damage.")
	_save("effects/bellows_charge", _instant({"energy": 15}))
	_passive("bellows", "Ability.Passive.Bellows", B.SELF, [["charge", "bellows_charge", D.USE_EFFECT, 0]], &"Event.Damage.Dealt.Break")
	_described("bellows", "Bellows", [t, s, RARE], 7, _ability_set(["bellows"], []), "Breaking an enemy gives +15 ult charge.")
	var quench := _row("quench", "damage", D.FLAT, 150, ExecutionRow.Targets.ALL, ice)
	quench.toughness_x100 = Fixed.from_typed(30)
	_ability("quench_flask", "Ability.Item.Quench", B.ALL_ENEMIES, [quench], _spin(0.6), [[0.3, "quench"]], {"sound": ["Ice5", 0.2, -4.0]})
	_usable("quench_flask", "Quench Flask", [s, COMMON], 4, "quench_flask", consumable, 1, "All enemies: 150 Ice damage.")
	_passive("ember_heart", "Ability.Passive.Emberheart", B.SINGLE_ENEMY, [["flare", "damage", D.FLAT, 50, fire]], &"Event.Damage.Dealt.Fire")
	_described("ember_heart", "Ember Heart", [t, EPIC], 9, _ability_set(["ember_heart"], []), "Fire hits deal 50 more Fire damage.")
	var slag_plate := _mixed_infinite([["def", ADD, 80], ["spd", ADD, -6]])
	slag_plate.granted_tags.assign([&"Resist.Fire"])
	_save("effects/slag_plate", slag_plate)
	_piece("slag_plate", "Slag Plate", "Body", [t, s, RARE], 7, _ability_set([], ["slag_plate"]), "+80 DEF, resist Fire, −6 SPD.")
	_passive("molten_core", "Ability.Passive.Moltencore", B.SINGLE_ENEMY, [["melt", "burn", D.FLAT, 80, fire]], &"Event.Damage.Dealt.Fire")
	_described("molten_core", "Molten Core", [b, LEGENDARY], 12, _ability_set(["molten_core"], []), "Fire hits set the target ablaze: 80 Fire damage for 2 turns.")
	# The Hollow (boss rewards and events: the chapter has no item rooms).
	_save("effects/blood_pact", _infinite({"dmg_mult": 25}, false))
	_passive("blood_pact", "Ability.Passive.Bloodpact", B.SELF, [["price", "bleed", D.USE_EFFECT, 0]], &"Event.Battle.Start")
	_described("blood_pact", "Blood Pact", [b, EPIC], 9, _ability_set(["blood_pact"], ["blood_pact"]), "+25% damage dealt; you start every battle Bleeding.")
	_save("effects/heartstring_heal", _percent_of_max(10))
	_passive("heartstring", "Ability.Passive.Heartstring", B.SELF, [["mend", "heartstring_heal", D.USE_EFFECT, 0]], &"Event.Unit.Killed")
	_described("heartstring", "Heartstring", [b, t, RARE], 7, _ability_set(["heartstring"], []), "Heal 10% of max HP on a kill.")
	_ability("clotting_salve", "Ability.Item.Salve", B.SINGLE_ALLY, [_row("clean", "cleanse", D.USE_EFFECT, 0, ExecutionRow.Targets.ALL),
		_row("regen", "regen", D.USE_EFFECT, 0, ExecutionRow.Targets.ALL)], _flash(0.5), [[0.25, "clean"], [0.3, "regen"]])
	_usable("clotting_salve", "Clotting Salve", [s, b, COMMON], 4, "clotting_salve", consumable, 1, "One ally: cleanse and Regen.")
	_save("effects/scar_ring", _granting([&"Resist.Physical"]))
	_described("scar_ring", "Scar Ring", [b, EPIC], 9, _ability_set([], ["scar_ring"]), "You resist Physical (half damage).")
	var cloak := _infinite({"max_hp": 150}, false)
	cloak.granted_tags.assign([&"Immune.Bleed"])  # spec 3.9: status immunity by tag
	_save("effects/vein_cloak", cloak)
	_piece("vein_cloak", "Vein Cloak", "Body", [b, t, RARE], 7, _ability_set([], ["vein_cloak"]), "+150 max HP, immune to Bleed.")
	_save("effects/second_heart_revive", _percent_of_max(50))
	_ability("second_heart", "Ability.Item.Secondheart", B.SINGLE_DEAD_ALLY, [_row("revive", "second_heart_revive", D.USE_EFFECT, 0,
		ExecutionRow.Targets.ALL)], _spin(0.6), [[0.4, "revive"]], {"sound": ["Raise2", 0.0, -2.0]})
	_usable("second_heart", "Second Heart", [b, LEGENDARY], 12, "second_heart", consumable, 1, "Revive an ally with 50% HP (once).")
	# The Silent Cathedral (boss rewards and the Vault).
	_save("effects/halo", _infinite({"heal_mult": 10}, false))
	_passive("halo", "Ability.Passive.Halo", B.SELF, [["ward", "ward", D.USE_EFFECT, 0]], &"Event.Battle.Start")
	_described("halo", "Halo", [b, EPIC], 9, _ability_set(["halo"], ["halo"]), "Ward at the start of every battle; +10% healing given.")
	_passive("censer", "Ability.Passive.Censer", B.ALL_ALLIES, [["regen", "regen", D.USE_EFFECT, 0]], &"Event.Battle.Start")
	_described("censer", "Censer", [b, RARE], 7, _ability_set(["censer"], []), "The party starts every battle with Regen.")
	_save("effects/relic_shard", _infinite({"crit_rate": 12}, false))
	_described("relic_shard", "Relic Shard", [b, RARE], 7, _ability_set([], ["relic_shard"]), "+12% crit rate.")
	_save("effects/holy_heal", _percent_of_max(20))
	_ability("holy_water", "Ability.Item.Holywater", B.ALL_ALLIES, [_row("clean", "cleanse", D.USE_EFFECT, 0, ExecutionRow.Targets.ALL),
		_row("heal", "holy_heal", D.USE_EFFECT, 0, ExecutionRow.Targets.ALL)], _flash(0.6), [[0.3, "clean"], [0.35, "heal"]])
	_usable("holy_water", "Holy Water", [s, COMMON], 5, "holy_water", cooldown, 3, "The party: cleanse and heal 20% of max HP. Ready again after 3 won battles.")
	_save("effects/vestment", _infinite({"def": 60, "max_mp": 40}, false))
	_piece("vestment", "Vestment", "Body", [b, EPIC], 9, _ability_set([], ["vestment"]), "+60 DEF, +40 max MP.")
	_save("effects/seraph_wing", _infinite({"spd": 12}, false))
	_described("seraph_wing", "Seraph Wing", [b, LEGENDARY], 12, _ability_set([], ["seraph_wing"]), "The whole party: +12 SPD.", party)
	# The Vault.
	_described("gilded_idol", "Gilded Idol", [t, COMMON], 3, null, "Worth 25 coins the moment you pick it up.",
		{"on_pickup": _outcomes([_coins(25)])})
	_described("ledger", "Ledger", [t, RARE], 6, null, "+2 coins for every room you clear.",
		{"on_room_cleared": _outcomes([_coins(2)])})
	_save("effects/golden_fleece", _infinite({"max_hp": 20}, true))
	_described("golden_fleece", "Golden Fleece", [t, EPIC], 9, _ability_set([], ["golden_fleece"]), "+20% max HP.")
	_save("effects/appraisers_loupe", _infinite({"weakness_dmg": 20}, false))
	_described("appraisers_loupe", "Appraiser's Loupe", [t, RARE], 7, _ability_set([], ["appraisers_loupe"]), "+20% weakness damage.")
	_save("effects/crown", _infinite({"atk": 10, "def": 10, "spd": 10}, true))
	_piece("crown", "Crown", "Head", [b, LEGENDARY], 12, _ability_set([], ["crown"]), "+10% ATK, DEF and SPD.")
	_save("effects/mimic_mend", _instant({"hp": 30}))
	_passive("mimic_tooth", "Ability.Passive.Mimictooth", B.SINGLE_ENEMY, [["bleed", "bleed", D.USE_EFFECT, 0]], &"Event.Damage.Dealt.Critical")
	_passive("mimic_mend", "Ability.Passive.Mimicmend", B.SELF, [["mend", "mimic_mend", D.USE_EFFECT, 0]], &"Event.Damage.Dealt.Critical")
	_described("mimic_tooth", "Mimic Tooth", [t, EPIC], 9, _ability_set(["mimic_tooth", "mimic_mend"], []), "Critical hits make the target Bleed and heal you 30 HP.")


# --- Corrupted items (15) and Void Scar ----------------------------------------------------------------------------------

func _corrupted(name: String, title: String, tier: StringName, grants: AbilitySet, description: String, extra: Dictionary = {}) -> void:
	_described("corrupted_" + name, title, [VOID_POOL, CORRUPTED, tier], 0, grants, description, extra)


func _corrupted_items() -> void:
	var D := ExecutionRow.DamageMode
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	var party := {"applies_to": ItemDefinition.AppliesTo.PARTY}
	_save("effects/void_scar", _infinite({"max_hp": -10}, true))  # stacks: each copy is another −10%
	_described("void_scar", "Void Scar", [&"Item.Curse", COMMON], 0, _ability_set([], ["void_scar"]), "−10% max HP. The Void's price; it adds up.")
	# Legendaries.
	_save("effects/corrupted_seal_cost", _infinite({"dmg_taken": 10}, false))
	_passive("corrupted_seal", "Ability.Passive.Corruptedseal", B.SINGLE_ENEMY, [["execute", "damage", D.SCALED, 90, physical]],
		&"Event.Damage.Dealt.Critical", {"asset_tags": FOLLOW_UP})
	_corrupted("executioners_seal", "Corrupted Seal", LEGENDARY, _ability_set(["corrupted_seal"], ["corrupted_seal_cost"]),
		"Critical hits trigger a follow-up: 90% ATK Physical. You take 10% more damage.")
	_save("effects/corrupted_hide", _granting([&"Drain.Physical", &"Drain.Ice", &"Weakness.Fire"]))
	_corrupted("leech_hide", "Corrupted Hide", LEGENDARY, _ability_set([], ["corrupted_hide"]), "You drain Physical and Ice, but you become weak to Fire.")
	var heart := _infinite({"dmg_mult": 20}, false)
	heart.granted_tags.assign([&"Drain.Fire", &"Weakness.Ice", &"Weakness.Physical"])
	_save("effects/corrupted_heart", heart)
	_corrupted("salamander_heart", "Corrupted Heart", LEGENDARY, _ability_set([], ["corrupted_heart"]),
		"You drain Fire and deal +20% damage, but you become weak to Ice and Physical.")
	_save("effects/corrupted_totem", _infinite({"def": 50, "spd": -8}, false))
	_corrupted("guardian_totem", "Corrupted Totem", LEGENDARY, _ability_set([], ["corrupted_totem"]), "The whole party: +50 DEF, −8 SPD.", party)
	_save("effects/corrupted_band_cost", _infinite({"max_hp": -10}, true))
	_passive("corrupted_band", "Ability.Passive.Corruptedband", B.SINGLE_ENEMY, [["riposte", "damage", D.SCALED, 60, physical]],
		&"Event.Damage.Dealt.Critical", {"asset_tags": FOLLOW_UP})
	_piece("corrupted_duelists_band", "Corrupted Band", "Accessory", [VOID_POOL, CORRUPTED, LEGENDARY], 0,
		_ability_set(["corrupted_band"], ["corrupted_band_cost"]), "Critical hits trigger a follow-up: 60% ATK Physical. −10% max HP.")
	# Epics.
	_save("effects/corrupted_brand", _infinite({"dmg_mult": 40, "dmg_taken": 20}, false))
	_corrupted("berserker_brand", "Corrupted Brand", EPIC, _ability_set([], ["corrupted_brand"]), "+40% damage dealt; +20% damage taken.")
	_save("effects/corrupted_bounty", _instant({"energy": 40, "hp": 120}))
	_save("effects/corrupted_bounty_cost", _infinite({"heal_taken": -15}, false))
	_passive("corrupted_bounty", "Ability.Passive.Corruptedbounty", B.SELF, [["bounty", "corrupted_bounty", D.USE_EFFECT, 0]], &"Event.Unit.Killed")
	_corrupted("bounty_mark", "Corrupted Bounty", EPIC, _ability_set(["corrupted_bounty"], ["corrupted_bounty_cost"]),
		"On a kill: +40 ult charge and heal 120 HP. −15% healing received.")
	_save("effects/corrupted_oath_charge", _instant({"energy": 40}))
	_save("effects/corrupted_oath_fury", _buff({"atk": 30}, 2, [&"Status.Buff.AttackUp"]))
	_save("effects/corrupted_oath_cost", _infinite({"toughness_dmg": -20}, false))
	_passive("corrupted_oath", "Ability.Passive.Corruptedoath", B.SELF, [["charge", "corrupted_oath_charge", D.USE_EFFECT, 0],
		["fury", "corrupted_oath_fury", D.USE_EFFECT, 0]], &"Event.Damage.Dealt.Break")
	_corrupted("breakers_oath", "Corrupted Oath", EPIC, _ability_set(["corrupted_oath"], ["corrupted_oath_cost"]),
		"Breaking an enemy: +40 ult charge and +30% ATK for 2 turns. −20% toughness damage.")
	_save("effects/corrupted_mark_cost", _infinite({"crit_rate": -10}, false))
	_passive("corrupted_mark", "Ability.Passive.Corruptedmark", B.SINGLE_ENEMY, [["shot", "damage", D.SCALED, 80, physical]],
		&"Event.Damage.Dealt.Weakness", {"asset_tags": FOLLOW_UP})
	_corrupted("hunters_mark", "Corrupted Mark", EPIC, _ability_set(["corrupted_mark"], ["corrupted_mark_cost"]),
		"Hitting a weakness triggers a follow-up: 80% ATK Physical. −10% crit rate.")
	_save("effects/corrupted_coil_refund", _instant({"energy": 40}))
	_save("effects/corrupted_coil_cost", _infinite({"max_mp": -30}, false))
	_passive("corrupted_coil", "Ability.Passive.Corruptedcoil", B.SELF, [["refund", "corrupted_coil_refund", D.USE_EFFECT, 0]],
		&"Event.Ability.Used.Ultimate")
	_corrupted("overcharge_coil", "Corrupted Coil", EPIC, _ability_set(["corrupted_coil"], ["corrupted_coil_cost"]),
		"After each of your ults, +40 ult charge. −30 max MP.")
	_save("effects/corrupted_fang", _infinite({"broken_dmg": 50, "dmg_mult": -15}, false))
	_corrupted("predators_fang", "Corrupted Fang", EPIC, _ability_set([], ["corrupted_fang"]), "+50% damage to Broken enemies; −15% damage to the rest.")
	_save("effects/corrupted_vampire_heal", _instant({"hp": 35}))
	_save("effects/corrupted_vampire_cost", _infinite({"max_hp": -20}, true))
	_passive("corrupted_vampire", "Ability.Passive.Corruptedvampire", B.SELF, [["drain", "corrupted_vampire_heal", D.USE_EFFECT, 0]],
		&"Event.Damage.Dealt")
	_corrupted("vampire_fang", "Corrupted Vampire Fang", EPIC, _ability_set(["corrupted_vampire"], ["corrupted_vampire_cost"]),
		"Heal 35 HP whenever you deal damage. −20% max HP.")
	_save("effects/corrupted_thorns_cost", _infinite({"def": -40}, false))
	_passive("corrupted_thorns", "Ability.Passive.Corruptedthorns", B.SINGLE_ENEMY, [["thorns", "damage", D.FLAT, 150, physical]],
		&"Event.Damage.Taken")
	_corrupted("thorn_mail", "Corrupted Thorns", EPIC, _ability_set(["corrupted_thorns"], ["corrupted_thorns_cost"]),
		"When hit, strike back for 150 Physical damage. −40 DEF.")
	_save("effects/corrupted_drum", _mixed_infinite([["spd", ADD, 12], ["def", PERCENT, -10]]))
	_corrupted("war_drum", "Corrupted Drum", EPIC, _ability_set([], ["corrupted_drum"]), "The whole party: +12 SPD, −10% DEF.", party)
	_save("effects/corrupted_lantern_cost", _granting([&"Weakness.Fire"]))
	var freeze_row := _chance(_row("freeze", "freeze", D.USE_EFFECT, 0, ExecutionRow.Targets.ALL), 50)
	_ability("corrupted_lantern", "Ability.Passive.Corruptedlantern", B.SINGLE_ENEMY, [freeze_row], _flash(0.3), [[0.15, "freeze"]],
		{"trigger": &"Event.Damage.Dealt.Ice"})
	_corrupted("frost_lantern", "Corrupted Lantern", EPIC, _ability_set(["corrupted_lantern"], ["corrupted_lantern_cost"]),
		"Ice damage Freezes the target half the time, but you become weak to Fire.")


# --- Chapters, floor rules, boss rooms and the Void's altars -------------------------------------------------------------

func _rules(name: String, base: int, most: int, specials: Array) -> FloorGenRules:
	var small: FloorGenRules = _r["floor_rules/small"]
	var rules: FloorGenRules = small.duplicate()
	rules.id = StringName("demo.rules." + name)
	rules.base_rooms = base
	rules.max_rooms = most
	rules.grid_size = Vector2i(11, 10)
	var tags: Array[StringName] = []
	tags.assign(specials)
	rules.special_room_tags = tags
	return _save("floor_rules/" + name, rules)


func _boss_room(name: String, title: String, chapter: StringName) -> void:
	var room: RoomDefinition = _r["rooms/boss"].duplicate(true)
	room.id = StringName("demo.room." + name)
	room.display_name = title
	room.tags.assign([&"Room.Type.Boss", chapter])
	_save("rooms/" + name, room)


func _chapter_def(name: String, title: String, tag: StringName, route: StringName, rules: FloorGenRules,
		rotation: bool) -> void:
	var chapter := ChapterDefinition.new()
	chapter.id = StringName("demo.chapter." + name)
	chapter.display_name = title
	chapter.tags.assign([tag])
	var rooms := GameplayTagQuery.new()
	rooms.require_any_tags.assign([&"Chapter.Demo", tag])
	chapter.room_query = rooms
	chapter.encounter_query = _query([tag], [&"Encounter.Boss"])
	chapter.boss_encounter_query = _query([&"Encounter.Boss", tag])
	chapter.event_query = _query([&"Event.Demo"])
	chapter.floor_gen_rules = rules
	chapter.scaling = _r["scaling/descent"]
	chapter.boss_rotation = rotation
	chapter.route_tag = route
	_save("chapters/" + name, chapter)


func _chapters() -> void:
	var treasure := &"Room.Type.Treasure"
	var shop := &"Room.Type.Shop"
	var altar := &"Room.Type.Altar"
	_boss_room("forge_boss", "Foundry floor", &"Chapter.Forge")
	_boss_room("hollow_boss", "Heart chamber", &"Chapter.Hollow")
	_boss_room("cathedral_boss", "Nave", &"Chapter.Cathedral")
	_boss_room("vault_boss", "The Collector's hall", &"Chapter.Vault")
	_boss_room("coven_boss", "Black altar", &"Chapter.Coven")
	_boss_room("void_boss", "The edge", &"Chapter.Void")
	# The Void's altars: two pedestals of corrupted items, each costing a Void Scar.
	var P := RoomPlacement.Kind
	var players := [_placement(Vector2i(2, 2), P.PLAYER_SPAWN, 1), _placement(Vector2i(2, 4), P.PLAYER_SPAWN, 2),
		_placement(Vector2i(1, 1), P.PLAYER_SPAWN, 3), _placement(Vector2i(1, 5), P.PLAYER_SPAWN, 4)]
	var pedestals := []
	for cell in [Vector2i(5, 3), Vector2i(7, 3)]:
		var pedestal := _placement(cell, P.ITEM_PEDESTAL, 1)
		pedestal.item_query = _query([VOID_POOL])
		pedestal.price_item = _r["items/void_scar"]
		pedestals.append(pedestal)
	var all_doors := RoomDefinition.DOOR_N | RoomDefinition.DOOR_E | RoomDefinition.DOOR_S | RoomDefinition.DOOR_W
	_room("altar", "Altar", [altar, &"Chapter.Void"], all_doors, RoomDefinition.ContentMode.NONE, players + pedestals)
	# The Vault's treasure rooms draw from the item room pool (Pool.Treasure); there is no Vault pool (2026-11-09).
	var hoard := _placement(Vector2i(6, 3), P.ITEM_PEDESTAL, 1)
	var hoard_query := GameplayTagQuery.new()
	hoard_query.require_any_tags.assign([&"Pool.Treasure"])
	hoard.item_query = hoard_query
	_room("hoard", "Hoard", [treasure, &"Chapter.Vault"], all_doors, RoomDefinition.ContentMode.NONE, players + [hoard])
	_chapter_def("forge", "The Ember Forge", &"Chapter.Forge", &"", _rules("forge", 7, 10, [treasure, shop]), true)
	_chapter_def("hollow", "The Hollow", &"Chapter.Hollow", &"", _rules("hollow", 8, 11, []), true)
	_chapter_def("cathedral", "The Silent Cathedral", &"Chapter.Cathedral", &"Route.Light", _rules("cathedral", 8, 11, []), false)
	_chapter_def("vault", "The Vault", &"Chapter.Vault", &"Route.Light",
		_rules("vault", 10, 14, [treasure, treasure, treasure, treasure, shop]), false)
	_chapter_def("coven", "The Black Coven", &"Chapter.Coven", &"Route.Dark", _rules("coven", 8, 11, []), false)
	_chapter_def("void", "The Void", &"Chapter.Void", &"Route.Dark", _rules("void", 9, 13, [altar, altar, altar]), false)
