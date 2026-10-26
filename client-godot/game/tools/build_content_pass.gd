## One-time builder for the content-pass content (spec content-pass 3.4, 3.6): statuses, the break effects, the new
## enemies and the Lich, items and armor that use them, Provoke, Purify and the Golem's Rockfall, written into
## res://content/demo/ through ResourceSaver like build_item_pass.
##
## Same rules as build_demo, whose helpers it reuses: it never overwrites (an existing file is skipped and used), it
## writes nowhere but content/demo/, and it never touches an existing file. Edits to existing demo files (the Golem,
## the characters, the five existing ults) are made by hand with your approval, not here.
## Values are starting values, typed as a designer would; tune them in the files.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_content_pass.tscn
extends "res://game/tools/build_item_pass.gd"

const REFRESH := GameplayEffect.StackingPolicy.REFRESH_DURATION


func _ready() -> void:
	if not ResourceLoader.exists(GENERATED_SET) or load(PERCENT_OF_MAX) == null:
		_quit("Needs %s and %s (run --import once first)." % [GENERATED_SET, PERCENT_OF_MAX])
		return
	_attributes = load(ATTRIBUTES)
	for name in ["damage", "ult_cost", "mp_cost_heal", "burn"]:
		_r["effects/" + name] = load(CONTENT + "effects/%s.tres" % name)
	for name in ["ult_charge_hit"]:
		_r["abilities/" + name] = load(CONTENT + "abilities/%s.tscn" % name)
	_statuses()
	_abilities_and_kits()
	_new_items()
	_new_armor()
	_new_enemies()
	print("build_content_pass: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _made:
		print("  made    ", path)
	for path in _skipped:
		print("  skipped ", path)
	for path in _failed:
		print("  FAILED  ", path)
	get_tree().quit(1 if not _failed.is_empty() else 0)


# --- Statuses (spec 3.4) -------------------------------------------------------------------------------------------------

func _statuses() -> void:
	var not_controlled := _query([], [&"State.Controlled"])
	_save("queries/not_controlled", not_controlled)
	var not_immune := _query([], [&"Immune.Control"])
	# DoTs and HoTs: tick at the holder's turn start.
	_save("effects/bleed", _refresh(_percent_dot(-6, 2, [&"Status.Debuff.Bleed"])))      # 6% of max HP per tick
	var poison := _tagged([&"Status.Debuff.Poison"], 3)
	poison.period = 1.0
	poison.modifiers.append(_modifier("hp", ADD, -25))                                      # 25 HP per stack per tick
	_save("effects/poison", _refresh(poison, 5))
	_save("effects/regen", _refresh(_percent_dot(6, 2, [&"Status.Buff.Regen"])))
	# Stat ups and downs (percent of the stat, 2 turns).
	_save("effects/attack_down", _refresh(_buff({"atk": -15}, 2, [&"Status.Debuff.AttackDown"])))
	_save("effects/defense_up", _refresh(_buff({"def": 30}, 2, [&"Status.Buff.DefenseUp"])))
	_save("effects/defense_down", _refresh(_buff({"def": -25}, 2, [&"Status.Debuff.DefenseDown"])))
	_save("effects/haste", _refresh(_buff({"spd": 15}, 2, [&"Status.Buff.Haste"])))
	_save("effects/slow", _refresh(_buff({"spd": -15}, 2, [&"Status.Debuff.Slow"])))
	_save("effects/vulnerable", _refresh(_buff({"dmg_taken": 10}, 2, [&"Status.Debuff.Vulnerable"]), 3))
	_save("effects/weaken", _refresh(_buff({"dmg_mult": -15}, 2, [&"Status.Debuff.Weaken"])))
	# Control (State.Controlled: the turn is skipped) and its counters.
	var freeze := _refresh(_tagged([&"Status.Debuff.Freeze", &"State.Controlled"], 1))
	freeze.application_query = not_immune
	_save("effects/freeze", freeze)
	var stun := _refresh(_tagged([&"Status.Debuff.Stun", &"State.Controlled"], 1))
	stun.application_query = not_immune
	_save("effects/stun", stun)
	_save("effects/entangle", _refresh(_buff({"spd": -10}, 2, [&"Status.Debuff.Entangle"])))  # + a 30% delay on the row
	_save("effects/taunt", _refresh(_tagged([&"Status.Buff.Taunt", &"State.Taunting"], 2)))
	_save("effects/ward", _refresh(_tagged([&"Status.Buff.Ward", &"Immune.Control"], 2)))
	var cleanse := GameplayEffect.new()
	cleanse.policy = GameplayEffect.DurationPolicy.INSTANT
	cleanse.remove_effects_with_tags.assign([&"Status.Debuff"])
	_save("effects/cleanse", cleanse)
	var dispel := GameplayEffect.new()
	dispel.policy = GameplayEffect.DurationPolicy.INSTANT
	dispel.remove_effects_with_tags.assign([&"Status.Buff"])
	_save("effects/dispel", dispel)
	_save("effects/interrupt_fury", _refresh(_buff({"atk": 15}, 1, [&"Status.Buff.AttackUp"])))
	# Affinities and other worn effects.
	_save("effects/salamander_heart", _granting([&"Drain.Fire", &"Weakness.Ice"]))
	_save("effects/frostguard_charm", _granting([&"Resist.Ice"]))
	_save("effects/leech_hide", _granting([&"Drain.Physical"]))
	_save("effects/warden_helm", _granting([&"Immune.Control"]))
	# Spec content-pass D13: Witch's Eye adds a turn to the holder's debuffs (H8); Hexbreaker Charm Wards at battle start.
	_save("effects/witchs_eye", _infinite({"debuff_turns": 1}, false))
	# Instants for triggered passives.
	_save("effects/overcharge_refund", _instant({"energy": 20}))
	_save("effects/siphon_charge", _instant({"energy": 10}))
	_save("effects/mirror_heal", _instant({"hp": 60}))
	# Toxic Echo's follow-up only lands on a poisoned target (the effect's application query).
	var echo := GameplayEffect.new()
	echo.policy = GameplayEffect.DurationPolicy.INSTANT
	echo.executions.append(load(DAMAGE_CALC).new())
	echo.application_query = _query([&"Status.Debuff.Poison"])
	_save("effects/toxic_echo_damage", echo)


## REFRESH_DURATION with `max_stacks` (1: reapplying refreshes the duration; more: stacks that each count).
func _refresh(effect: GameplayEffect, max_stacks: int = 1) -> GameplayEffect:
	effect.stacking_policy = REFRESH
	effect.max_stacks = max_stacks
	return effect


## A turn-based tick of `typed`% of max HP (negative: damage), with the heal multipliers on heals.
func _percent_dot(typed: float, turns: int, granted: Array) -> GameplayEffect:
	var effect := _tagged(granted, turns)
	effect.period = 1.0
	var calc: GameplayExecutionCalculation = load(PERCENT_OF_MAX).new()
	calc.set("percent_x100", Fixed.from_typed(typed))
	if typed > 0:
		calc.set("target_bonus", "heal_taken")
	effect.executions.append(calc)
	return effect


func _granting(tags: Array) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INFINITE
	effect.granted_tags.assign(tags)
	return effect


func _chance(row: ExecutionRow, typed: float) -> ExecutionRow:
	row.chance_x100 = Fixed.from_typed(typed)
	return row


# --- Abilities (party kits, break effects, item passives, enemy moves) ---------------------------------------------------

func _abilities_and_kits() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	var fire := [&"Damage.Type.Fire"]
	var ice := [&"Damage.Type.Ice"]
	var ult := {"cost": "ult_cost", "asset_tags": [BattleAbility.ULTIMATE_TAG], "query": _r["queries/not_controlled"]}
	# Party skills (added to the Warrior and the Cleric by hand, with your approval).
	_ability("provoke", "Ability.Provoke", B.SELF, [_row("taunt", "taunt", D.USE_EFFECT, 0, T.ALL),
		_row("guard", "defense_up", D.USE_EFFECT, 0, T.ALL)], _jump(0.6), [[0.25, "taunt"], [0.3, "guard"]],
		{"sound": ["Buff", 0.0, -4.0]})
	_ability("purify", "Ability.Purify", B.ALL_ALLIES, [_row("cleanse", "cleanse", D.USE_EFFECT, 0, T.ALL),
		_row("regen", "regen", D.USE_EFFECT, 0, T.ALL)], _flash(0.6), [[0.3, "cleanse"], [0.35, "regen"]],
		{"cost": "mp_cost_heal", "sound": ["Recovery5", 0.1, -4.0]})
	# Break effects (HSR, spec D2): on the breaker, one per damage type, triggered by Event.Damage.Dealt.Break.<Type>.
	_ability("break_physical", "Ability.Passive.Break.Physical", B.SINGLE_ENEMY,
		[_row("burst", "damage", D.SCALED, 100, T.ALL, physical), _row("bleed", "bleed", D.USE_EFFECT, 0, T.ALL)],
		_flash(0.4), [[0.15, "burst"], [0.2, "bleed"]], {"trigger": &"Event.Damage.Dealt.Break.Physical", "sound": ["Blow4", 0.1, -6.0]})
	_ability("break_fire", "Ability.Passive.Break.Fire", B.SINGLE_ENEMY,
		[_row("burst", "damage", D.SCALED, 50, T.ALL, fire), _row("burn", "burn", D.FLAT, 40, T.ALL, fire)],
		_flash(0.4), [[0.15, "burst"], [0.2, "burn"]], {"trigger": &"Event.Damage.Dealt.Break.Fire", "sound": ["Fire2", 0.1, -6.0]})
	_ability("break_ice", "Ability.Passive.Break.Ice", B.SINGLE_ENEMY,
		[_row("burst", "damage", D.SCALED, 50, T.ALL, ice), _chance(_row("freeze", "freeze", D.USE_EFFECT, 0, T.ALL), 65)],
		_flash(0.4), [[0.15, "burst"], [0.2, "freeze"]], {"trigger": &"Event.Damage.Dealt.Break.Ice", "sound": ["Ice2", 0.1, -6.0]})
	# Item and armor passives.
	_ability("frost_lantern", "Ability.Passive.Frostlantern", B.SINGLE_ENEMY,
		[_chance(_row("freeze", "freeze", D.USE_EFFECT, 0, T.ALL), 25)], _flash(0.3), [[0.15, "freeze"]],
		{"trigger": &"Event.Damage.Dealt.Ice"})
	_ability("serrated_edge", "Ability.Passive.Serratededge", B.SINGLE_ENEMY, [_row("bleed", "bleed", D.USE_EFFECT, 0, T.ALL)],
		_flash(0.3), [[0.15, "bleed"]], {"trigger": &"Event.Damage.Dealt.Critical"})
	_ability("toxic_echo", "Ability.Passive.Toxicecho", B.SINGLE_ENEMY,
		[_row("echo", "toxic_echo_damage", D.SCALED, 30, T.ALL, physical)], _jump(0.5), [[0.25, "echo"]],
		{"trigger": &"Event.Damage.Dealt.Weakness", "asset_tags": FOLLOW_UP, "sound": ["Attack1", 0.2, -10.0]})
	_ability("overcharge_coil", "Ability.Passive.Overcharge", B.SELF, [_row("refund", "overcharge_refund", D.USE_EFFECT, 0, T.ALL)],
		_still(0.05), [[0.0, "refund"]], {"trigger": &"Event.Ability.Used.Ultimate"})
	_ability("interrupters_badge", "Ability.Passive.Interrupter", B.SELF,
		[_row("fury", "interrupt_fury", D.USE_EFFECT, 0, T.ALL)], _still(0.05), [[0.0, "fury"]],
		{"trigger": &"Event.Battle.Interrupt"})
	_ability("shatterpoint", "Ability.Passive.Shatterpoint", B.SINGLE_ENEMY,
		[_row("crack", "vulnerable", D.USE_EFFECT, 0, T.ALL)], _flash(0.3), [[0.15, "crack"]],
		{"trigger": &"Event.Damage.Dealt.Break.Ice"})
	_ability("mirror_ward", "Ability.Passive.Mirrorward", B.SELF, [_row("mend", "mirror_heal", D.USE_EFFECT, 0, T.ALL)],
		_still(0.05), [[0.0, "mend"]], {"trigger": &"Event.Status.Resisted"})
	_ability("last_rites", "Ability.Passive.Lastrites", B.SELF, [_row("regen", "regen", D.USE_EFFECT, 0, T.ALL)],
		_still(0.05), [[0.0, "regen"]], {"trigger": &"Event.Unit.Killed"})
	_ability("siphon_sigil", "Ability.Passive.Siphon", B.SELF, [_row("charge", "siphon_charge", D.USE_EFFECT, 0, T.ALL)],
		_still(0.05), [[0.0, "charge"]], {"trigger": &"Event.Damage.Taken.Drained"})
	_ability("thornbark_mail", "Ability.Passive.Thornbark", B.SINGLE_ENEMY, [_row("poison", "poison", D.USE_EFFECT, 0, T.ALL)],
		_flash(0.3), [[0.15, "poison"]], {"trigger": &"Event.Damage.Taken"})
	_ability("tacticians_ring", "Ability.Passive.Tactician", B.SELF, [_row("taunt", "taunt", D.USE_EFFECT, 0, T.ALL)],
		_jump(0.4), [[0.2, "taunt"]], {"trigger": &"Event.Battle.Start"})
	_ability("hexbreaker_charm", "Ability.Passive.Hexbreaker", B.SELF, [_row("ward", "ward", D.USE_EFFECT, 0, T.ALL)],
		_jump(0.4), [[0.2, "ward"]], {"trigger": &"Event.Battle.Start"})
	# Usable items.
	_ability("plague_flask", "Ability.Item.Plague", B.ALL_ENEMIES, [_row("poison", "poison", D.USE_EFFECT, 0, T.ALL)],
		_jump(0.6), [[0.3, "poison"], [0.4, "poison"]], {"sound": ["Poison", 0.2, -4.0]})
	_ability("purifying_bell", "Ability.Item.Bell", B.ALL_ALLIES, [_row("cleanse", "cleanse", D.USE_EFFECT, 0, T.ALL)],
		_spin(0.6), [[0.3, "cleanse"]], {"sound": ["Chime1", 0.0, -4.0]})
	# Enemy moves.
	_ability("fire_bolt", "Ability.Firebolt", B.SINGLE_ENEMY, [_row("bolt", "damage", D.SCALED, 100, T.ALL, fire),
		_chance(_row("burn", "burn", D.FLAT, 30, T.ALL, fire), 100)], _jump(0.6), [[0.3, "bolt"], [0.35, "burn"]],
		{"sound": ["Fire1", 0.2, -8.0]})
	_ability("spit", "Ability.Spit", B.SINGLE_ENEMY, [_row("spit", "damage", D.SCALED, 80, T.ALL, physical),
		_chance(_row("poison", "poison", D.USE_EFFECT, 0, T.ALL), 100)], _jump(0.6), [[0.3, "spit"], [0.35, "poison"]])
	_ability("chill", "Ability.Chill", B.SINGLE_ENEMY, [_row("chill", "damage", D.SCALED, 60, T.ALL, ice),
		_chance(_row("slow", "slow", D.USE_EFFECT, 0, T.ALL), 100)], _flash(0.5), [[0.25, "chill"], [0.3, "slow"]])
	_ability("freeze_touch", "Ability.Freezetouch", B.SINGLE_ENEMY, [_row("touch", "damage", D.SCALED, 50, T.ALL, ice),
		_chance(_row("freeze", "freeze", D.USE_EFFECT, 0, T.ALL), 50)], _flash(0.5), [[0.25, "touch"], [0.3, "freeze"]],
		{"sound": ["Ice5", 0.2, -8.0]})
	var bash := _row("bash", "damage", D.SCALED, 90, T.ALL, physical)
	bash.toughness_x100 = Fixed.from_typed(30)
	_ability("shield_bash", "Ability.Shieldbash", B.SINGLE_ENEMY, [bash,
		_chance(_row("stun", "stun", D.USE_EFFECT, 0, T.ALL), 40)], _jump(0.6), [[0.3, "bash"], [0.35, "stun"]],
		{"sound": ["Blow4", 0.2, -6.0]})
	_ability("hex", "Ability.Hex", B.SINGLE_ENEMY, [_chance(_row("hex", "vulnerable", D.USE_EFFECT, 0, T.ALL), 100)],
		_flash(0.5), [[0.3, "hex"]])
	_ability("mend", "Ability.Mend", B.SINGLE_ALLY, [_row("regen", "regen", D.USE_EFFECT, 0, T.ALL)], _flash(0.5), [[0.3, "regen"]])
	_ability("dispel", "Ability.Dispel", B.ALL_ENEMIES, [_chance(_row("dispel", "dispel", D.USE_EFFECT, 0, T.ALL), 100)],
		_spin(0.6), [[0.3, "dispel"]])
	var phase_1 := _query([], [&"State.Phase.Two"])
	var phase_2 := _query([&"State.Phase.Two"], [&"State.Phase.Three"])
	var blast := _row("blast", "damage", D.SCALED, 90, T.PRIMARY, physical)
	blast.toughness_x100 = Fixed.from_typed(30)
	_ability("bleed_blast", "Ability.Bleedblast", B.BLAST_ENEMY, [blast, _row("splash", "damage", D.SCALED, 40, T.ADJACENT, physical),
		_chance(_row("bleed", "bleed", D.USE_EFFECT, 0, T.PRIMARY), 100)], _jump(0.7), [[0.3, "blast"], [0.32, "splash"],
		[0.4, "bleed"]], {"query": phase_1, "sound": ["Attack2", 0.2, -6.0]})
	_ability("hex_all", "Ability.Hexall", B.ALL_ENEMIES, [_chance(_row("hex", "vulnerable", D.USE_EFFECT, 0, T.ALL), 100),
		_chance(_row("weaken", "weaken", D.USE_EFFECT, 0, T.ALL), 100)], _spin(0.7), [[0.3, "hex"], [0.4, "weaken"]],
		{"query": phase_2})
	var doom := _row("doom", "damage", D.SCALED, 180, T.ALL, physical)
	doom.toughness_x100 = Fixed.from_typed(30)
	_ability("doom", "Ability.Doom", B.SINGLE_ENEMY, [doom], _jump(0.8), [[0.4, "doom"]],
		{"query": _query([&"State.Phase.Three"]), "sound": ["Explosion1", 0.3, -4.0]})
	_ability("death_ray", "Ability.Ult.Deathray", B.SINGLE_ENEMY, [_row("ray", "damage", D.SCALED, 200, T.ALL, ice)],
		_spin(1.0), [[0.6, "ray"]], ult.merged({"sound": ["Ice5", 0.5, -2.0]}))
	_ability("rockfall", "Ability.Rockfall", B.ALL_ENEMIES, [_row("rocks", "damage", D.SCALED, 70, T.ALL, physical)],
		_jump(0.8), [[0.4, "rocks"]], {"query": _query([&"State.Phase.Two"]), "sound": ["Explosion1", 0.3, -6.0]})
	# The Golem's phase 2 (granted by its phase, by hand with your approval): State.Phase.Two opens Rockfall.
	var golem_phase := AbilitySet.new()
	golem_phase.tags.assign([&"State.Phase.Two"])
	golem_phase.abilities.append(_r["abilities/rockfall"])
	_save("loadouts/golem_phase_2", golem_phase)
	for phase in [[2, &"State.Phase.Two"], [3, &"State.Phase.Three"]]:
		var lich_phase := AbilitySet.new()
		lich_phase.tags.assign([phase[1]])
		_save("loadouts/lich_phase_%d" % phase[0], lich_phase)


# --- Items and armor (spec 3.6) ------------------------------------------------------------------------------------------

func _new_items() -> void:
	var common := &"Item.Rarity.Common"
	var rare := &"Item.Rarity.Rare"
	var t := &"Pool.Treasure"
	var s := &"Pool.Shop"
	var b := &"Pool.Boss"
	var consumable := ItemDefinition.UseMode.CONSUMABLE
	var cooldown := ItemDefinition.UseMode.COOLDOWN
	_usable("plague_flask", "Plague Flask", [s, common], 4, "plague_flask", consumable, 1, "All enemies: 2 stacks of Poison (25 per stack each turn, 3 turns).")
	_described("frost_lantern", "Frost Lantern", [t, rare], 8, _ability_set(["frost_lantern"], []), "Ice damage has a 25% chance to Freeze the target.")
	_described("serrated_edge", "Serrated Edge", [t, common], 6, _ability_set(["serrated_edge"], []), "Critical hits make the target Bleed (6% of max HP per turn, 2 turns).")
	_described("toxic_echo", "Toxic Echo", [t, rare], 8, _ability_set(["toxic_echo"], []), "Hitting a weakness of a Poisoned enemy triggers a follow-up: 30% ATK Physical.")
	_usable("purifying_bell", "Purifying Bell", [t, s, rare], 8, "purifying_bell", cooldown, 2, "Cleanse every debuff from the party. Ready again after 2 won battles.")
	_described("hexbreaker_charm", "Hexbreaker Charm", [t, s, common], 6, _ability_set(["hexbreaker_charm"], []), "At the start of every battle: Ward (immune to control) for 2 turns.")
	_described("witchs_eye", "Witch's Eye", [t, s, common], 6, _ability_set([], ["witchs_eye"]), "Debuffs you apply last 1 more turn.")
	_described("overcharge_coil", "Overcharge Coil", [t, rare], 9, _ability_set(["overcharge_coil"], []), "After each of your ults, +20 ult charge.")
	_described("interrupters_badge", "Interrupter's Badge", [t, common], 6, _ability_set(["interrupters_badge"], []), "After an out-of-turn ult, +15% ATK for 1 turn.")
	_described("shatterpoint", "Shatterpoint", [t, rare], 8, _ability_set(["shatterpoint"], []), "Breaking an enemy with Ice makes it Vulnerable.")
	_described("mirror_ward", "Mirror Ward", [t, common], 6, _ability_set(["mirror_ward"], []), "Heal 60 HP whenever a status roll involving you misses.")
	_described("last_rites", "Last Rites", [t, common], 6, _ability_set(["last_rites"], []), "On a kill: Regen (6% of max HP per turn, 2 turns).")
	_described("salamander_heart", "Salamander Heart", [t, b, rare], 10, _ability_set([], ["salamander_heart"]), "You drain Fire (Fire hits heal you), but you become weak to Ice.")
	_described("frostguard_charm", "Frostguard Charm", [t, s, common], 6, _ability_set([], ["frostguard_charm"]), "You resist Ice (half damage). A weakness to Ice still wins.")
	_described("leech_hide", "Leech Hide", [b, rare], 12, _ability_set([], ["leech_hide"]), "You drain Physical: Physical hits heal you.")
	_described("siphon_sigil", "Siphon Sigil", [t, common], 5, _ability_set(["siphon_sigil"], []), "Each hit you drain gives +10 ult charge.")


func _new_armor() -> void:
	var common := &"Item.Rarity.Common"
	var rare := &"Item.Rarity.Rare"
	var t := &"Pool.Treasure"
	var s := &"Pool.Shop"
	var b := &"Pool.Boss"
	_piece("warden_helm", "Warden Helm", "Head", [t, b, rare], 9, _ability_set([], ["warden_helm"]), "Immune to Freeze and Stun.")
	_piece("thornbark_mail", "Thornbark Mail", "Body", [t, s, common], 7, _ability_set(["thornbark_mail"], []), "When hit, Poison the attacker.")
	_piece("tacticians_ring", "Tactician's Ring", "Accessory", [t, rare], 8, _ability_set(["tacticians_ring"], []), "Taunt at the start of every battle (enemies must target you).")


# --- Enemies, the Lich and their encounters (spec 3.6) -------------------------------------------------------------------

func _new_enemies() -> void:
	var core := {"crit_rate": 5, "crit_dmg": 50, "energy": 0, "weakness_dmg": 150}
	var imp_brain := TacticalBrain.new()
	_brained("imp", "Fire Imp", Color.ORANGE_RED, core.merged({"max_hp": 260, "hp": 260, "atk": 240, "def": 60, "spd": 115,
		"max_toughness": 30, "toughness": 30}), ["fire_bolt"], [&"Enemy.Type.Imp", &"Resist.Fire", &"Weakness.Ice"], imp_brain, [])
	_brained("toad", "Bog Toad", Color.DARK_OLIVE_GREEN, core.merged({"max_hp": 380, "hp": 380, "atk": 200, "def": 120,
		"spd": 85, "max_toughness": 40, "toughness": 40}), ["spit"], [&"Enemy.Type.Toad", &"Weakness.Fire"], null, [])
	var wisp_brain := PatternBrain.new()
	wisp_brain.pattern.assign([&"Ability.Chill", &"Ability.Freezetouch"])
	_brained("wisp", "Frost Wisp", Color.LIGHT_CYAN, core.merged({"max_hp": 220, "hp": 220, "atk": 220, "def": 50, "spd": 125,
		"max_toughness": 25, "toughness": 25}), ["chill", "freeze_touch"],
		[&"Enemy.Type.Wisp", &"Weakness.Fire", &"Weakness.Physical"], wisp_brain, [])
	_brained("knight", "Knight", Color.LIGHT_SLATE_GRAY, core.merged({"max_hp": 520, "hp": 520, "atk": 260, "def": 260,
		"spd": 90, "max_toughness": 80, "toughness": 80}), ["shield_bash"], [&"Enemy.Type.Knight", &"Weakness.Ice",
		&"Immune.Control"], null, [])
	var shaman_brain := PatternBrain.new()
	shaman_brain.pattern.assign([&"Ability.Hex", &"Ability.Mend", &"Ability.Dispel"])
	_brained("shaman", "Shaman", Color.MEDIUM_ORCHID, core.merged({"max_hp": 300, "hp": 300, "atk": 180, "def": 100,
		"spd": 105, "max_toughness": 30, "toughness": 30}), ["hex", "mend", "dispel"], [&"Enemy.Type.Shaman",
		&"Weakness.Physical"], shaman_brain, [])
	var lich_brain := TacticalBrain.new()
	lich_brain.ult_when_party_down = true
	lich_brain.ult_when_ally_hp_below_x100 = Fixed.from_typed(50)
	_brained("lich", "Lich", Color.DARK_SLATE_BLUE, core.merged({"max_hp": 4800, "hp": 4800, "atk": 300, "def": 200,
		"spd": 100, "max_toughness": 150, "toughness": 150, "weakness_dmg": 125}), ["bleed_blast", "hex_all", "doom",
		"death_ray", "ult_charge_hit"], [&"Enemy.Boss", &"Enemy.Type.Lich", &"Resist.Ice", &"Weakness.Physical"], lich_brain,
		[_phase(60, "lich_phase_2", false), _phase(25, "lich_phase_3", true)])
	var demo := &"Chapter.Demo"
	_encounter("fire_court", "Fire Court", [demo], [["imp", null], ["imp", null]])
	_encounter("bog", "Bog", [demo], [["toad", null], ["wisp", null]])
	_encounter("vanguard", "Vanguard", [demo], [["knight", null], ["shaman", null]])
	_encounter("lich", "The Lich", [&"Encounter.Boss", demo], [["lich", null]])


func _brained(name: String, title: String, color: Color, stats: Dictionary, abilities: Array, tags: Array,
		brain: EnemyBrain, phases: Array) -> void:
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
	_save("enemies/" + name, enemy)


func _phase(hp_below: float, set_name: String, clear_debuffs: bool) -> BossPhase:
	var phase := BossPhase.new()
	phase.hp_below_x100 = Fixed.from_typed(hp_below)
	phase.ability_set = _r["loadouts/" + set_name]
	phase.clear_debuffs = clear_debuffs
	return phase
