## One-time builder for spec route-enemies: one elite and two regular enemies for each ending-route chapter (the Silent
## Cathedral, the Vault, the Black Coven, the Void), their abilities, phase sets, effects and encounters, written into
## res://content/demo/ through ResourceSaver like build_full_descent, whose helpers it reuses.
##
## Same rules: it never overwrites (an existing file is skipped and used), it writes nowhere but content/demo/, and it
## never touches an existing file. The tags go into godot_gas/tag_registry.tres by hand (spec route-enemies Q4). Values
## are the spec's starting values, typed as a designer would; tune them in the files.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_route_enemies.tscn
extends "res://game/tools/build_full_descent.gd"

const ELITE := &"Enemy.Rank.Elite"
const PHASE_TWO := &"State.Phase.Two"
## Spec route-enemies 3.3: an elite's encounter weighs 40% of a regular one. The field is typed with 1 as the default
## weight (stored ×100: regulars 100, elites 40), so 40 typed here would make elites 40 times as common.
const ELITE_WEIGHT := 0.4
## Spec route-enemies Q7: Consume's asset tag, so its Event.Ability.Used.Consume triggers the Gorge passive.
const CONSUME_TYPE := &"Ability.Type.Consume"


func _ready() -> void:
	if not ResourceLoader.exists(GENERATED_SET) or load(PERCENT_OF_MAX) == null:
		_quit("Needs %s and %s (run --import once first)." % [GENERATED_SET, PERCENT_OF_MAX])
		return
	_attributes = load(ATTRIBUTES)
	for name in ["damage", "bleed", "burn", "stun", "slow", "vulnerable", "weaken", "haste", "ward", "rally", "cleanse"]:
		_r["effects/" + name] = load(CONTENT + "effects/%s.tres" % name)
	for name in ["strike", "smite", "dispel", "bite", "curse", "tremor", "brace"]:
		_r["abilities/" + name] = load(CONTENT + "abilities/%s.tscn" % name)
	for name in ["rations", "honey_cake", "roast_haunch", "hearty_feast", "halo", "golden_idol", "witchs_eye", "vampire_fang"]:
		_r["items/" + name] = load(CONTENT + "items/%s.tres" % name)
	for name in ["choir_seraph", "gilded_mimic", "vault_sentry", "cultist", "bound_demon", "void_wraith"]:
		_r["enemies/" + name] = load(CONTENT + "enemies/%s.tres" % name)
	for key in _r:
		if _r[key] == null:
			_quit("Missing %s%s" % [CONTENT, key])
			return
	_route_effects()
	_route_moves()
	_route_enemies()
	print("build_route_enemies: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _made:
		print("  made    ", path)
	for path in _skipped:
		print("  skipped ", path)
	for path in _failed:
		print("  FAILED  ", path)
	get_tree().quit(1 if not _failed.is_empty() else 0)


# --- Effects (spec 3.6) --------------------------------------------------------------------------------------------------

func _route_effects() -> void:
	_save("effects/sp_drain_15", _instant({"mp": -15}))  # Levy; the attribute set clamps mp at 0
	_save("effects/vigil_heal", _percent_of_max(10))
	_save("effects/cauldron_brew_heal", _percent_of_max(12))
	_save("effects/hoard_greed_heal", _percent_of_max(10))
	_save("effects/gorge_heal", _percent_of_max(10))
	_save("effects/gravity_pull", GameplayEffect.new())  # instant and empty: the row lands, so its delay applies


# --- Abilities (spec 3.1, 3.2, 3.4, 3.5) ---------------------------------------------------------------------------------

func _delayed(row: ExecutionRow, typed: float) -> ExecutionRow:
	row.delay_x100 = Fixed.from_typed(typed)
	return row


func _route_moves() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	var fire := [&"Damage.Type.Fire"]
	var ice := [&"Damage.Type.Ice"]
	var consume := {"asset_tags": [CONSUME_TYPE]}
	# The Silent Cathedral.
	_ability("toll", "Ability.Toll", B.ALL_ENEMIES, [_delayed(_row("toll", "damage", D.SCALED, 50, T.ALL, physical), 20)],
		_spin(0.7), [[0.35, "toll"]], {"sound": ["Chime1", 0.2, -4.0]})
	_ability("votive_flame", "Ability.Votiveflame", B.SINGLE_ENEMY, [_row("flame", "damage", D.SCALED, 110, T.ALL, fire),
		_chance(_row("burn", "burn", D.FLAT, 50, T.ALL, fire), 60)], _flash(0.5), [[0.25, "flame"], [0.3, "burn"]],
		{"sound": ["Fire1", 0.2, -8.0]})
	_ability("vigil", "Ability.Vigil", B.ALL_ALLIES, [_row("heal", "vigil_heal", D.USE_EFFECT, 0, T.ALL),
		_row("cleanse", "cleanse", D.USE_EFFECT, 0, T.ALL)], _flash(0.6), [[0.3, "heal"], [0.35, "cleanse"]])
	_ability("prism_ray", "Ability.Prismray", B.ALL_ENEMIES, [_row("ray", "damage", D.SCALED, 70, T.ALL, ice),
		_chance(_row("expose", "vulnerable", D.USE_EFFECT, 0, T.ALL), 40)], _spin(0.8), [[0.4, "ray"], [0.45, "expose"]],
		{"sound": ["Ice2", 0.3, -6.0]})
	_ability("stained_ward", "Ability.Stainedward", B.ALL_ALLIES, [_row("ward", "ward", D.USE_EFFECT, 0, T.ALL)], _flash(0.5),
		[[0.25, "ward"]])
	_ability("shard_rain", "Ability.Shardrain", B.ALL_ENEMIES, [_row("shards", "damage", D.SCALED, 60, T.ALL, physical),
		_chance(_row("bleed", "bleed", D.USE_EFFECT, 0, T.ALL), 50)], _spin(0.8), [[0.4, "shards"], [0.45, "bleed"]])
	# The Vault.
	_ability("levy", "Ability.Levy", B.SINGLE_ENEMY, [_row("levy", "damage", D.SCALED, 80, T.ALL, physical),
		_row("tax", "sp_drain_15", D.USE_EFFECT, 0, T.ALL)], _jump(0.5), [[0.25, "levy"], [0.3, "tax"]])
	_ability("stone_gaze", "Ability.Stonegaze", B.SINGLE_ENEMY, [_row("gaze", "damage", D.SCALED, 60, T.ALL, physical),
		_chance(_row("stun", "stun", D.USE_EFFECT, 0, T.ALL), 45)], _flash(0.6), [[0.3, "gaze"], [0.35, "stun"]])
	_ability("gilded_breath", "Ability.Gildedbreath", B.ALL_ENEMIES, [_row("breath", "damage", D.SCALED, 75, T.ALL, fire),
		_chance(_row("burn", "burn", D.FLAT, 50, T.ALL, fire), 50)], _spin(0.8), [[0.4, "breath"], [0.45, "burn"]],
		{"sound": ["Fire2", 0.3, -6.0]})
	# The Hoard Drake's phase copy of Gilded Breath, its pattern's fourth step (a step it lacks falls back to Bite).
	_ability("fury_breath", "Ability.Furybreath", B.ALL_ENEMIES, [_row("breath", "damage", D.SCALED, 75, T.ALL, fire),
		_chance(_row("burn", "burn", D.FLAT, 50, T.ALL, fire), 50)], _spin(0.8), [[0.4, "breath"], [0.45, "burn"]],
		{"sound": ["Fire2", 0.3, -6.0]})
	_ability("hoard_greed", "Ability.Hoardgreed", B.SELF, [_row("rally", "rally", D.USE_EFFECT, 0, T.ALL),
		_row("heal", "hoard_greed_heal", D.USE_EFFECT, 0, T.ALL)], _flash(0.5), [[0.25, "rally"], [0.3, "heal"]])
	# The Black Coven.
	_ability("pinprick", "Ability.Pinprick", B.SINGLE_ENEMY, [_row("prick", "damage", D.SCALED, 70, T.ALL, physical),
		_chance(_row("bleed", "bleed", D.USE_EFFECT, 0, T.ALL), 60)], _jump(0.5), [[0.25, "prick"], [0.3, "bleed"]])
	_ability("ill_omen", "Ability.Illomen", B.ALL_ENEMIES, [_row("omen", "damage", D.SCALED, 40, T.ALL, ice),
		_chance(_row("slow", "slow", D.USE_EFFECT, 0, T.ALL), 50)], _flash(0.6), [[0.3, "omen"], [0.35, "slow"]])
	# hex_all needs the High Witch's State.Phase.Two, so the Hag Sister has her own.
	_ability("hag_hex", "Ability.Haghex", B.ALL_ENEMIES, [_chance(_row("hex", "vulnerable", D.USE_EFFECT, 0, T.ALL), 50),
		_chance(_row("weaken", "weaken", D.USE_EFFECT, 0, T.ALL), 50)], _flash(0.6), [[0.3, "hex"], [0.35, "weaken"]])
	_ability("boil_over", "Ability.Boilover", B.ALL_ENEMIES, [_row("boil", "damage", D.SCALED, 65, T.ALL, fire),
		_chance(_row("burn", "burn", D.FLAT, 45, T.ALL, fire), 50)], _spin(0.8), [[0.4, "boil"], [0.45, "burn"]],
		{"sound": ["Fire2", 0.3, -6.0]})
	_ability("bitter_boil", "Ability.Bitterboil", B.ALL_ENEMIES, [_row("boil", "damage", D.SCALED, 65, T.ALL, fire),
		_chance(_row("burn", "burn", D.FLAT, 45, T.ALL, fire), 50)], _spin(0.8), [[0.4, "boil"], [0.45, "burn"]],
		{"sound": ["Fire2", 0.3, -6.0]})
	_ability("cauldron_brew", "Ability.Cauldronbrew", B.ALL_ALLIES, [_row("heal", "cauldron_brew_heal", D.USE_EFFECT, 0, T.ALL),
		_row("rally", "rally", D.USE_EFFECT, 0, T.ALL)], _flash(0.6), [[0.3, "heal"], [0.35, "rally"]])
	# The Void.
	_ability("dim_wings", "Ability.Dimwings", B.ALL_ENEMIES, [_row("wings", "damage", D.SCALED, 40, T.ALL, ice),
		_chance(_row("weaken", "weaken", D.USE_EFFECT, 0, T.ALL), 40)], _flash(0.6), [[0.3, "wings"], [0.35, "weaken"]])
	_ability("echo_strike", "Ability.Echostrike", B.SINGLE_ENEMY, [_row("strike", "damage", D.SCALED, 50, T.ALL, physical),
		_row("echo", "damage", D.SCALED, 50, T.ALL, physical)], _jump(0.7), [[0.25, "strike"], [0.45, "echo"]])
	# Resound (spec Q7): strikes back only when hit on its weakness, so it never answers the party's Physical counters.
	_passive("resound", "Ability.Passive.Resound", B.SINGLE_ENEMY, [["resound", "damage", D.SCALED, 40, physical]],
		&"Event.Damage.Taken.Weakness")
	_ability("consume", "Ability.Consume", B.SINGLE_ENEMY, [_row("consume", "damage", D.SCALED, 120, T.ALL, physical)],
		_jump(0.8), [[0.4, "consume"]], consume.merged({"sound": ["Blow4", 0.3, -4.0]}))
	# The Void Devourer's phase copy of Consume (it heals through Gorge too).
	_ability("ravenous_maw", "Ability.Ravenousmaw", B.SINGLE_ENEMY, [_row("consume", "damage", D.SCALED, 120, T.ALL, physical)],
		_jump(0.8), [[0.4, "consume"]], consume.merged({"sound": ["Blow4", 0.3, -4.0]}))
	_passive("gorge", "Ability.Passive.Gorge", B.SELF, [["gorge", "gorge_heal", D.USE_EFFECT, 0]], &"Event.Ability.Used.Consume")
	# Gravity Well: no damage; its delay rides an empty instant effect that always lands.
	_ability("gravity_well", "Ability.Gravitywell", B.ALL_ENEMIES, [_delayed(_row("pull", "gravity_pull", D.USE_EFFECT, 0,
		T.ALL), 25), _chance(_row("slow", "slow", D.USE_EFFECT, 0, T.ALL), 40)], _spin(0.9), [[0.45, "pull"], [0.5, "slow"]])


# --- Enemies, phase sets and encounters ----------------------------------------------------------------------------------

func _route_enemy(name: String, title: String, color: Color, stats: Dictionary, abilities: Array, tags: Array,
		brain: EnemyBrain, phases: Array, drop: String, drop_chance: float) -> void:
	var enemy := EnemyDefinition.new()
	enemy.id = StringName("demo.enemy." + name)
	enemy.display_name = title
	enemy.display_color = color
	enemy.attribute_set = _attributes
	_stats(enemy, stats)
	for ability in abilities:
		enemy.abilities.append(_r["abilities/" + ability])
	enemy.tags.assign(tags)
	enemy.brain = brain
	enemy.phases.assign(phases)
	enemy.drop_item = _r["items/" + drop]
	enemy.drop_chance_x100 = Fixed.from_typed(drop_chance)
	_save("enemies/" + name, enemy)


## A regular encounter (default weight 1) or an elite one (ELITE_WEIGHT); slots are enemy names, no variant.
func _route_encounter(name: String, title: String, chapter: StringName, enemies: Array, elite: bool) -> void:
	var slots: Array = []
	for enemy in enemies:
		slots.append([enemy, false])
	var encounter := _built_encounter(name, title, [chapter], slots)
	if elite:
		encounter.weight_x100 = Fixed.from_typed(ELITE_WEIGHT)
	_save("encounters/" + name, encounter)


func _route_enemies() -> void:
	var cathedral := &"Chapter.Cathedral"
	var vault := &"Chapter.Vault"
	var coven := &"Chapter.Coven"
	var void_tag := &"Chapter.Void"
	# Each elite: Haste and one extra ability at 50% HP. The extra ability is its pattern's fourth step; before the
	# phase that step falls back to the first ability it has (EnemyBrain's default), like the Golem's Rockfall.
	_phase_set("glass_saint_cracked", [PHASE_TWO], ["shard_rain"], ["haste"])
	_phase_set("hoard_drake_fury", [PHASE_TWO], ["fury_breath"], ["haste"])
	_phase_set("hag_sister_bitter", [PHASE_TWO], ["bitter_boil"], ["haste"])
	_phase_set("void_devourer_starving", [PHASE_TWO], ["ravenous_maw"], ["haste"])
	# The Silent Cathedral.
	_route_enemy("bell_ringer", "Bell Ringer", Color.BURLYWOOD, _stats_of(640, 300, 180, 110, 80), ["toll", "strike"],
		[&"Enemy.Type.Ringer", &"Weakness.Fire"], _pattern([&"Ability.Toll", &"Ability.Strike", &"Ability.Strike"]), [],
		"rations", 5)
	_route_enemy("candle_acolyte", "Candle Acolyte", Color.LEMON_CHIFFON, _stats_of(480, 320, 140, 125, 60),
		["votive_flame", "vigil"], [&"Enemy.Type.Acolyte", &"Resist.Fire", &"Weakness.Ice"],
		_pattern([&"Ability.Votiveflame", &"Ability.Votiveflame", &"Ability.Vigil"]), [], "honey_cake", 5)
	_route_enemy("glass_saint", "Glass Saint", Color.LIGHT_CYAN, _stats_of(2600, 380, 260, 100, 240),
		["smite", "prism_ray", "stained_ward"], [&"Enemy.Type.Saint", ELITE, &"Resist.Ice", &"Resist.Fire",
		&"Weakness.Physical"], _pattern([&"Ability.Prismray", &"Ability.Stainedward", &"Ability.Smite", &"Ability.Shardrain"]),
		[_phase(50, "glass_saint_cracked", false)], "halo", 25)
	_route_encounter("bell_tower", "Bell tower", cathedral, ["bell_ringer", "bell_ringer"], false)
	_route_encounter("vespers", "Vespers", cathedral, ["candle_acolyte", "bell_ringer", "choir_seraph"], false)
	_route_encounter("glass_saint", "Glass saint", cathedral, ["glass_saint", "candle_acolyte"], true)
	# The Vault.
	_route_enemy("tally_clerk", "Tally Clerk", Color.TAN, _stats_of(460, 280, 150, 135, 60), ["levy", "dispel"],
		[&"Enemy.Type.Clerk", &"Weakness.Fire"], _pattern([&"Ability.Levy", &"Ability.Levy", &"Ability.Dispel"]), [],
		"roast_haunch", 5)
	_route_enemy("vault_gargoyle", "Vault Gargoyle", Color.SLATE_GRAY, _stats_of(900, 340, 360, 90, 140),
		["stone_gaze", "brace"], [&"Enemy.Type.Gargoyle", &"Resist.Physical", &"Weakness.Ice"],
		_pattern([&"Ability.Stonegaze", &"Ability.Brace", &"Ability.Stonegaze"]), [], "hearty_feast", 4)
	_route_enemy("hoard_drake", "Hoard Drake", Color.GOLDENROD, _stats_of(3000, 420, 240, 115, 220),
		["bite", "gilded_breath", "hoard_greed"], [&"Enemy.Type.Drake", ELITE, &"Resist.Fire", &"Weakness.Ice"],
		_pattern([&"Ability.Bite", &"Ability.Gildedbreath", &"Ability.Hoardgreed", &"Ability.Furybreath"]),
		[_phase(50, "hoard_drake_fury", false)], "golden_idol", 25)
	_route_encounter("counting_house", "Counting house", vault, ["tally_clerk", "tally_clerk", "gilded_mimic"], false)
	_route_encounter("gargoyle_watch", "Gargoyle watch", vault, ["vault_gargoyle", "vault_sentry"], false)
	_route_encounter("drake_lair", "Drake lair", vault, ["hoard_drake", "tally_clerk"], true)
	# The Black Coven.
	_route_enemy("hex_doll", "Hex Doll", Color.PLUM, _stats_of(500, 300, 130, 120, 50), ["pinprick", "curse"],
		[&"Enemy.Type.Doll", &"Weakness.Fire"], _pattern([&"Ability.Pinprick", &"Ability.Curse", &"Ability.Pinprick"]), [],
		"honey_cake", 5)
	_route_enemy("coven_familiar", "Coven Familiar", Color.DARK_SLATE_BLUE, _stats_of(420, 280, 120, 145, 50),
		["ill_omen", "bite"], [&"Enemy.Type.Familiar", &"Resist.Ice", &"Weakness.Fire"],
		_pattern([&"Ability.Illomen", &"Ability.Bite", &"Ability.Bite"]), [], "rations", 5)
	# Hag's Hex first: before the phase her fourth step falls back to it, after it Bitter Boil is a second Boil Over.
	_route_enemy("hag_sister", "Hag Sister", Color.DARK_OLIVE_GREEN, _stats_of(2700, 390, 220, 105, 200),
		["hag_hex", "boil_over", "cauldron_brew"], [&"Enemy.Type.Hag", ELITE, &"Resist.Fire", &"Weakness.Physical"],
		_pattern([&"Ability.Boilover", &"Ability.Haghex", &"Ability.Cauldronbrew", &"Ability.Bitterboil"]),
		[_phase(50, "hag_sister_bitter", false)], "witchs_eye", 25)
	_route_encounter("doll_circle", "Doll circle", coven, ["hex_doll", "hex_doll", "cultist"], false)
	_route_encounter("familiars", "Familiars", coven, ["coven_familiar", "coven_familiar", "bound_demon"], false)
	_route_encounter("hag_sister", "Hag sister", coven, ["hag_sister", "coven_familiar"], true)
	# The Void.
	_route_enemy("null_moth", "Null Moth", Color.LAVENDER, _stats_of(440, 290, 120, 140, 50), ["dim_wings", "bite"],
		[&"Enemy.Type.Moth", &"Weakness.Physical"], _pattern([&"Ability.Dimwings", &"Ability.Bite", &"Ability.Bite"]), [],
		"roast_haunch", 4)
	_route_enemy("hollow_echo", "Hollow Echo", Color.LIGHT_SLATE_GRAY, _stats_of(700, 330, 220, 115, 100),
		["echo_strike", "strike", "resound"], [&"Enemy.Type.Echo", &"Resist.Fire", &"Weakness.Ice"],
		_pattern([&"Ability.Echostrike", &"Ability.Strike", &"Ability.Echostrike"]), [], "hearty_feast", 4)
	_route_enemy("void_devourer", "Void Devourer", Color.DARK_SLATE_GRAY, _stats_of(3100, 430, 250, 100, 230),
		["tremor", "consume", "gravity_well", "gorge"], [&"Enemy.Type.Devourer", ELITE, &"Resist.Ice", &"Weakness.Physical"],
		_pattern([&"Ability.Gravitywell", &"Ability.Consume", &"Ability.Tremor", &"Ability.Ravenousmaw"]),
		[_phase(50, "void_devourer_starving", false)], "vampire_fang", 25)
	_route_encounter("moth_swarm", "Moth swarm", void_tag, ["null_moth", "null_moth", "null_moth"], false)
	_route_encounter("echoes", "Echoes", void_tag, ["hollow_echo", "void_wraith"], false)
	_route_encounter("devourer", "Devourer", void_tag, ["void_devourer", "null_moth"], true)
