## Builder for spec level-cap 2.2 and 2.3: the growth bands and the level skills from level 12 to 50 of the eleven demo classes
## (new skills, passives and ranks), written into res://content/demo/ through ResourceSaver like the other content builders.
##
## It writes only this pass's own new files and never overwrites one that exists (they are the user's to tune); --force
## rewrites this pass's own files. Every move reuses an existing animation (its `execute` keys name the rows, its sound comes
## with it) and the SP costs are the shared effects/sp_cost_<n>.tres. A rank is a copy of its skill with larger numbers.
## Most passives use item-power's hooks (ally events, DoT ticks, trigger chance, echoes, dying); none needs kernel code.
## Values are first proposals, typed as a designer would; tune them in the files.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_level_pass.tscn [-- --force] [-- --apply]
## It prints each class's list (level, kind, what it does, SP cost). --apply also adds the rows and growth bands to the eleven
## character files as a text edit (an existing design file: only with the user's go-ahead) and prints each change old → new.
extends "res://game/tools/build_item_power.gd"

const FIRE := [&"Damage.Type.Fire"]
const ICE := [&"Damage.Type.Ice"]
const BAND_LEVELS := [2, 16, 31]
const GROWTH_KINDS := {"damage": ["arcanist", "cryomancer", "ember_knight", "pyromancer", "ranger", "warrior"],
	"support": ["bard", "cleric", "plaguewright", "shatterweaver"], "tank": ["bulwark"]}

var _force := false
var _class := ""
var _patched := {}     # character file -> its new text, written once every file could be patched
var _rows := {}        # class -> [{"level", "name", "replaces", "kind", "text"}]


func _ready() -> void:
	_force = OS.get_cmdline_user_args().has("--force")
	_growth()
	_warrior()
	_arcanist()
	_bard()
	_cleric()
	_bulwark()
	_cryomancer()
	_ember_knight()
	_plaguewright()
	_pyromancer()
	_ranger()
	_shatterweaver()
	_print_lists()
	if OS.get_cmdline_user_args().has("--apply") and _failed.is_empty():
		for name in _rows:
			_apply(name)
		for path in _patched if _failed.is_empty() else {}:
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file == null:
				_failed.append("%s (%s)" % [path, error_string(FileAccess.get_open_error())])
				continue
			file.store_string(_patched[path])
			file.close()
	print("build_level_pass: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _failed:
		print("  FAILED  ", path)
	get_tree().quit(1 if not _failed.is_empty() else 0)


# --- Growth (2.2) --------------------------------------------------------------------------------------------------------

## Band 1 is today's growth per level, band 2 about half of it, band 3 about a quarter.
func _growth() -> void:
	_band("damage", {"max_hp": [6, 3, 1.5], "atk": [8, 4, 2], "def": [4, 2, 1]})
	_band("support", {"max_hp": [7, 3.5, 1.75], "atk": [6, 3, 1.5], "def": [5, 2.5, 1.25]})
	_band("tank", {"max_hp": [9, 4.5, 2.25], "atk": [4, 2, 1], "def": [7, 3.5, 1.75]})


func _band(kind: String, changes: Dictionary) -> void:
	for index in BAND_LEVELS.size():
		var typed := {}
		for attribute_name in changes:
			typed[attribute_name] = changes[attribute_name][index]
		typed["sp_gain"] = [7, 3.5, 1.75][index]
		typed["max_mp"] = [7, 3.5, 1.75][index]
		_fx("growth_%s_%d" % [kind, index + 1], _refresh(_infinite(typed, true), 0))


# --- Warrior: damage dealer and off-tank -----------------------------------------------------------------------------------

func _warrior() -> void:
	_class = "warrior"
	var A := BattleAbility.Targeting
	_active(12, "sundering_blow", "Sundering Blow", A.SINGLE_ENEMY, "splinter", 59,
		[_hit("splinter", 170, PHYSICAL, {"tough": 60}), _on("crack", "vulnerable", {"chance": 100})],
		"Heavy Physical damage to one enemy. Makes it Vulnerable.")
	_rank(16, "execute_2", "Execute II", "execute", {"execute": {"percent": 420, "tough": 150}}, 0,
		"420% ATK Physical to one enemy.")
	_fx("lv_bloodlust", _attack_up(15, 3, 3))
	_fx("lv_bloodlust_2", _attack_up(25, 3, 3))
	_trigger(20, "bloodlust", "Bloodlust", A.SELF, "bellows", [_on("charge", "lv_bloodlust")], &"Event.Unit.Killed",
		"On a kill: +15% ATK for 3 turns (3 stacks).")
	_rank(24, "cleave_2", "Cleave II", "cleave", {"cleave": {"percent": 280, "tough": 110}}, 0,
		"280% ATK Physical to every enemy.")
	_rank(26, "sundering_blow_2", "Sundering Blow II", "sundering_blow", {"splinter": {"percent": 260, "tough": 75}}, 83,
		"260% ATK Physical to one enemy. Makes it Vulnerable.")
	_active(28, "titans_fall", "Titan's Fall", A.BLAST_ENEMY, "crush", 103,
		[_hit("crush", 480, PHYSICAL, {"tough": 100, "on": ExecutionRow.Targets.PRIMARY}),
		_hit("quake", 170, PHYSICAL, {"tough": 40, "on": ExecutionRow.Targets.ADJACENT})],
		"480% ATK Physical to one enemy, 170% to its neighbours.")
	_rank(35, "bloodlust_2", "Bloodlust II", "bloodlust", {"charge": {"effect": "lv_bloodlust_2"}}, 0,
		"On a kill: +25% ATK for 3 turns (3 stacks).")
	_trigger(40, "unbowed", "Unbowed", A.SINGLE_ENEMY, "duelists_band", [_hit("riposte", 70, PHYSICAL)], &"Event.Ally.Damage.Taken",
		"When an ally is hit: a follow-up of 70% ATK Physical on the attacker.",
		{"asset_tags": FOLLOW_UP})
	_rank(45, "titans_fall_2", "Titan's Fall II", "titans_fall", {"crush": {"percent": 640, "tough": 120},
		"quake": {"percent": 230, "tough": 55}}, 121, "640% ATK Physical to one enemy, 230% to its neighbours.")
	_rank(50, "execute_3", "Execute III", "execute_2", {"execute": {"percent": 580, "tough": 180}}, 0,
		"580% ATK Physical to one enemy.")


# --- Arcanist: Fire and Ice magic ------------------------------------------------------------------------------------------

func _arcanist() -> void:
	_class = "arcanist"
	var A := BattleAbility.Targeting
	_active(12, "prismatic_ray", "Prismatic Ray", A.SINGLE_ENEMY, "prism_ray", 123,
		[_hit("ray", 260, ICE), _on("expose", "vulnerable", {"chance": 100})], "260% ATK Ice to one enemy. Makes it Vulnerable.")
	_rank(15, "meteor_2", "Meteor II", "meteor", {"meteor": {"percent": 280, "tough": 80}}, 0, "280% ATK Fire to every enemy.")
	_trigger(19, "arcane_echo", "Arcane Echo", A.SELF, "", [], &"Event.Ability.Used.Skill",
		"25% chance: your skills cast again at 50%.", {"asset_tags": [&"Ability.Type.Echo"], "trigger_chance": 25, "echo_scale": 50})
	_rank(23, "winter_nova", "Winter Nova", "frost_nova", {"nova": {"percent": 130}}, 123, "130% ATK Ice to every enemy.")
	_rank(26, "prismatic_ray_2", "Prismatic Ray II", "prismatic_ray", {"ray": {"percent": 360}}, 153,
		"360% ATK Ice to one enemy. Makes it Vulnerable.")
	_active(28, "cataclysm", "Cataclysm", A.ALL_ENEMIES, "hellfire", 173,
		[_hit("fire", 240, FIRE), _burn_row("burn", 90)], "240% ATK Fire to every enemy, and a strong Burn.")
	_rank(36, "arcane_echo_2", "Arcane Echo II", "arcane_echo", {}, 0, "40% chance: your skills cast again at 60%.",
		{"trigger_chance": 40, "echo_scale": 60})
	_fx("lv_mana_font", _instant({"mp": 15}))
	_trigger(41, "mana_font", "Mana Font", A.SELF, "spellweave", [_on("mana", "lv_mana_font")], &"Event.Turn.Start",
		"Each of your turns starts with 15 SP more.")
	_rank(46, "cataclysm_2", "Cataclysm II", "cataclysm", {"fire": {"percent": 330}, "burn": {"flat": 130}}, 203,
		"330% ATK Fire to every enemy, and a fierce Burn.")
	_rank(50, "meteor_3", "Meteor III", "meteor_2", {"meteor": {"percent": 380, "tough": 100}}, 0, "380% ATK Fire to every enemy.")


# --- Bard: buffs and debuffs -------------------------------------------------------------------------------------------------

func _bard() -> void:
	_class = "bard"
	var A := BattleAbility.Targeting
	_fx("lv_ballad", _regen(8, 3))
	_fx("lv_ballad_2", _regen(12, 3))
	_active(12, "ballad", "Ballad of Mending", A.ALL_ALLIES, "hymn", 83, [_on("regen", "lv_ballad")],
		"The party regenerates 8% of max HP each turn for 3 turns.")
	_fx("finale_2", _cued(_buff({"atk": 45}, 2, [&"Status.Buff.Finale"]), &"Cue.Fx.Buff.Finale"))
	_fx("finale_3", _cued(_buff({"atk": 60}, 3, [&"Status.Buff.Finale"]), &"Cue.Fx.Buff.Finale"))
	_rank(16, "finale_2", "Finale II", "finale", {"finale": {"effect": "finale_2"}}, 0,
		"The party acts at once, with +45% ATK for 2 turns.")
	_fx("lv_perfect_pitch", _instant({"energy": 15}))
	_fx("lv_perfect_pitch_2", _instant({"energy": 25}))
	_trigger(20, "perfect_pitch", "Perfect Pitch", A.SELF, "encore", [_on("charge", "lv_perfect_pitch")],
		&"Event.Ally.Ability.Used.Ultimate", "When an ally uses an ult: 15 ult charge.")
	_active(24, "cacophony", "Cacophony", A.ALL_ENEMIES, "entropy", 103,
		[_on("decay", "vulnerable", {"chance": 100}), _on("bleed", "weaken", {"chance": 75}), _on("slow", "slow", {"chance": 75})],
		"Makes every enemy Vulnerable; 75% chance each to Weaken and Slow it.", {"replaces": "discord"})
	_rank(26, "ballad_2", "Ballad of Mending II", "ballad", {"regen": {"effect": "lv_ballad_2"}}, 113,
		"The party regenerates 12% of max HP each turn for 3 turns.")
	_fx("lv_war_symphony", _symphony(45, 20))
	_fx("lv_war_symphony_2", _symphony(60, 30))
	_active(28, "war_symphony", "Symphony of War", A.ALL_ALLIES, "breakers_oath", 133,
		[_on("charge", "class_charge_10"), _on("fury", "lv_war_symphony")],
		"The party: 10 ult charge, +45% ATK and +20% crit rate for 3 turns.")
	_rank(35, "perfect_pitch_2", "Perfect Pitch II", "perfect_pitch", {"charge": {"effect": "lv_perfect_pitch_2"}}, 0,
		"When an ally uses an ult: 25 ult charge.")
	_trigger(40, "standing_ovation", "Standing Ovation", A.SELF, "encore", [_on("charge", "gravity_pull", {"delay": -35})],
		&"Event.Ally.Ability.Used.Ultimate", "When an ally uses an ult: your next turn comes 35% sooner.")
	_rank(45, "war_symphony_2", "Symphony of War II", "war_symphony", {"charge": {"effect": "class_charge_20"},
		"fury": {"effect": "lv_war_symphony_2"}}, 153, "The party: 20 ult charge, +60% ATK and +30% crit rate for 3 turns.")
	_rank(50, "finale_3", "Finale III", "finale_2", {"finale": {"effect": "finale_3"}}, 0,
		"The party acts at once, with +60% ATK for 3 turns.")


# --- Cleric: healer ------------------------------------------------------------------------------------------------------------

func _cleric() -> void:
	_class = "cleric"
	var A := BattleAbility.Targeting
	_active(12, "blessed_aegis", "Blessed Aegis", A.ALL_ALLIES, "bastion", 89, [_on("ward", "ward"), _on("guard", "defense_up")],
		"The party: +30% DEF and immune to control for 2 turns.")
	_fx("sanctuary_heal_2", _heal(35))
	_fx("sanctuary_heal_3", _heal(55))
	_rank(15, "sanctuary_2", "Sanctuary II", "sanctuary", {"bless": {"effect": "sanctuary_heal_2"}}, 0,
		"Restores 35% of max HP to the party.")
	_fx("lv_guardian_spirit", _heal(5))
	_fx("lv_guardian_spirit_2", _heal(8))
	_trigger(19, "guardian_spirit", "Guardian Spirit", A.SINGLE_ALLY, "heartstring", [_on("mend", "lv_guardian_spirit")],
		&"Event.Ally.Damage.Taken", "When an ally is hit: 50% chance to heal them 5% of max HP.", {"trigger_chance": 50})
	var revive := _percent_of_max(70)
	revive.application_cue_tags.assign([&"Cue.Fx.Revive", &"Cue.Sfx.Revive"])
	_fx("resurrection_revive_2", revive)
	_rank(22, "resurrection_2", "Resurrection II", "resurrection", {"raise": {"effect": "resurrection_revive_2"}}, 0,
		"Brings one fallen ally back with 70% of max HP.")
	_fx("lv_benediction", _heal(28))
	_active(26, "benediction", "Benediction", A.ALL_ALLIES, "cauldron_brew", 139, [_on("heal", "lv_benediction"), _on("rally", "regen")],
		"Restores 28% of max HP to the party, and Regen.", {"replaces": "mass_heal", "field": true})
	_fx("lv_miracle", _heal(45))
	_fx("lv_miracle_2", _heal(65))
	_active(28, "miracle", "Miracle", A.ALL_ALLIES, "holy_water", 153, [_on("clean", "cleanse"), _on("heal", "lv_miracle")],
		"Removes the party's debuffs and restores 45% of max HP.", {"field": true})
	_rank(35, "guardian_spirit_2", "Guardian Spirit II", "guardian_spirit", {"mend": {"effect": "lv_guardian_spirit_2"}}, 0,
		"When an ally is hit: 65% chance to heal them 8% of max HP.", {"trigger_chance": 65})
	var rise := _percent_of_max(50)  # no heal_taken: a save works for a holder that can't be healed
	rise.application_cue_tags.assign(HEAL_CUES)
	_fx("lv_undying_faith", rise)
	_trigger(40, "undying_faith", "Undying Faith", A.SELF, "undying_ember", [_on("rise", "lv_undying_faith"), _on("fury", "regen"),
		_on("saved", "undying_ember_saved")], &"Event.Unit.Dying",
		"Once per battle, a killing blow leaves you at 50% HP with Regen.", {"query": _query([], [&"State.DeathSaved"])})
	_rank(45, "miracle_2", "Miracle II", "miracle", {"heal": {"effect": "lv_miracle_2"}}, 173,
		"Removes the party's debuffs and restores 65% of max HP.")
	_rank(50, "sanctuary_3", "Sanctuary III", "sanctuary_2", {"bless": {"effect": "sanctuary_heal_3"}}, 0,
		"Restores 55% of max HP to the party.")


# --- Bulwark: tank -------------------------------------------------------------------------------------------------------------

func _bulwark() -> void:
	_class = "bulwark"
	var A := BattleAbility.Targeting
	_active(12, "shield_charge", "Shield Charge", A.SINGLE_ENEMY, "shield_bash", 63,
		[_hit("bash", 140, PHYSICAL, {"tough": 60}), _on("stun", "stun", {"chance": 50})],
		"140% ATK Physical to one enemy. 50% chance to Stun it.")
	_rank(15, "bastion_2", "Bastion II", "bastion", {"guard": {"effect": "defense_up_2"}}, 0,
		"The party: +45% DEF and immune to control for 2 turns.")
	_trigger(20, "protector", "Protector", A.SINGLE_ENEMY, "duelists_band", [_hit("riposte", 60, PHYSICAL)],
		&"Event.Ally.Damage.Taken", "When an ally is hit: 50% chance of a follow-up of 60% ATK Physical on the attacker.",
		{"asset_tags": FOLLOW_UP, "trigger_chance": 50})
	_rank(24, "shield_charge_2", "Shield Charge II", "shield_charge", {"bash": {"percent": 210, "tough": 75},
		"stun": {"chance": 65}}, 83, "210% ATK Physical to one enemy. 65% chance to Stun it.")
	_fx("lv_fortress", _infinite({"def": 20, "dmg_taken": -8}, true))
	_trigger(26, "fortress", "Fortress", A.SELF, "oath_warrior", [_on("oath", "lv_fortress")], &"Event.Battle.Start",
		"+20% DEF, −8% damage taken.")
	_active(28, "earthshaker", "Earthshaker", A.ALL_ENEMIES, "ill_omen", 97,
		[_hit("omen", 170, PHYSICAL, {"tough": 60}), _on("slow", "slow", {"chance": 100})], "170% ATK Physical to every enemy. Slows it.")
	_rank(35, "protector_2", "Protector II", "protector", {"riposte": {"percent": 80}}, 0,
		"When an ally is hit: 75% chance of a follow-up of 80% ATK Physical on the attacker.", {"trigger_chance": 75})
	_fx("lv_stoneheart", _percent_heal(5))
	_trigger(40, "stoneheart", "Stoneheart", A.SELF, "oath_warrior", [_on("oath", "lv_stoneheart")], &"Event.Turn.Start",
		"Heal 5% of your max HP at the start of each turn.")
	_rank(45, "earthshaker_2", "Earthshaker II", "earthshaker", {"omen": {"percent": 250, "tough": 75}}, 113,
		"250% ATK Physical to every enemy. Slows it.")
	_rank(50, "bastion_3", "Bastion III", "bastion_2", {"guard": {"effect": "defense_up_3"}}, 0,
		"The party: +60% DEF and immune to control for 2 turns.")


# --- Cryomancer: control -------------------------------------------------------------------------------------------------------

func _cryomancer() -> void:
	_class = "cryomancer"
	var A := BattleAbility.Targeting
	_active(12, "frost_lock", "Frost Lock", A.SINGLE_ENEMY, "lockdown", 89,
		[_hit("lock", 130, ICE, {"tough": 30}), _on("freeze", "freeze", {"chance": 70})],
		"130% ATK Ice to one enemy. 70% chance to Freeze it.")
	_rank(16, "absolute_zero_2", "Absolute Zero II", "absolute_zero", {"zero": {"percent": 230}, "freeze": {"chance": 60}}, 0,
		"230% ATK Ice to every enemy. 60% chance to Freeze it.")
	_trigger(20, "ice_shards", "Ice Shards", A.SINGLE_ENEMY, "hunters_instinct", [_hit("volley", 60, ICE)],
		&"Event.Damage.Dealt.Ice", "Your Ice hits: 30% chance of a follow-up of 60% ATK Ice.",
		{"asset_tags": FOLLOW_UP, "trigger_chance": 30})
	_rank(24, "whiteout", "Whiteout", "blizzard", {"storm": {"percent": 120}}, 123, "120% ATK Ice to every enemy. Slows it.")
	_rank(26, "frost_lock_2", "Frost Lock II", "frost_lock", {"lock": {"percent": 190, "tough": 45}, "freeze": {"chance": 85}}, 113,
		"190% ATK Ice to one enemy. 85% chance to Freeze it.")
	_active(29, "glacier", "Glacier", A.BLAST_ENEMY, "ice_blast", 149,
		[_hit("blast", 440, ICE, {"tough": 60, "on": ExecutionRow.Targets.PRIMARY}),
		_hit("chill", 180, ICE, {"on": ExecutionRow.Targets.ADJACENT})],
		"440% ATK Ice to one enemy, 180% to its neighbours.")
	_rank(36, "ice_shards_2", "Ice Shards II", "ice_shards", {"volley": {"percent": 80}}, 0,
		"Your Ice hits: 45% chance of a follow-up of 80% ATK Ice.", {"trigger_chance": 45})
	_trigger(41, "permafrost", "Permafrost", A.SINGLE_ENEMY, "molten_core", [_on("melt", "slow", {"chance": 40})],
		&"Event.Damage.Dealt.Ice", "Your Ice hits have a 40% chance to Slow the target.")
	_rank(45, "glacier_2", "Glacier II", "glacier", {"blast": {"percent": 590, "tough": 75}, "chill": {"percent": 240}}, 173,
		"590% ATK Ice to one enemy, 240% to its neighbours.")
	_rank(50, "absolute_zero_3", "Absolute Zero III", "absolute_zero_2", {"zero": {"percent": 310}, "freeze": {"chance": 75}}, 0,
		"310% ATK Ice to every enemy. 75% chance to Freeze it.")


# --- Ember Knight: break damage ------------------------------------------------------------------------------------------------

func _ember_knight() -> void:
	_class = "ember_knight"
	var A := BattleAbility.Targeting
	_active(12, "blazing_arc", "Blazing Arc", A.BLAST_ENEMY, "fireburst", 67,
		[_hit("burst", 150, FIRE, {"tough": 40, "on": ExecutionRow.Targets.PRIMARY}),
		_hit("splash", 70, FIRE, {"tough": 20, "on": ExecutionRow.Targets.ADJACENT})],
		"150% ATK Fire to one enemy, 70% to its neighbours.")
	_fx("combustion_2", _combustion(40, 70, 60))
	_fx("combustion_3", _combustion(50, 90, 80))
	_rank(15, "complete_combustion_2", "Complete Combustion II", "complete_combustion", {"combust": {"effect": "combustion_2"}}, 0,
		"+40 SPD, +70% toughness damage and +60% damage to Broken enemies for 3 turns.")
	_trigger(20, "detonate", "Detonate", A.SINGLE_ENEMY, "frost_ember", [_hit("burn", 120, FIRE)], &"Event.Damage.Dealt.Break",
		"Breaking an enemy: a follow-up of 120% ATK Fire.", {"asset_tags": FOLLOW_UP})
	_rank(24, "fyrefly_strike_2", "Fyrefly Strike II", "fyrefly_strike", {"strike": {"percent": 290, "tough": 75},
		"splash": {"percent": 120}}, 99, "290% ATK Fire to one enemy, 120% to its neighbours. Makes them weak to Fire.")
	_rank(26, "blazing_arc_2", "Blazing Arc II", "blazing_arc", {"burst": {"percent": 220, "tough": 55},
		"splash": {"percent": 100, "tough": 30}}, 89, "220% ATK Fire to one enemy, 100% to its neighbours.")
	_active(28, "phoenix_dive", "Phoenix Dive", A.SINGLE_ENEMY, "meltdown", 119,
		[_hit("melt", 460, FIRE, {"tough": 90}), _burn_row("burn", 110)], "460% ATK Fire to one enemy, and a strong Burn.")
	_rank(35, "detonate_2", "Detonate II", "detonate", {"burn": {"percent": 200}}, 0,
		"Breaking an enemy: a follow-up of 200% ATK Fire.")
	var soul := _mixed_infinite([["broken_dmg", GameplayEffectModifier.Operation.ADD, 20],
		["spd", GameplayEffectModifier.Operation.ADD, 12]])
	_fx("lv_ember_soul", soul)
	_trigger(40, "ember_soul", "Ember Soul", A.SELF, "oath_warrior", [_on("oath", "lv_ember_soul")], &"Event.Battle.Start",
		"+12 SPD, +20% damage to Broken enemies.")
	_rank(45, "phoenix_dive_2", "Phoenix Dive II", "phoenix_dive", {"melt": {"percent": 610, "tough": 110}, "burn": {"flat": 150}}, 139,
		"610% ATK Fire to one enemy, and a fierce Burn.")
	_rank(50, "complete_combustion_3", "Complete Combustion III", "complete_combustion_2", {"combust": {"effect": "combustion_3"}}, 0,
		"+50 SPD, +90% toughness damage and +80% damage to Broken enemies for 3 turns.")


# --- Plaguewright: statuses ----------------------------------------------------------------------------------------------------

func _plaguewright() -> void:
	_class = "plaguewright"
	var A := BattleAbility.Targeting
	_active(12, "festering_wound", "Festering Wound", A.SINGLE_ENEMY, "hemorrhage", 63,
		[_hit("cut", 120, PHYSICAL), _on("bleed", "bleed", {"chance": 80})], "120% ATK Physical to one enemy. 80% chance to Bleed.")
	_rank(15, "pandemic_2", "Pandemic II", "pandemic", {"poison": {"effect": "poison_2"}, "burn": {"flat": 100}}, 0,
		"A stronger Poison, Bleed, Burn and Vulnerable on every enemy.")
	_trigger(19, "toxic_spores", "Toxic Spores", A.RANDOM_OTHER_ENEMY, "mimic_tooth", [_spread("bleed")], &"Event.Damage.Dealt.Dot",
		"Each tick of your DoTs: 20% chance to spread one stack to another enemy.", {"trigger_chance": 20})
	var strong := _add_buff({"debuff_turns": 1}, 3, [&"Status.Buff.Malady"])
	strong.modifiers.append(_modifier("atk", GameplayEffectModifier.Operation.PERCENT_ADD, 20))
	_fx("malady_2", _cued(strong, &"Cue.Fx.Buff.Malady"))
	_rank(24, "lingering_malady_2", "Lingering Malady II", "lingering_malady", {"malady": {"effect": "malady_2"}}, 99,
		"The party: debuffs last 1 turn longer and +20% ATK for 3 turns.")
	_rank(26, "festering_wound_2", "Festering Wound II", "festering_wound", {"cut": {"percent": 190}, "bleed": {"chance": 100}}, 83,
		"190% ATK Physical to one enemy. It Bleeds.")
	var dose: GameplayEffect = load(CONTENT + "effects/poison_2.tres").duplicate(true)
	dose.modifiers.assign([_modifier("hp", GameplayEffectModifier.Operation.ADD, -60)])
	_fx("poison_3", dose)
	_active(28, "miasma", "Miasma", A.ALL_ENEMIES, "spit", 143,
		[_hit("spit", 120, PHYSICAL), _on("poison", "poison_3", {"chance": 100})],
		"120% ATK Physical to every enemy, and a virulent Poison.")
	_rank(35, "toxic_spores_2", "Toxic Spores II", "toxic_spores", {}, 0,
		"Each tick of your DoTs: 35% chance to spread one stack to another enemy.", {"trigger_chance": 35})
	_trigger(40, "pathogen", "Pathogen", A.SINGLE_ENEMY, "toxic_echo", [_hit("echo", 50, PHYSICAL)], &"Event.Damage.Dealt.Dot",
		"Each tick of your DoTs: 25% chance of a follow-up of 50% ATK Physical on that enemy.",
		{"asset_tags": FOLLOW_UP, "trigger_chance": 25})
	_rank(45, "miasma_2", "Miasma II", "miasma", {"spit": {"percent": 190}}, 169,
		"190% ATK Physical to every enemy, and a virulent Poison.")
	_rank(50, "pandemic_3", "Pandemic III", "pandemic_2", {"poison": {"effect": "poison_3"}, "burn": {"flat": 150}}, 0,
		"A virulent Poison, Bleed, a strong Burn and Vulnerable on every enemy.")


# --- Pyromancer: burns -----------------------------------------------------------------------------------------------------------

func _pyromancer() -> void:
	_class = "pyromancer"
	var A := BattleAbility.Targeting
	_active(12, "flame_tongue", "Flame Tongue", A.BLAST_ENEMY, "bleed_blast", 83,
		[_hit("blast", 150, FIRE, {"on": ExecutionRow.Targets.PRIMARY}), _hit("splash", 70, FIRE, {"on": ExecutionRow.Targets.ADJACENT}),
		_burn_row("bleed", 70)], "150% ATK Fire to one enemy, 70% to its neighbours, and a Burn.")
	_rank(15, "supernova_2", "Supernova II", "supernova", {"nova": {"percent": 310}, "burn": {"flat": 140}}, 0,
		"310% ATK Fire to every enemy, and a strong Burn.")
	_trigger(20, "combust", "Combust", A.SINGLE_ENEMY, "toxic_echo", [_hit("echo", 60, FIRE)], &"Event.Damage.Dealt.Dot",
		"Each tick of your DoTs: 25% chance of a follow-up of 60% ATK Fire on that enemy.",
		{"asset_tags": FOLLOW_UP, "trigger_chance": 25})
	_rank(24, "conflagration", "Conflagration", "inferno", {"fire": {"percent": 110}, "burn": {"flat": 75}}, 123,
		"110% ATK Fire to every enemy, and a Burn.")
	_rank(26, "flame_tongue_2", "Flame Tongue II", "flame_tongue", {"blast": {"percent": 220}, "splash": {"percent": 100},
		"bleed": {"flat": 100}}, 113, "220% ATK Fire to one enemy, 100% to its neighbours, and a strong Burn.")
	_active(29, "dragons_breath", "Dragon's Breath", A.ALL_ENEMIES, "fury_breath", 159,
		[_hit("breath", 230, FIRE), _burn_row("burn", 120)], "230% ATK Fire to every enemy, and a strong Burn.")
	_rank(36, "combust_2", "Combust II", "combust", {"echo": {"percent": 80}}, 0,
		"Each tick of your DoTs: 35% chance of a follow-up of 80% ATK Fire on that enemy.", {"trigger_chance": 35})
	_fx("lv_heart_of_fire", _infinite({"dmg_mult": 15}, true))
	_trigger(41, "heart_of_fire", "Heart of Fire", A.SELF, "oath_warrior", [_on("oath", "lv_heart_of_fire")], &"Event.Battle.Start",
		"+15% damage.")
	_rank(46, "dragons_breath_2", "Dragon's Breath II", "dragons_breath", {"breath": {"percent": 310}, "burn": {"flat": 170}}, 183,
		"310% ATK Fire to every enemy, and a fierce Burn.")
	_rank(50, "supernova_3", "Supernova III", "supernova_2", {"nova": {"percent": 420}, "burn": {"flat": 190}}, 0,
		"420% ATK Fire to every enemy, and a fierce Burn.")


# --- Ranger: follow-ups ----------------------------------------------------------------------------------------------------------

func _ranger() -> void:
	_class = "ranger"
	var A := BattleAbility.Targeting
	_active(12, "twin_shot", "Twin Shot", A.SINGLE_ENEMY, "echo_strike", 53, [_hit("strike", 105, PHYSICAL), _hit("echo", 105, PHYSICAL)],
		"Two shots of 105% ATK Physical at one enemy.")
	_rank(15, "rain_of_arrows_2", "Rain of Arrows II", "rain_of_arrows", {"rain": {"percent": 190}}, 0,
		"190% ATK Physical to every enemy.")
	_trigger(18, "opportunist", "Opportunist", A.SINGLE_ENEMY, "hunters_instinct", [_hit("volley", 50, PHYSICAL)],
		&"Event.Damage.Dealt.Critical", "Critical hits: 50% chance of a follow-up of 50% ATK Physical.",
		{"asset_tags": FOLLOW_UP, "trigger_chance": 50})
	_rank(22, "hunters_instinct_2", "Hunter's Instinct II", "hunters_instinct", {"volley": {"percent": 80}}, 0,
		"Hitting a weakness: a follow-up of 80% ATK Physical.")
	_rank(26, "twin_shot_2", "Twin Shot II", "twin_shot", {"strike": {"percent": 150}, "echo": {"percent": 150}}, 73,
		"Two shots of 150% ATK Physical at one enemy.")
	_active(28, "judgement_arrow", "Judgement Arrow", A.SINGLE_ENEMY, "judgement", 97, [_hit("judge", 450, PHYSICAL, {"tough": 60})],
		"450% ATK Physical to one enemy.")
	_rank(35, "opportunist_2", "Opportunist II", "opportunist", {"volley": {"percent": 75}}, 0,
		"Critical hits: 65% chance of a follow-up of 75% ATK Physical.", {"trigger_chance": 65})
	_fx("lv_eagle_eye", _mixed_infinite([["crit_rate", GameplayEffectModifier.Operation.ADD, 15],
		["crit_dmg", GameplayEffectModifier.Operation.ADD, 40]]))
	_trigger(40, "eagle_eye", "Eagle Eye", A.SELF, "oath_warrior", [_on("oath", "lv_eagle_eye")], &"Event.Battle.Start",
		"+15% crit rate, +40% crit damage.")
	_rank(45, "judgement_arrow_2", "Judgement Arrow II", "judgement_arrow", {"judge": {"percent": 600, "tough": 75}}, 119,
		"600% ATK Physical to one enemy.")
	_rank(50, "rain_of_arrows_3", "Rain of Arrows III", "rain_of_arrows_2", {"rain": {"percent": 270}}, 0,
		"270% ATK Physical to every enemy.")


# --- Shatterweaver: break support --------------------------------------------------------------------------------------------------

func _shatterweaver() -> void:
	_class = "shatterweaver"
	var A := BattleAbility.Targeting
	_active(12, "crystal_rain", "Crystal Rain", A.ALL_ENEMIES, "tremor", 83, [_hit("tremor", 60, PHYSICAL, {"tough": 40})],
		"60% ATK Physical and toughness damage to every enemy.")
	_rank(16, "shatter_chorus_2", "Shatter Chorus II", "shatter_chorus", {"chorus": {"percent": 100, "tough": 110}}, 0,
		"100% ATK Physical and heavy toughness damage to every enemy.")
	_fx("lv_fault_echo", _instant({"energy": 8}))
	_fx("lv_fault_echo_2", _instant({"energy": 14}))
	_trigger(20, "fault_echo", "Fault Echo", A.ALL_ALLIES, "resonance", [_on("charge", "lv_fault_echo")], &"Event.Damage.Dealt.Break",
		"Breaking an enemy: 8 ult charge for the party.")
	var field := _add_buff({"toughness_dmg": 45, "broken_dmg": 40}, 3, [&"Status.Buff.Fracture"])
	_fx("fracture_2", _cued(field, &"Cue.Fx.Buff.Fracture"))
	_rank(24, "fracture_field_2", "Fracture Field II", "fracture_field", {"fracture": {"effect": "fracture_2"}}, 113,
		"The party: +45% toughness damage and +40% damage to Broken enemies for 3 turns.")
	_rank(26, "crystal_rain_2", "Crystal Rain II", "crystal_rain", {"tremor": {"percent": 95, "tough": 55}}, 103,
		"95% ATK Physical and heavy toughness damage to every enemy.")
	_active(29, "worldbreaker", "Worldbreaker", A.SINGLE_ENEMY, "rend", 119,
		[_hit("rend", 300, PHYSICAL, {"tough": 130}), _on("bleed", "vulnerable", {"chance": 100})],
		"300% ATK Physical and massive toughness damage to one enemy. Makes it Vulnerable.")
	_rank(36, "fault_echo_2", "Fault Echo II", "fault_echo", {"charge": {"effect": "lv_fault_echo_2"}}, 0,
		"Breaking an enemy: 14 ult charge for the party.")
	_fx("lv_crystalline", _mixed_infinite([["toughness_dmg", GameplayEffectModifier.Operation.ADD, 15],
		["broken_dmg", GameplayEffectModifier.Operation.ADD, 15]]))
	_trigger(41, "crystalline", "Crystalline", A.ALL_ALLIES, "oath_warrior", [_on("oath", "lv_crystalline")], &"Event.Battle.Start",
		"The party: +15% toughness damage, +15% damage to Broken enemies.")
	_rank(45, "worldbreaker_2", "Worldbreaker II", "worldbreaker", {"rend": {"percent": 420, "tough": 160}}, 139,
		"420% ATK Physical and massive toughness damage to one enemy. Makes it Vulnerable.")
	_rank(50, "shatter_chorus_3", "Shatter Chorus III", "shatter_chorus_2", {"chorus": {"percent": 150, "tough": 140}}, 0,
		"150% ATK Physical and massive toughness damage to every enemy.")


# --- Small builders ----------------------------------------------------------------------------------------------------------------

func _cued(effect: GameplayEffect, persistent: StringName) -> GameplayEffect:
	effect.persistent_cue_tags.assign([persistent])
	effect.application_cue_tags.assign(BUFF_CUES)
	return effect


func _regen(percent: float, turns: int) -> GameplayEffect:
	var effect := _refresh(_percent_dot(percent, turns, [&"Status.Buff.Regen"]))
	effect.periodic_cue_tags.assign(HEAL_CUES)
	return _cued(effect, &"Cue.Fx.Buff.Regen")


func _symphony(atk: float, crit: float) -> GameplayEffect:
	var effect := _attack_up(atk, 3, 1)
	effect.modifiers.append(_modifier("crit_rate", GameplayEffectModifier.Operation.ADD, crit))
	return effect


func _combustion(speed: float, toughness: float, broken: float) -> GameplayEffect:
	return _cued(_add_buff({"spd": speed, "toughness_dmg": toughness, "broken_dmg": broken}, 3,
		[&"Status.Buff.Combustion", &"State.Combustion"]), &"Cue.Fx.Buff.Combustion")


## build_classes' helper: a turn-based buff that adds (attributes that start at 0, or flat SPD).
func _add_buff(changes: Dictionary, turns: int, granted: Array) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.TURN_BASED
	effect.duration_turns = turns
	effect.granted_tags.assign(granted)
	for attribute_name in changes:
		effect.modifiers.append(_modifier(attribute_name, GameplayEffectModifier.Operation.ADD, changes[attribute_name]))
	return effect


## A new effect of this pass.
func _fx(name: String, effect: GameplayEffect) -> void:
	var path := CONTENT + "effects/%s.tres" % name
	if _force and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_save("effects/" + name, effect)


func _effect(name: String) -> GameplayEffect:
	if not _r.has("effects/" + name):
		_r["effects/" + name] = load(CONTENT + "effects/%s.tres" % name)
	if _r["effects/" + name] == null:
		_failed.append("effects/%s is missing" % name)
	return _r["effects/" + name]


## A damage row: `percent`% ATK of a damage type.
func _hit(id: String, percent: float, types: Array, options: Dictionary = {}) -> ExecutionRow:
	_effect("damage")
	var row := _row(id, "damage", ExecutionRow.DamageMode.SCALED, percent, options.get("on", ExecutionRow.Targets.ALL), types)
	row.toughness_x100 = Fixed.from_typed(options.get("tough", 0))
	return row


## A row that applies an effect.
func _on(id: String, effect_name: String, options: Dictionary = {}) -> ExecutionRow:
	_effect(effect_name)
	var row := _row(id, effect_name, ExecutionRow.DamageMode.USE_EFFECT, 0, ExecutionRow.Targets.ALL)
	row.chance_x100 = Fixed.from_typed(options.get("chance", 0))
	row.delay_x100 = Fixed.from_typed(options.get("delay", 0))
	return row


func _burn_row(id: String, tick: float) -> ExecutionRow:
	_effect("burn")
	var row := _row(id, "burn", ExecutionRow.DamageMode.FLAT, tick, ExecutionRow.Targets.ALL, FIRE)
	row.chance_x100 = Fixed.from_typed(100)
	return row


## The DoT that ticked, spread (item-power's event_effect row).
func _spread(id: String) -> ExecutionRow:
	var row := _on(id, "poison")
	row.event_effect = true
	return row


## A new action skill: `cost` SP, Ability.Role.* tags read from its rows, Battle (and Field with options.field).
func _active(level: int, name: String, title: String, targeting: int, animation: String, cost: int, rows: Array, text: String,
		options: Dictionary = {}) -> void:
	var ability := BattleAbility.new()
	ability.targeting = targeting
	ability.executions.assign(rows)
	ability.animation = _animation(animation)
	ability.ability_tag = StringName("Ability." + _dashboard(name))
	ability.cost_effect = _cost(cost)
	var usage: Array = [&"Ability.Usage.Battle", &"Ability.Usage.Field"] if options.get("field", false) else [&"Ability.Usage.Battle"]
	ability.asset_tags.assign(RolePass.roles_of(ability) + usage)
	_add(level, name, title, ability, text, "active (%d SP)" % cost, _tag_of(options["replaces"]) if options.has("replaces") else &"")


## A new passive. `animation` names an existing animation ("" = none, an echo).
func _trigger(level: int, name: String, title: String, targeting: int, animation: String, rows: Array, event: StringName, text: String,
		options: Dictionary = {}) -> void:
	var ability := BattleAbility.new()
	ability.targeting = targeting
	ability.executions.assign(rows)
	ability.animation = _animation(animation) if animation != "" else null
	ability.ability_tag = StringName("Ability.Passive." + _dashboard(name))
	ability.trigger_event_tag = event
	ability.asset_tags.assign(options.get("asset_tags", []))
	ability.activation_query = options.get("query")
	ability.trigger_chance_x100 = Fixed.from_typed(options.get("trigger_chance", 0))
	ability.echo_scale_x100 = Fixed.from_typed(options.get("echo_scale", 0))
	_add(level, name, title, ability, text, "passive", &"")


## The next rank of `base` (an ability file): a copy with the changed rows ({row id: {"percent", "tough", "chance", "flat",
## "effect"}}), its own tag and, above 0, its own SP cost.
func _rank(level: int, name: String, title: String, base: String, changes: Dictionary, cost: int, text: String,
		options: Dictionary = {}) -> void:
	var from := (load(CONTENT + "abilities/%s.tscn" % base) as PackedScene).instantiate() as BattleAbility
	var ability := BattleAbility.new()
	ability.targeting = from.targeting
	ability.animation = from.animation
	ability.trigger_event_tag = from.trigger_event_tag
	ability.asset_tags.assign(from.asset_tags)
	ability.cast_cue_tags.assign(from.cast_cue_tags)
	ability.activation_query = _own(from.activation_query)
	ability.trigger_chance_x100 = Fixed.from_typed(options["trigger_chance"]) if options.has("trigger_chance") else from.trigger_chance_x100
	ability.echo_scale_x100 = Fixed.from_typed(options["echo_scale"]) if options.has("echo_scale") else from.echo_scale_x100
	ability.cost_effect = _cost(cost) if cost > 0 else from.cost_effect
	var prefix := "Ability."
	var kind := "active"
	if from.is_triggered():
		prefix = "Ability.Passive."
		kind = "passive"
	elif from.is_ultimate():
		prefix = "Ability.Ult."
		kind = "ult"
	ability.ability_tag = StringName(prefix + _dashboard(name))
	for row in from.executions:
		var copy := row.duplicate() as ExecutionRow
		var change: Dictionary = changes.get(String(row.id), {})
		if change.has("percent"):
			copy.multiplier_x100 = Fixed.from_typed(change["percent"])
		if change.has("flat"):
			copy.flat_damage_x100 = Fixed.from_typed(change["flat"])
		if change.has("tough"):
			copy.toughness_x100 = Fixed.from_typed(change["tough"])
		if change.has("chance"):
			copy.chance_x100 = Fixed.from_typed(change["chance"])
		if change.has("effect"):
			copy.effect = _effect(change["effect"])
		ability.executions.append(copy)
	for id in changes:
		if not from.executions.any(func(row: ExecutionRow) -> bool: return String(row.id) == id):
			_failed.append("%s: %s has no row %s" % [name, base, id])
	from.free()
	if cost > 0:
		kind += " (%d SP)" % cost
	_add(level, name, title, ability, text, kind, _tag_of(base))


## One tag segment the way the GodotGAS dashboard writes it (titans_fall_2 → Titansfall2).
func _dashboard(name: String) -> String:
	var joined := name.replace("_", "")
	return joined.left(1).to_upper() + joined.substr(1)


## A shared query stays shared; one built into the base scene is copied into the rank's own scene.
func _own(query: GameplayTagQuery) -> GameplayTagQuery:
	if query == null or not query.resource_path.contains("::"):
		return query
	return query.duplicate() as GameplayTagQuery


func _add(level: int, name: String, title: String, ability: BattleAbility, text: String, kind: String, replaces: StringName) -> void:
	ability.name = name.to_pascal_case()
	ability.ability_name = title
	ability.description = text
	var keys: Array = ExecutionReader.sequence_for(ability.animation) if ability.animation != null else []
	var ids: Array = ability.executions.map(func(row: ExecutionRow) -> StringName: return row.id)
	for id in ids:
		if not keys.has(id):
			_failed.append("%s: its animation never fires row %s" % [name, id])
	for key in keys:
		if not ids.has(key):
			_failed.append("%s: its animation fires %s, which is no row" % [name, key])
	var path := CONTENT + "abilities/%s.tscn" % name
	if _force and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_rows.get_or_add(_class, []).append({"level": level, "name": name, "title": title, "replaces": replaces, "kind": kind, "text": text})
	_pack(path, ability)
	ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)


func _animation(name: String) -> Animation:
	var animation := load(CONTENT + "animations/%s.tres" % name) as Animation
	if animation == null:
		_failed.append("animations/%s is missing" % name)
	return animation


func _tag_of(name: String) -> StringName:
	return SkillTags.tag_of(load(CONTENT + "abilities/%s.tscn" % name))


## The shared cost effect of `amount` SP, made when missing (the cost pass's file).
func _cost(amount: int) -> GameplayEffect:
	var key := "sp_cost_%d" % amount
	var path := CONTENT + "effects/%s.tres" % key
	if not ResourceLoader.exists(path):
		var calc: Resource = load(CONTENT + "exec_calcs/exec_calc_cost.gd").new()
		calc.set("amount_x100", Fixed.from_typed(amount))
		var effect := GameplayEffect.new()
		effect.policy = GameplayEffect.DurationPolicy.INSTANT
		effect.executions.append(calc)
		_save("effects/" + key, effect)
	return load(path)


# --- The lists and the character files ---------------------------------------------------------------------------------------------

func _print_lists() -> void:
	for name in _rows:
		print("\n%s" % name.capitalize())
		for row in _rows[name]:
			var replaces := " (replaces %s)" % String(row["replaces"]).trim_prefix("Ability.") if row["replaces"] != &"" else ""
			print("  %2d  %-16s %s%s: %s" % [row["level"], row["kind"], row["title"], replaces, row["text"]])


## Adds the class's rows and growth bands to its character file as a text edit; a row already in the file is left alone.
func _apply(name: String) -> void:
	var path := CONTENT + "characters/%s.tres" % name
	var text := FileAccess.get_file_as_string(path)
	var kind: String = GROWTH_KINDS.keys().filter(func(key: String) -> bool: return GROWTH_KINDS[key].has(name))[0]
	var externals := ""
	var subs := ""
	var added := PackedStringArray()
	var lines := PackedStringArray()
	for row in _rows[name]:
		if text.contains("abilities/%s.tscn\"" % row["name"]):
			continue
		externals += "[ext_resource type=\"PackedScene\" path=\"res://content/demo/abilities/%s.tscn\" id=\"lc_%s\"]\n" % [row["name"], row["name"]]
		subs += "[sub_resource type=\"Resource\" id=\"LevelSkill_lc_%s\"]\nscript = ExtResource(\"97_lvl\")\nlevel = %d\nability = ExtResource(\"lc_%s\")\n%s\n" % [
			row["name"], row["level"], row["name"], "replaces = &\"%s\"\n" % row["replaces"] if row["replaces"] != &"" else ""]
		added.append("SubResource(\"LevelSkill_lc_%s\")" % row["name"])
		lines.append("    (none) → level %d: %s%s" % [row["level"], row["name"], " replaces %s" % row["replaces"] if row["replaces"] != &"" else ""])
	var list := RegEx.create_from_string("(?m)^level_skills = .*\\]\\)$").search(text)
	if not text.contains("id=\"97_lvl\"") or list == null:
		_failed.append("%s: no level_skills line to extend" % path)
		return
	if not added.is_empty():
		var longer := list.get_string().trim_suffix("])") + ", " + ", ".join(added) + "])"
		print("%s  level_skills: +%d rows\n%s" % [path, added.size(), "\n".join(lines)])
		text = text.replace(list.get_string(), longer)
	if not text.contains("growth_bands = ") and not text.contains("\nlevel_effect = ExtResource("):
		_failed.append("%s: no level_effect line to replace with growth bands" % path)
		return
	var effect := RegEx.create_from_string("(?m)^level_effect = ExtResource\\(\"([^\"]+)\"\\)$").search(text)
	if effect != null and not text.contains("growth_bands = "):
		var old_line := RegEx.create_from_string("(?m)^\\[ext_resource [^\\n]*id=\"%s\"\\]\\n" % effect.get_string(1)).search(text)
		externals += "[ext_resource type=\"Script\" path=\"res://game/defs/growth_band.gd\" id=\"lc_band\"]\n"
		var bands := PackedStringArray()
		for index in BAND_LEVELS.size():
			externals += "[ext_resource type=\"Resource\" path=\"res://content/demo/effects/growth_%s_%d.tres\" id=\"lc_growth_%d\"]\n" % [kind, index + 1, index + 1]
			subs += "[sub_resource type=\"Resource\" id=\"GrowthBand_%d\"]\nscript = ExtResource(\"lc_band\")\nfrom_level = %d\neffect = ExtResource(\"lc_growth_%d\")\n\n" % [
				index + 1, BAND_LEVELS[index], index + 1]
			bands.append("SubResource(\"GrowthBand_%d\")" % (index + 1))
		print("%s  level_effect: growth_%s → growth_bands: %s" % [path, kind, ", ".join(BAND_LEVELS.map(func(from: int) -> String:
			return "growth_%s_%d from level %d" % [kind, BAND_LEVELS.find(from) + 1, from]))])
		text = text.replace(effect.get_string(), "growth_bands = Array[ExtResource(\"lc_band\")]([%s])" % ", ".join(bands))
		if old_line != null:
			text = text.replace(old_line.get_string(), "")
	# The new ext_resources after the last one, the new sub_resources before [resource].
	var last := text.rfind("\n[ext_resource ")
	var line_end := text.find("\n", last + 1) + 1
	text = text.substr(0, line_end) + externals + text.substr(line_end)
	text = text.replace("\n[resource]\n", "\n" + subs + "[resource]\n")
	_patched[path] = text
