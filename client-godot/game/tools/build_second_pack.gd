## Builder for spec second-pack (slice 5j): the Blood Moon characters, their moves and effects, the shared battle rules, and the
## Blood Moon items, written into res://content/demo/ through ResourceSaver like the other content builders, whose helpers it
## reuses. It writes only this pass's own new files and never overwrites one that exists (they are the user's to tune); --force
## rewrites this pass's own files. Values are the spec's first proposals, typed as a designer would; tune them in the files.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_second_pack.tscn [-- --force] [-- --step <n>]
## Steps (spec second-pack, built one at a time with the user's check): 1 the shared pieces, Vlad and the Bloodbinder;
## 2 the Vampire Hunter and the Werewolf; 3 the Bloodletter; 4 the 53 Blood Moon items; 5 the level rows (to 50).
extends "res://game/tools/build_level_pass.gd"

const HP_COST: String = CONTENT + "exec_calcs/exec_calc_hp_cost.gd"
const LIFESTEAL_TAG := &"Status.Buff.Lifesteal"
const BLOOD_SET := &"Card.Set.Bloodmoon"
const SHEET := {"crit_rate": 5, "crit_dmg": 50, "energy": 0, "max_mp": 0, "mp": 0, "sp_basic": 0, "max_toughness": 0,
	"toughness": 0}

var _step := 1


func _ready() -> void:
	_force = OS.get_cmdline_user_args().has("--force")
	var args := OS.get_cmdline_user_args()
	if args.has("--step"):
		_step = int(args[args.find("--step") + 1])
	_attributes = load(CONTENT + "attributes/demo_unit_attributes.gd")
	for script in [PERCENT_OF_MAX, EVENT_AMOUNT_CALC, HP_COST, CONTENT + "exec_calcs/exec_calc_detonate.gd"]:
		if load(script) == null:
			_quit("Missing %s (run --import once first)." % script)
			return
	if _step >= 5:
		_items()  # the level rows reuse the items' helpers and effects (bm_i_crit_mark)
	if _step >= 1:
		_shared()
		_vlad()
		_bloodbinder()
	if _step >= 2:
		_hunter()
		_werewolf()
	if _step >= 3:
		_bloodletter()
	if _step == 4:
		_items()
	print("build_second_pack: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _made:
		print("  made    ", path)
	for path in _failed:
		print("  FAILED  ", path)
	get_tree().quit(1 if not _failed.is_empty() else 0)


# --- Shared pieces (B6, B7, B1) --------------------------------------------------------------------------------------------

func _shared() -> void:
	var heal := GameplayEffect.new()
	heal.policy = GameplayEffect.DurationPolicy.INSTANT
	var calc: Resource = load(EVENT_AMOUNT_CALC).new()
	calc.set("attribute", "hp")
	calc.set("target_bonus", "heal_taken")
	heal.executions.append(calc)
	_fx("bm_lifesteal_heal", heal)
	var bleed := (load(CONTENT + "effects/bleed.tres") as GameplayEffect).duplicate(true) as GameplayEffect
	bleed.executions[0].set("percent_x100", Fixed.from_typed(-2))  # 2% max HP per stack per tick
	bleed.max_stacks = 5
	_fx("bm_bleed", bleed)
	var rules_path := CONTENT + "rules/battle_rules.tres"
	if not _exists(rules_path):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CONTENT + "rules"))
		var rules := BattleRules.new()
		rules.id = &"demo.battle_rules"
		rules.bleed_effect = _effect("bm_bleed")
		rules.lifesteal_effect = _effect("bm_lifesteal_heal")
		rules.health_low_x100 = Fixed.from_typed(50)
		rules.health_critical_x100 = Fixed.from_typed(25)
		_write(rules_path, rules)
	_fx("bm_pool_fill", _event_amount_into("energy"))


## An instant effect adding the triggering event's amount (Data.Event.Amount, an EVENT_AMOUNT row) to `attribute`.
func _event_amount_into(attribute: String) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INSTANT
	var calc: Resource = load(EVENT_AMOUNT_CALC).new()
	calc.set("attribute", attribute)
	effect.executions.append(calc)
	return effect


## The cost effect of `percent`% of max HP (B1), made when missing.
func _hp_cost(percent: float) -> GameplayEffect:
	var name := "bm_hp_cost_%s" % str(percent).replace(".", "_")
	if not _r.has("effects/" + name) and not ResourceLoader.exists(CONTENT + "effects/%s.tres" % name):
		var calc: Resource = load(HP_COST).new()
		calc.set("percent_x100", Fixed.from_typed(percent))
		var effect := GameplayEffect.new()
		effect.policy = GameplayEffect.DurationPolicy.INSTANT
		effect.executions.append(calc)
		_fx(name, effect)
	return _effect(name)


## A heal of `percent`% of the target's max HP, scaled by the healer's heal_mult (and its missing-HP bonus) and the target's
## heal_taken.
func _heal_of(percent: float) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INSTANT
	var calc: Resource = load(PERCENT_OF_MAX).new()
	calc.set("percent_x100", Fixed.from_typed(percent))
	calc.set("source_bonus", "heal_mult")
	calc.set("target_bonus", "heal_taken")
	effect.executions.append(calc)
	effect.application_cue_tags.assign(HEAL_CUES)
	return effect


## A copy of an existing animation with its execute keys renamed (and spread over the same span when there are more), so a new
## move can reuse a look with its own rows. Made when missing.
## `sound`: a sound-bank id (presentation/audio/sfx/bank/<id>.tres) that replaces every stream of the copy's audio tracks (an ult's
## own signature sound, spec second-pack 2.6); "" keeps the base's.
func _keyed(base: String, name: String, keys: Array, sound: String = "") -> String:
	var path := CONTENT + "animations/%s.tres" % name
	if not _exists(path):
		var animation := _animation(base).duplicate(true) as Animation
		if sound != "":
			var stream: AudioStream = load("res://presentation/audio/sfx/bank/%s.tres" % sound)
			for track in animation.get_track_count():
				if animation.track_get_type(track) == Animation.TYPE_AUDIO:
					for key in animation.track_get_key_count(track):
						animation.audio_track_set_key_stream(track, key, stream)
		for track in animation.get_track_count():
			if animation.track_get_type(track) != Animation.TYPE_METHOD:
				continue
			var times: Array = []
			for key in range(animation.track_get_key_count(track) - 1, -1, -1):
				var call: Dictionary = animation.track_get_key_value(track, key)
				if call.get("method") == &"execute":
					times.push_front(animation.track_get_key_time(track, key))
					animation.track_remove_key(track, key)
			if times.is_empty():
				continue
			var first: float = times[0]
			var last: float = times[-1] if times.size() > 1 else first + 0.3
			for index in keys.size():
				var time := first if keys.size() == 1 else first + (last - first) * index / (keys.size() - 1)
				animation.track_insert_key(track, time, {"method": &"execute", "args": [StringName(keys[index])]})
		animation.resource_name = name
		_write(path, animation)
	return name


# --- Moves ------------------------------------------------------------------------------------------------------------------

## A base move (no level row): an action, an ult or a passive, by `kind` ("basic", "skill", "ult", "auto_ult", "passive").
func _move(name: String, title: String, kind: String, targeting: int, animation: String, rows: Array, text: String,
		options: Dictionary = {}) -> void:
	var path := CONTENT + "abilities/%s.tscn" % name
	if _force and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if _exists(path):
		_r["abilities/" + name] = load(path)
		return
	var ability := BattleAbility.new()
	ability.name = name.to_pascal_case()
	ability.ability_name = title
	ability.description = text
	ability.targeting = targeting
	var tag_name := name.trim_prefix("bm_")  # the file prefix keeps this pass's files apart; tags read like the others
	ability.executions.assign(rows)
	ability.animation = _animation(animation) if animation != "" else null  # an echo replays the follow-up's own rows
	ability.cost_effect = options.get("cost")
	match kind:
		"basic", "skill":
			ability.ability_tag = StringName("Ability." + _dashboard(tag_name))
			var tags: Array = RolePass.roles_of(ability) + [&"Ability.Usage.Battle"]
			if kind == "basic":
				tags.append(&"Ability.Type.Basic")
			ability.asset_tags.assign(tags)
		"ult":
			ability.ability_tag = StringName("Ability.Ult." + _dashboard(tag_name))
			ability.cost_effect = _effect("ult_cost")
			ability.activation_query = load(CONTENT + "queries/not_controlled.tres")
			ability.asset_tags.assign(RolePass.roles_of(ability) + [&"Ability.Type.Ultimate", &"Ability.Usage.Battle"])
			if options.has("cue"):  # vfx-content-pass: an ultimate's own cast cue (the flourish and its signature)
				ability.cast_cue_tags.assign([options["cue"]])
		"auto_ult":  # spec second-pack D29: a meter ability on the ult charge, cast by itself at a full bar
			ability.ability_tag = StringName("Ability.Ult." + _dashboard(tag_name))
			ability.activation_query = load(CONTENT + "queries/not_controlled.tres")
			ability.meter_attribute = "energy"
			ability.meter_threshold_of = "max_energy"
			ability.meter_threshold_percent_x100 = Fixed.from_typed(100)
			ability.asset_tags.assign(RolePass.roles_of(ability))
		"passive":
			ability.ability_tag = StringName("Ability.Passive." + _dashboard(tag_name))
			ability.trigger_event_tag = options.get("event", Battle.EVENT_BATTLE_START)
			ability.asset_tags.assign(options.get("asset_tags", []))
			ability.activation_query = options.get("query")
			ability.trigger_chance_x100 = Fixed.from_typed(options.get("chance", 0))
			ability.echo_scale_x100 = Fixed.from_typed(options.get("echo", 0))
			ability.subject_query = options.get("subject")
	var keys: Array = ExecutionReader.sequence_for(ability.animation) if ability.animation != null else []
	for row in rows:
		if not keys.has(row.id):
			_failed.append("%s: its animation never fires row %s" % [name, row.id])
	var ids: Array = rows.map(func(row: ExecutionRow) -> StringName: return row.id)
	for key in keys:
		if not ids.has(key):
			_failed.append("%s: its animation fires %s, which has no row" % [name, key])
	_pack(path, ability)
	_r["abilities/" + name] = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)


## A row applying `effect_name` to the action's targets.
func _put(id: String, effect_name: String) -> ExecutionRow:
	return _on(id, effect_name)


## A row adding `percent`% of the event's amount to an attribute through `effect_name` (EVENT_AMOUNT, item-power K6).
func _amount(id: String, effect_name: String, percent: float) -> ExecutionRow:
	_effect(effect_name)
	var row := _row(id, effect_name, ExecutionRow.DamageMode.EVENT_AMOUNT, 0, ExecutionRow.Targets.ALL)
	row.multiplier_x100 = Fixed.from_typed(percent)
	return row


# --- Characters ---------------------------------------------------------------------------------------------------------------

func _new_character(name: String, title: String, color: Color, stats: Dictionary, abilities: Array, tags: Array, growth: String,
		role: String, text: String, health_states: bool = false) -> void:
	var path := CONTENT + "characters/%s.tres" % name
	if _force and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if _exists(path):
		return
	var character := CharacterDefinition.new()
	character.id = StringName("demo.character." + name)
	character.display_name = title
	character.display_color = color
	character.attribute_set = _attributes
	_stats(character, SHEET.merged(stats, true))
	for ability in abilities:
		character.abilities.append(load(CONTENT + "abilities/%s.tscn" % ability))
	character.tags.assign([StringName("Character." + _dashboard(name))] + tags)
	character.role = role
	character.description = text
	character.health_states = health_states
	character.level_skills.assign(_level_skills(name))  # empty before step 5
	character.default_loadout = Loadout.new()
	var band_script: Script = load("res://game/defs/growth_band.gd")
	for index in BAND_LEVELS.size():
		var band: Resource = band_script.new()
		band.set("from_level", BAND_LEVELS[index])
		band.set("effect", _effect("growth_%s_%d" % [growth, index + 1]))
		character.growth_bands.append(band)
	_write(path, character)


## Every class's shared kit: ult charge from actions and hits, the three break passives and Block.
const KIT := ["ult_charge", "ult_charge_hit", "break_physical", "break_fire", "break_ice", "block"]


# --- Vlad, the Vampire (2.2) -----------------------------------------------------------------------------------------------

func _vlad() -> void:
	var A := BattleAbility.Targeting
	var T := ExecutionRow.Targets
	_fx("bm_vlad_lifesteal", _infinite({"lifesteal": 20}, false))
	_fx("bm_thirst", _infinite({"missing_hp_dmg": 0.4}, false))
	var feast := _add_buff({"lifesteal": 30}, 2, [LIFESTEAL_TAG])
	feast.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_feast_lifesteal", feast)
	_move("bm_fang", "Fang", "basic", A.SINGLE_ENEMY, "bite", [_hit("bite", 100, PHYSICAL, {"tough": 30})],
		"100% ATK Physical to one enemy.")
	_move("bm_blood_lance", "Blood Lance", "skill", A.SINGLE_ENEMY, "execute", [_hit("execute", 220, PHYSICAL, {"tough": 60})],
		"Costs 12% max HP. 220% ATK Physical to one enemy.", {"cost": _hp_cost(12)})
	_move("bm_crimson_sweep", "Crimson Sweep", "skill", A.ALL_ENEMIES, "cleave", [_hit("cleave", 120, PHYSICAL, {"tough": 30})],
		"Costs 18% max HP. 120% ATK Physical to every enemy.", {"cost": _hp_cost(18)})
	_move("bm_night_feast", "Night Feast", "ult", A.BLAST_ENEMY, _keyed("crush", "bm_night_feast", ["crush", "quake"], "ult.night_feast"),
		[_hit("crush", 300, PHYSICAL, {"tough": 90, "on": T.PRIMARY}), _hit("quake", 100, PHYSICAL, {"tough": 30, "on": T.ADJACENT})],
		"300% ATK Physical to one enemy and 100% to its neighbours. Afterwards: +30% lifesteal for 2 turns and cleansed.",
		{"cue": &"Cue.Fx.Ult.Nightfeast"})
	_move("bm_feast_after", "Night Feast", "passive", A.SELF, _keyed("purify", "bm_feast_after", ["cleanse", "feast"]),
		[_put("cleanse", "cleanse"), _put("feast", "bm_feast_lifesteal")], "After Night Feast: +30% lifesteal for 2 turns, cleansed.",
		{"event": &"Event.Ability.Used.Ultimate"})
	_move("bm_vampirism", "Lifesteal", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_vlad_lifesteal")],
		"Every hit heals 20% of the damage dealt.")
	_move("bm_thirst", "Thirst", "passive", A.SELF, "blood_pact", [_put("price", "bm_thirst")],
		"+0.4% damage for every 1% of max HP missing.")
	if _step >= 5:
		_vlad_levels()
	_new_character("vampire", "Vlad", Color(0.93, 0.9, 0.9), {"max_hp": 1000, "hp": 1000, "atk": 520, "def": 260, "spd": 102},
		["bm_night_feast", "bm_fang", "bm_blood_lance", "bm_crimson_sweep", "bm_feast_after", "bm_vampirism", "bm_thirst"] + KIT,
		[&"Unit.Role.Damage", &"Unit.Role.Tank", BLOOD_SET], "damage", "Damage dealer / off-tank: HP costs, lifesteal",
		"Pays HP instead of SP and heals by hitting: strong while it keeps hitting, in danger when it can't.", true)


# --- The Bloodbinder (2.3, D29) --------------------------------------------------------------------------------------------

func _bloodbinder() -> void:
	var A := BattleAbility.Targeting
	_fx("bm_binder_lifesteal", _infinite({"lifesteal": 10}, false))
	_fx("bm_martyrs_grace", _infinite({"missing_hp_heal": 0.5}, false))
	_fx("bm_transfusion_heal", _heal_of(25))
	var rite := _add_buff({"lifesteal": 12}, 2, [LIFESTEAL_TAG])
	rite.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_blood_rite", rite)
	_fx("bm_communion_heal", _heal_of(20))
	var communion := _add_buff({"lifesteal": 10}, 2, [LIFESTEAL_TAG])
	communion.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_communion_lifesteal", communion)
	_move("bm_blood_bolt", "Blood Bolt", "basic", A.SINGLE_ENEMY, "witch_bolt", [_hit("bolt", 80, PHYSICAL, {"tough": 30})],
		"80% ATK Physical to one enemy.")
	_move("bm_transfusion", "Transfusion", "skill", A.SINGLE_ALLY, "heal", [_put("heal", "bm_transfusion_heal")],
		"Costs 10% max HP. One ally heals 25% of their max HP.", {"cost": _hp_cost(10)})
	_move("bm_blood_rite", "Blood Rite", "skill", A.ALL_ALLIES, "rally_horn", [_put("rally", "bm_blood_rite")],
		"Costs 15% max HP. The party: +12% lifesteal for 2 turns.", {"cost": _hp_cost(15)})
	_move("bm_crimson_communion", "Crimson Communion", "auto_ult", A.ALL_ALLIES,
		_keyed("sanctuary", "bm_crimson_communion", ["bless", "cleanse", "rite"], "ult.crimson_communion"),
		[_put("bless", "bm_communion_heal"), _put("cleanse", "cleanse"), _put("rite", "bm_communion_lifesteal")],
		"Casts itself when the ult bar is full: every ally heals 20% of their max HP, is cleansed and gets +10% lifesteal for 2 turns.")
	_move("bm_binder_lifesteal", "Blood Bond", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_binder_lifesteal")],
		"Every hit heals 10% of the damage dealt.")
	_move("bm_martyrs_grace", "Martyr's Grace", "passive", A.SELF, "blood_pact", [_put("price", "bm_martyrs_grace")],
		"Heals +0.5% for every 1% of its own max HP missing.")
	for pool in [["bm_pool_taken", Battle.EVENT_DAMAGE_TAKEN], ["bm_pool_ally", Battle.EVENT_ALLY_DAMAGE_TAKEN],
			["bm_pool_cost", Battle.EVENT_COST_HP], ["bm_pool_ally_cost", Battle.EVENT_ALLY_COST_HP]]:
		_move(pool[0], "Blood Pool", "passive", A.SELF, "siphon_sigil", [_amount("charge", "bm_pool_fill", 5)],
			"HP the party loses fills the ult bar (5% of it as ult charge).", {"event": pool[1]})
	if _step >= 5:
		_bloodbinder_levels()
	_new_character("bloodbinder", "Bloodbinder", Color(0.8, 0.79, 0.82), {"max_hp": 950, "hp": 950, "atk": 330, "def": 270,
		"spd": 100}, ["bm_crimson_communion", "bm_blood_bolt", "bm_transfusion", "bm_blood_rite", "bm_binder_lifesteal",
		"bm_martyrs_grace", "bm_pool_taken", "bm_pool_ally", "bm_pool_cost", "bm_pool_ally_cost"] + KIT,
		[&"Unit.Role.Healer", &"Unit.Role.Support", BLOOD_SET], "support", "Support: healer, HP costs",
		"Pays HP to heal and to give the party lifesteal; heals harder the lower it is. Its ult bar fills with the HP the party loses and the ult casts itself.")


# --- Step 2 helpers -----------------------------------------------------------------------------------------------------

const DEBUFF_CUES: Array[StringName] = [&"Cue.Fx.Apply.Debuff", &"Cue.Sfx.Apply.Debuff"]
const SP_KIT := ["ult_charge", "ult_charge_hit", "break_physical", "break_fire", "break_ice", "block", "sp_gain"]


## A damage effect whose hits have `bonus`% more crit rate (100 = always a crit), made when missing.
func _keen_damage(name: String, bonus: float) -> String:
	if not _r.has("effects/" + name) and not ResourceLoader.exists(CONTENT + "effects/%s.tres" % name):
		var effect := (load(CONTENT + "effects/damage.tres") as GameplayEffect).duplicate(true) as GameplayEffect
		effect.executions[0].set("crit_rate_bonus_x100", Fixed.from_typed(bonus))
		_fx(name, effect)
	return name


## A hit row on `effect_name` (a damage effect), like _hit.
func _hit_on(effect_name: String, id: String, percent: float, types: Array, options: Dictionary = {}) -> ExecutionRow:
	_effect(effect_name)
	var row := _row(id, effect_name, ExecutionRow.DamageMode.SCALED, percent, options.get("on", ExecutionRow.Targets.ALL), types)
	row.toughness_x100 = Fixed.from_typed(options.get("tough", 0))
	return row


func _any_query(any: Array = [], ignore: Array = []) -> GameplayTagQuery:
	var query := GameplayTagQuery.new()
	query.require_any_tags.assign(any)
	query.ignore_tags.assign(ignore)
	return query


func _timed(changes: Dictionary, turns: int, granted: Array,
		operation: GameplayEffectModifier.Operation = GameplayEffectModifier.Operation.ADD) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.TURN_BASED
	effect.duration_turns = turns
	effect.stacking_policy = GameplayEffect.StackingPolicy.REFRESH_DURATION
	effect.max_stacks = 1
	effect.granted_tags.assign(granted)
	for attribute_name in changes:
		effect.modifiers.append(_modifier(attribute_name, operation, changes[attribute_name]))
	return effect


# --- The Vampire Hunter (2.4) ----------------------------------------------------------------------------------------------

func _hunter() -> void:
	var A := BattleAbility.Targeting
	var T := ExecutionRow.Targets
	var focus := GameplayEffect.new()  # D11: a stacking status, not a Status.Buff, so never dispelled
	focus.policy = GameplayEffect.DurationPolicy.TURN_BASED  # 99 turns, renewed by each stack: until a crit, cleared at death
	focus.duration_turns = 99
	focus.stacking_policy = GameplayEffect.StackingPolicy.REFRESH_DURATION
	focus.max_stacks = 5
	focus.modifiers.append(_modifier("crit_rate", GameplayEffectModifier.Operation.ADD, 8))
	focus.modifiers.append(_modifier("crit_dmg", GameplayEffectModifier.Operation.ADD, 12))
	focus.granted_tags.assign([&"Status.Focus"])
	_fx("bm_focus", focus)
	var spend := GameplayEffect.new()
	spend.policy = GameplayEffect.DurationPolicy.INSTANT
	spend.remove_effects_with_tags.assign([&"Status.Focus"])
	_fx("bm_focus_spent", spend)
	var silvered := _timed({"heal_taken": -50}, 2, [&"Status.Debuff.Silvered"])  # D12
	silvered.application_query = _any_query([], [&"Immune.Silvered", &"Immune.Debuff"])
	silvered.application_cue_tags.assign(DEBUFF_CUES)
	_fx("bm_silvered", silvered)
	_move("bm_silver_bolt", "Silver Bolt", "basic", A.SINGLE_ENEMY, "quick_shot", [_hit("shot", 100, PHYSICAL, {"tough": 30})],
		"100% ATK Physical to one enemy.")
	_move("bm_holy_water", "Holy Water", "skill", A.BLAST_ENEMY, _keyed("fire_bolt", "bm_holy_water", ["flask", "splash"]),
		[_hit("flask", 90, FIRE, {"tough": 60, "on": T.PRIMARY}), _hit("splash", 45, FIRE, {"tough": 30, "on": T.ADJACENT})],
		"90% ATK Fire to one enemy and 45% to its neighbours.", {"cost": _cost(43)})
	_move("bm_stake", "Stake", "skill", A.SINGLE_ENEMY, "execute",
		[_hit_on(_keen_damage("bm_damage_keen", 25), "execute", 220, PHYSICAL, {"tough": 60})],
		"220% ATK Physical to one enemy, with +25% crit rate.", {"cost": _cost(53)})
	_move("bm_dawnbreak", "Dawnbreak", "ult", A.SINGLE_ENEMY, _keyed("crush", "bm_dawnbreak", ["crush"], "ult.dawnbreak"),
		[_hit_on(_keen_damage("bm_damage_sure", 100), "crush", 320, PHYSICAL, {"tough": 90})],
		"320% ATK Physical to one enemy, always a crit.", {"cue": &"Cue.Fx.Ult.Dawnbreak"})
	_move("bm_focus", "Focus", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_focus")],
		"Every hit that does not crit: +1 Focus (max 5; each +8% crit rate, +12% crit damage). A crit spends them all.",
		{"event": Battle.EVENT_DAMAGE_DEALT})
	_move("bm_focus_spent", "Focus", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_focus_spent")],
		"A crit spends every Focus.", {"event": &"Event.Damage.Dealt.Critical"})
	_move("bm_silver", "Silver", "passive", A.SINGLE_ENEMY, "siphon_sigil", [_put("charge", "bm_silvered")],
		"Its crits Silver the target: -50% healing received for 2 turns.", {"event": &"Event.Damage.Dealt.Critical"})
	if _step >= 5:
		_hunter_levels()
	_new_character("vampire_hunter", "Vampire Hunter", Color(0.24, 0.27, 0.36), {"max_hp": 850, "hp": 850, "atk": 500,
		"def": 220, "spd": 112, "max_mp": 70, "mp": 70, "sp_basic": 15, "crit_rate": 10, "crit_dmg": 60},
		["bm_dawnbreak", "bm_silver_bolt", "bm_holy_water", "bm_stake", "bm_focus", "bm_focus_spent", "bm_silver"] + SP_KIT,
		[&"Unit.Role.Damage", BLOOD_SET], "damage", "Damage dealer: crits",
		"Builds Focus with every hit that misses a crit, spends it on the crit, and Silvers what it crits: they heal half as much.")


# --- The Werewolf (2.4b) -----------------------------------------------------------------------------------------------------

func _werewolf() -> void:
	var A := BattleAbility.Targeting
	var T := ExecutionRow.Targets
	# Wolf Form (D21): under 50% HP (State.Health.Low, B5) the always-on part is awake; the timed status covers Howl and the
	# ult. Each gives +10% lifesteal; the timed one rests while the low-HP one is awake, so they never add up.
	var nature := _infinite({"lifesteal": 10}, false)
	nature.granted_tags.assign([&"State.WolfForm"])
	nature.ongoing_suppression_query = _any_query([], [Battle.HEALTH_LOW_TAG])
	_fx("bm_wolf_nature", nature)
	var form := _timed({"lifesteal": 10}, 2, [&"Status.WolfForm"])
	form.application_query = _any_query([&"Character.Werewolf"])  # Howl reaches the party; only the Werewolf turns
	form.ongoing_suppression_query = _any_query([Battle.HEALTH_LOW_TAG])
	form.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_wolf_form", form)
	var howl := _timed({"atk": 15}, 2, [&"Status.Buff.AttackUp"], GameplayEffectModifier.Operation.PERCENT_ADD)
	howl.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_howl", howl)
	_move("bm_wolf_rend", "Rend", "basic", A.SINGLE_ENEMY, _keyed("rend", "bm_wolf_rend", ["rend"]), [_hit("rend", 100, PHYSICAL, {"tough": 60})],
		"100% ATK Physical to one enemy, heavy toughness damage.")
	_move("bm_pounce", "Pounce", "skill", A.SINGLE_ENEMY, "bite", [_hit("bite", 180, PHYSICAL, {"tough": 90})],
		"180% ATK Physical to one enemy. Breaking an enemy brings its next action 15% sooner.", {"cost": _cost(43)})
	_move("bm_howl", "Howl", "skill", A.ALL_ALLIES, _keyed("rally_horn", "bm_howl", ["rally", "form"]),
		[_put("rally", "bm_howl"), _put("form", "bm_wolf_form")], "Wolf Form for 2 turns; the party +15% ATK for 2 turns.",
		{"cost": _cost(53)})
	var claws: Array = []
	for index in 5:
		claws.append(_hit("c%d" % (index + 1), 50, PHYSICAL, {"tough": 30, "on": T.RANDOM}))
	_move("bm_moonfall_frenzy", "Moonfall Frenzy", "ult", A.ALL_ENEMIES,
		_keyed("cleave", "bm_moonfall_frenzy", ["c1", "c2", "c3", "c4", "c5"], "ult.moonfall_frenzy"), claws,
		"5 claws of 50% ATK Physical at random enemies; then Wolf Form for 2 turns.", {"cue": &"Cue.Fx.Ult.Moonfallfrenzy"})
	_move("bm_frenzy_after", "Moonfall Frenzy", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_wolf_form")],
		"After Moonfall Frenzy: Wolf Form for 2 turns.", {"event": &"Event.Ability.Used.Ultimate"})
	_move("bm_wolf_nature", "Wolf Form", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_wolf_nature")],
		"Under 50% HP: Wolf Form.")
	var claw_query := _any_query([&"State.WolfForm", &"Status.WolfForm"])
	for used in [["basic", &"Event.Ability.Used.Basic"], ["skill", &"Event.Ability.Used.Skill"],
			["ult", &"Event.Ability.Used.Ultimate"]]:
		_move("bm_claw_" + used[0], "Claw", "passive", A.SINGLE_ENEMY, _keyed("strike", "bm_claw", ["claw"]),
			[_hit("claw", 40, PHYSICAL, {"tough": 15})],
			"In Wolf Form, after each of its actions: a 40% ATK Physical follow-up on its target.",
			{"event": used[1], "query": claw_query, "asset_tags": FOLLOW_UP})
	_move("bm_pounce_break", "Pounce", "passive", A.SELF, "siphon_sigil", [_on("charge", "gravity_pull", {"delay": -15})],
		"Breaking an enemy brings its next action 15% sooner.", {"event": &"Event.Damage.Dealt.Break"})
	if _step >= 5:
		_werewolf_levels()
	_new_character("werewolf", "Werewolf", Color(0.45, 0.43, 0.42), {"max_hp": 1050, "hp": 1050, "atk": 500, "def": 280,
		"spd": 104, "max_mp": 60, "mp": 60, "sp_basic": 17},
		["bm_moonfall_frenzy", "bm_wolf_rend", "bm_pounce", "bm_howl", "bm_frenzy_after", "bm_wolf_nature", "bm_claw_basic",
		"bm_claw_skill", "bm_claw_ult", "bm_pounce_break"] + SP_KIT,
		[&"Unit.Role.Break", &"Unit.Role.FollowUp", &"Unit.Role.Damage", BLOOD_SET], "damage", "Breaker: follow-ups, Wolf Form",
		"Breaks shields and claws after each action in Wolf Form: under half HP, or for 2 turns after Howl or its ult.", true)


# --- Step 3: shared pieces of the Bleed and Silver kits ---------------------------------------------------------------------

const DETONATE_CALC: String = CONTENT + "exec_calcs/exec_calc_detonate.gd"


## The detonation (a DoT's remaining ticks at once, at `share`%) and the purge that follows it, made when missing.
func _detonate_pair() -> void:
	if not _r.has("effects/bm_bleed_detonate") and not ResourceLoader.exists(CONTENT + "effects/bm_bleed_detonate.tres"):
		var blast := GameplayEffect.new()
		blast.policy = GameplayEffect.DurationPolicy.INSTANT
		blast.executions.append(load(DETONATE_CALC).new())
		_fx("bm_bleed_detonate", blast)
	if not _r.has("effects/bm_bleed_purge") and not ResourceLoader.exists(CONTENT + "effects/bm_bleed_purge.tres"):
		var purge := GameplayEffect.new()
		purge.policy = GameplayEffect.DurationPolicy.INSTANT
		purge.remove_effects_with_tags.assign([Battle.BLEED_TAG])
		_fx("bm_bleed_purge", purge)


## A Bleed of `turns` turns (bm_bleed is 2), made when missing.
func _bleed_for(turns: int) -> String:
	if turns == 2:
		return "bm_bleed"
	var name := "bm_bleed_%d" % turns
	if not _r.has("effects/" + name) and not ResourceLoader.exists(CONTENT + "effects/%s.tres" % name):
		var bleed := _effect("bm_bleed").duplicate(true) as GameplayEffect
		bleed.duration_turns = turns
		_fx(name, bleed)
	return name


## A heal of `percent`% of the triggering event's amount (an EVENT_AMOUNT row on the lifesteal heal).
func _amount_heal(id: String, percent: float) -> ExecutionRow:
	return _amount(id, "bm_lifesteal_heal", percent)


# --- The Bloodletter (2.4c) ------------------------------------------------------------------------------------------------

func _bloodletter() -> void:
	var A := BattleAbility.Targeting
	_detonate_pair()
	_fx("bm_overheal_shield", _event_amount_into("shield"))  # the rules' overheal effect (Velvet Fangs)
	var letting := _timed({"bleed_lifesteal": 15}, 2, [&"Status.Buff.Letting"])
	letting.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_letting", letting)
	var lancet_bleed := _on("bleed", "bm_bleed", {"chance": 60})
	_move("bm_lancet", "Lancet", "basic", A.SINGLE_ENEMY, "pinprick", [_hit("prick", 90, PHYSICAL, {"tough": 30}), lancet_bleed],
		"90% ATK Physical to one enemy; 60% chance of 1 Bleed stack (2 turns).")
	var long_bleed := _bleed_for(3)
	_move("bm_open_vein", "Open Vein", "skill", A.SINGLE_ENEMY, _keyed("hemorrhage", "bm_open_vein", ["cut", "b1", "b2", "b3"]),
		[_hit("cut", 60, PHYSICAL, {"tough": 30}), _put("b1", long_bleed), _put("b2", long_bleed), _put("b3", long_bleed)],
		"60% ATK Physical and 3 Bleed stacks (3 turns) on one enemy.", {"cost": _cost(43)})
	_move("bm_siphon", "Siphon", "skill", A.SINGLE_ENEMY, _keyed("bleed_blast", "bm_siphon", ["blast", "clear"]),
		[_put("blast", "bm_bleed_detonate"), _put("clear", "bm_bleed_purge")],
		"Detonates every Bleed stack on one enemy (all its remaining ticks at once); the party heals 50% of that damage, shared.",
		{"cost": _cost(53)})
	_move("bm_siphon_share", "Siphon", "passive", A.ALL_ALLIES, "mend", [_amount_heal("regen", 12.5)],
		"A detonation heals every ally 12.5% of its damage (50% shared by a party of four).",
		{"event": &"Event.Damage.Dealt.Detonate"})
	_move("bm_crimson_letting", "Crimson Letting", "ult", A.ALL_ENEMIES, _keyed("bleeding_out", "bm_crimson_letting", ["l1", "l2"], "ult.crimson_letting"),
		[_put("l1", "bm_bleed"), _put("l2", "bm_bleed")],
		"2 Bleed stacks on every enemy; for 2 turns, the party's hits on a Bleeding enemy heal them 15% of the damage.",
		{"cue": &"Cue.Fx.Ult.Crimsonletting"})
	_move("bm_letting_after", "Crimson Letting", "passive", A.ALL_ALLIES, "rally_horn", [_put("rally", "bm_letting")],
		"After Crimson Letting: the party's hits on a Bleeding enemy heal 15% of the damage for 2 turns.",
		{"event": &"Event.Ability.Used.Ultimate"})
	_move("bm_leeching_wounds", "Leeching Wounds", "passive", A.LOWEST_ALLY, "mend", [_amount_heal("regen", 20)],
		"Each tick of a Bleed it applied heals the most hurt ally 20% of the tick.", {"event": Battle.EVENT_DOT_DEALT})
	if _step >= 5:
		_bloodletter_levels()
	_new_character("bloodletter", "Bloodletter", Color(0.68, 0.66, 0.66), {"max_hp": 900, "hp": 900, "atk": 430, "def": 240,
		"spd": 106, "max_mp": 70, "mp": 70, "sp_basic": 16},
		["bm_crimson_letting", "bm_lancet", "bm_open_vein", "bm_siphon", "bm_siphon_share", "bm_letting_after",
		"bm_leeching_wounds"] + SP_KIT,
		[&"Unit.Role.Dot", &"Unit.Role.Support", BLOOD_SET], "support", "DoT / support: Bleed that heals",
		"Bleeds enemies, detonates the Bleed for a party heal, and every tick of its Bleed heals the most hurt ally.")


# --- Step 3b: the Blood Moon items (2.5) ------------------------------------------------------------------------------------

const ECHO := [&"Ability.Type.Echo"]
const STRIKE_TAG := [&"Ability.Type.Strike"]
const ENEMY_ROOT := &"Enemy"
const PRICES := {&"Item.Rarity.Common": 5, &"Item.Rarity.Rare": 7, &"Item.Rarity.Epic": 9, &"Item.Rarity.Legendary": 12}


## An item of this pack: its pools, rarity, the Blood Moon set and its fit tags (`fits`: "Fit.X" / "Grants.X").
func _bm_item(name: String, title: String, pools: Array, rarity: StringName, fits: Array, abilities: Array, effects: Array,
		text: String) -> void:
	var path := CONTENT + "items/%s.tres" % name
	if _force and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_described(name, title, _bm_tags(pools, rarity, fits), PRICES[rarity], _grants(abilities, effects), text)


## A piece of armor or a weapon of this pack (`slot`: Weapon, Body, Head, ...).
func _bm_piece(name: String, title: String, slot: String, pools: Array, rarity: StringName, fits: Array, abilities: Array,
		effects: Array, text: String) -> void:
	var path := CONTENT + "equipment/%s.tres" % name
	if _force and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_piece(name, title, slot, _bm_tags(pools, rarity, fits), PRICES[rarity], _grants(abilities, effects), text)


func _bm_tags(pools: Array, rarity: StringName, fits: Array) -> Array:
	var tags: Array = pools + [rarity, BLOOD_SET]
	for fit in fits:
		tags.append(StringName("Item." + fit))
	return tags


func _grants(abilities: Array, effects: Array) -> AbilitySet:
	if (abilities + effects).is_empty():
		return null
	for effect_name in effects:
		_effect(effect_name)
	return _ability_set(abilities, effects)


## A stat effect that is always on: [[attribute, ADD or PERCENT, typed], ...].
func _stat_fx(name: String, changes: Array) -> String:
	_fx(name, _mixed_infinite(changes))
	return name


## A stat effect that is on only while its holder is under its low-HP line (B5): GodotGAS suppresses it otherwise. Its item
## also grants bm_i_tracked, so the holder carries the states.
func _low_fx(name: String, changes: Array) -> String:
	var effect := _mixed_infinite(changes)
	effect.ongoing_suppression_query = _any_query([], [Battle.HEALTH_LOW_TAG])
	_fx(name, effect)
	return name


func _flag(name: String, turns: int, tag: StringName) -> String:
	_fx(name, _timed({}, turns, [tag]))
	return name


func _purge_of(name: String, tag: StringName) -> String:
	var purge := GameplayEffect.new()
	purge.policy = GameplayEffect.DurationPolicy.INSTANT
	purge.remove_effects_with_tags.assign([tag])
	_fx(name, purge)
	return name


func _heal_fx(name: String, percent: float) -> String:
	_fx(name, _heal_of(percent))
	return name


func _items_shared() -> void:
	var tracked := GameplayEffect.new()
	tracked.policy = GameplayEffect.DurationPolicy.INFINITE
	tracked.granted_tags.assign([Battle.HEALTH_TRACKED_TAG])
	_fx("bm_i_tracked", tracked)
	_keyed("strike", "bm_i_strike", ["strike"])
	_keyed("pinprick", "bm_i_two_bleeds", ["b1", "b2"])
	_keyed("bleed_blast", "bm_i_burst", ["blast", "clear"])


func _items() -> void:
	var A := BattleAbility.Targeting
	var bleeding := _any_query([Battle.BLEED_TAG])
	var silvered := _any_query([&"Status.Debuff.Silvered"])
	var an_enemy := _any_query([ENEMY_ROOT])
	_items_shared()

	# Common (9)
	_heal_fx("bm_i_vial_heal", 15)
	_move("bm_i_blood_vial", "Blood Vial", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_i_vial_heal")],
		"On a kill: heal 15% of max HP.", {"event": &"Event.Unit.Killed"})
	_bm_item("blood_vial", "Blood Vial", [T, S, C], COMMON, ["Fit.Survival"], ["bm_i_blood_vial"], [], "On a kill: heal 15% of max HP.")
	_bm_item("fencers_glove", "Fencer's Glove", [T, S], COMMON, ["Fit.FollowUp"], [],
		[_stat_fx("bm_i_fencers_glove", [["follow_up_dmg", ADD, 15]])], "Follow-ups deal +15% damage.")
	_bm_item("blood_bandage", "Blood Bandage", [T, S, C], COMMON, ["Fit.Survival", "Fit.Healing"], [],
		[_low_fx("bm_i_blood_bandage", [["heal_taken", ADD, 15]]), "bm_i_tracked"], "+15% healing received while under 50% HP.")
	_bm_item("leech_tooth", "Leech Tooth", [T, C], COMMON, ["Fit.Lifesteal", "Fit.Survival"], [],
		[_stat_fx("bm_i_leech_tooth", [["lifesteal", ADD, 8]])], "+8% lifesteal.")
	_bm_item("silver_tip", "Silver Tip", [T, S, C], COMMON, ["Fit.Damage", "Fit.Crit"], [],
		[_stat_fx("bm_i_silver_tip", [["crit_rate", ADD, 8]])], "+8% crit rate.")
	_bm_item("hunters_whetstone", "Hunter's Whetstone", [T, S, C], COMMON, ["Fit.Damage", "Fit.Crit"], [],
		[_stat_fx("bm_i_hunters_whetstone", [["crit_dmg", ADD, 15]])], "+15% crit damage.")
	_bm_item("scalpel_kit", "Scalpel Kit", [T, S, C], COMMON, ["Fit.Bleed", "Fit.Dot", "Grants.Dot"], [],
		[_stat_fx("bm_i_scalpel_kit", [["bleed_chance", ADD, 15]])], "+15% Bleed chance.")
	_bm_item("crimson_poultice", "Crimson Poultice", [T, S, C], COMMON, ["Fit.Healing"], [],
		[_stat_fx("bm_i_crimson_poultice", [["heal_mult", ADD, 10]])], "Give +10% healing.")
	_bm_item("moonfang_charm", "Moonfang Charm", [T, S, C], COMMON, ["Fit.Break"], [],
		[_stat_fx("bm_i_moonfang_charm", [["toughness_dmg", ADD, 15]])], "+15% toughness damage.")

	# Rare (18)
	_bm_item("blood_chalice", "Blood Chalice", [T, S], RARE, ["Fit.Lifesteal", "Fit.Damage", "Fit.Survival"], [],
		[_stat_fx("bm_i_blood_chalice", [["lifesteal", ADD, 15], ["atk", PERCENT, 10]])], "+15% lifesteal; +10% ATK.")
	_move("bm_i_thorned_rose", "Thorned Rose", "passive", A.RANDOM_ENEMY, "bm_i_strike", [_hit("strike", 40, PHYSICAL, {"tough": 15})],
		"When you are healed: a 40% ATK Physical follow-up on a random enemy.",
		{"event": Battle.EVENT_HEAL_RECEIVED, "asset_tags": FOLLOW_UP})
	_bm_item("thorned_rose", "Thorned Rose", [T], RARE, ["Fit.FollowUp", "Fit.Healing", "Grants.FollowUp", "Fit.Break"], ["bm_i_thorned_rose"], [],
		"When you are healed, a 40% ATK follow-up on a random enemy.")
	var focus := _effect("bm_focus").duplicate(true) as GameplayEffect
	focus.max_stacks = 3
	_fx("bm_i_focus", focus)
	_move("bm_i_focus_gain", "Hunter's Focus", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_i_focus")],
		"Every hit that does not crit: +1 Focus (max 3).", {"event": Battle.EVENT_DAMAGE_DEALT})
	_move("bm_i_focus_spent", "Hunter's Focus", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_focus_spent")],
		"A crit spends every Focus.", {"event": &"Event.Damage.Dealt.Critical"})
	_bm_item("hunters_focus", "Hunter's Focus", [T, S], RARE, ["Fit.Damage", "Fit.Crit"], ["bm_i_focus_gain", "bm_i_focus_spent"], [],
		"Gives its holder Focus: every hit that does not crit gives 1 Focus (max 3; each +8% crit rate, +12% crit damage); a crit spends them all.")
	_move("bm_i_holy_water_vial", "Holy Water Vial", "passive", A.SINGLE_ENEMY, "siphon_sigil", [_put("charge", "bm_silvered")],
		"Your crits have a 25% chance to Silver the target.", {"event": &"Event.Damage.Dealt.Critical", "chance": 25})
	_bm_item("holy_water_vial", "Holy Water Vial", [T, S], RARE, ["Fit.Damage", "Fit.Crit"], ["bm_i_holy_water_vial"],
		[_stat_fx("bm_i_holy_water_vial", [["silvered_dmg", ADD, 15]])],
		"Your crits have a 25% chance to Silver the target; +15% damage against Silvered enemies.")
	var garlic := _timed({"heal_taken": -25}, 2, [&"Status.Debuff.Garlic"])
	garlic.application_query = _any_query([], [&"Immune.Garlic", &"Immune.Debuff"])
	garlic.application_cue_tags.assign(DEBUFF_CUES)
	_fx("bm_i_garlic", garlic)
	_move("bm_i_garlic_wreath", "Garlic Wreath", "passive", A.SINGLE_ENEMY, "siphon_sigil", [_put("charge", "bm_i_garlic")],
		"An enemy that hits you: -25% healing received for 2 turns.", {"event": Battle.EVENT_DAMAGE_TAKEN})
	_bm_item("garlic_wreath", "Garlic Wreath", [T, C], RARE, ["Fit.Survival", "Grants.Tank"], ["bm_i_garlic_wreath"], [],
		"An enemy that hits you gets -25% healing received for 2 turns.")
	_bm_item("moonstone_pendant", "Moonstone Pendant", [T, S], RARE, ["Fit.Survival"], [],
		[_stat_fx("bm_i_moonstone_pendant", [["health_low_at", GameplayEffectModifier.Operation.OVERRIDE, 60]]), "bm_i_tracked"],
		"Your low-HP effects start at 60% HP instead of 50%.")
	_move("bm_i_blood_jar", "Blood Jar", "passive", A.SELF, "siphon_sigil", [_amount_heal("charge", 10)],
		"When a Bleed you applied ticks, heal 10% of the tick.", {"event": Battle.EVENT_DOT_DEALT})
	_bm_item("blood_jar", "Blood Jar", [T, S], RARE, ["Fit.Bleed", "Fit.Dot", "Fit.Survival"], ["bm_i_blood_jar"],
		[_stat_fx("bm_i_bleed_5", [["bleed_chance", ADD, 5]])], "+5% Bleed chance; when a Bleed you applied ticks, heal 10% of the tick.")
	_bm_piece("barbed_lancet", "Barbed Lancet", "Weapon", [T], RARE, ["Fit.Bleed", "Fit.Dot", "Fit.Damage"], [],
		[_stat_fx("bm_i_barbed_lancet", [["atk", ADD, 25], ["bleed_chance", ADD, 5], ["bleed_turns", ADD, 1]])],
		"+25 ATK, +5% Bleed chance; your Bleeds last 1 turn longer.")
	_heal_fx("bm_i_tourniquet_heal", 5)
	_move("bm_i_tourniquet", "Tourniquet", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_i_tourniquet_heal")],
		"When a Bleeding enemy hits you, heal 5% of your max HP.", {"event": Battle.EVENT_DAMAGE_TAKEN, "subject": bleeding})
	_bm_item("tourniquet", "Tourniquet", [T, C], RARE, ["Fit.Bleed", "Fit.Dot", "Fit.Survival"], ["bm_i_tourniquet"], ["bm_i_bleed_5"],
		"+5% Bleed chance; when a Bleeding enemy hits you, heal 5% of your max HP.")
	_bm_item("clotted_phial", "Clotted Phial", [T, S], RARE, ["Fit.Bleed", "Fit.Dot"], [],
		[_stat_fx("bm_i_clotted_phial", [["bleed_chance", ADD, 5], ["bleed_stacks", ADD, 2]])],
		"+5% Bleed chance; your Bleeds can stack 2 more times.")
	_fx("bm_i_pool_chalice_heal", _heal_of(10))
	_move("bm_i_pool_chalice", "Pool Chalice", "passive", A.SINGLE_ALLY, "mend", [_put("regen", "bm_i_pool_chalice_heal")],
		"When an ally drops under 50% HP, heal them 10% of their max HP.", {"event": &"Event.Ally.Health.Low"})
	_move("bm_i_party_tracked", "Pool Chalice", "passive", A.ALL_ALLIES, "rally_horn", [_put("rally", "bm_i_tracked")],
		"The party's low-HP states are tracked.")
	_bm_item("pool_chalice", "Pool Chalice", [T, S], RARE, ["Fit.Healing", "Fit.Party"], ["bm_i_pool_chalice", "bm_i_party_tracked"], [],
		"When an ally drops under 50% HP, heal them 10% of their max HP.")
	var vein := _timed({"heal_mult": 15}, 2, [&"Status.Buff.VeinTap"])
	vein.max_stacks = 2
	vein.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_i_vein_tap", vein)
	_move("bm_i_vein_tap", "Vein Tap", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_i_vein_tap")],
		"Each time you pay HP: +15% healing you give for 2 turns (stacks twice).", {"event": Battle.EVENT_COST_HP})
	_bm_item("vein_tap", "Vein Tap", [T, S], RARE, ["Fit.Healing", "Fit.HpCost"], ["bm_i_vein_tap"], [],
		"Each time you pay HP: +15% healing you give for 2 turns (stacks twice).")
	_bm_item("martyrs_vial", "Martyr's Vial", [T, C], RARE, ["Fit.Healing"], [],
		[_stat_fx("bm_i_martyrs_vial", [["missing_hp_heal", ADD, 0.33]])],
		"Your heals +1% for every 3% of your own max HP missing.")
	var sure := _mixed_infinite([["crit_rate", ADD, 100]])
	sure.granted_tags.assign([&"State.SureShot"])
	_fx("bm_i_sure_shot", sure)
	_move("bm_i_sure_shot", "Silver Bolt Case", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_i_sure_shot")],
		"Your first hit in each battle is a crit.")
	_move("bm_i_sure_shot_spent", "Silver Bolt Case", "passive", A.SELF, "siphon_sigil",
		[_put("charge", _purge_of("bm_i_sure_shot_spent", &"State.SureShot"))], "After the first hit.", {"event": Battle.EVENT_DAMAGE_DEALT})
	_bm_item("silver_bolt_case", "Silver Bolt Case", [T, S], RARE, ["Fit.Damage", "Fit.Crit"], ["bm_i_sure_shot", "bm_i_sure_shot_spent"],
		[_stat_fx("bm_i_silver_bolt_case", [["crit_rate", ADD, 5]])], "+5% crit rate; your first hit in each battle is a crit.")
	_bm_piece("rending_claws", "Rending Claws", "Weapon", [T], RARE, ["Fit.FollowUp", "Fit.Break", "Fit.Damage"], [],
		[_stat_fx("bm_i_rending_claws", [["atk", ADD, 25], ["follow_up_tough", ADD, 20]])],
		"+25 ATK; your follow-ups deal +20% toughness damage.")
	_fx("bm_i_pack", _timed({}, 99, [&"State.PackReady"]))
	_move("bm_i_pack_ready", "Pack Sigil", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_i_pack")],
		"When you break an enemy, your next follow-up hits twice.", {"event": &"Event.Damage.Dealt.Break"})
	_move("bm_i_pack_echo", "Pack Sigil", "passive", A.SELF, "", [], "Your next follow-up hits twice.",
		{"event": Battle.EVENT_ATTACK_FOLLOW_UP, "asset_tags": ECHO, "echo": 100, "query": _any_query([&"State.PackReady"]),
		"subject": an_enemy})
	_move("bm_i_pack_spent", "Pack Sigil", "passive", A.SELF, "siphon_sigil",
		[_put("charge", _purge_of("bm_i_pack_spent", &"State.PackReady"))], "After the follow-up.",
		{"event": Battle.EVENT_ATTACK_FOLLOW_UP})
	_bm_item("pack_sigil", "Pack Sigil", [T, S], RARE, ["Fit.FollowUp", "Fit.Break"], ["bm_i_pack_ready", "bm_i_pack_echo",
		"bm_i_pack_spent"], [], "When you break an enemy, your next follow-up hits twice.")
	_bm_piece("silverbane_pelt", "Silverbane Pelt", "Body", [T, C], RARE, ["Fit.Survival"], [],
		[_stat_fx("bm_i_pelt_hp", [["max_hp", ADD, 60]]), _low_fx("bm_i_silverbane_pelt", [["dmg_taken", ADD, -10]]), "bm_i_tracked"],
		"+60 max HP; take 10% less damage while under 50% HP.")
	var signet := _event_amount_into("hp")
	signet.executions[0].set("target_bonus", "heal_taken")
	signet.executions[0].set("source_scale", "lifesteal")
	signet.application_cue_tags.assign(HEAL_CUES)
	_fx("bm_i_signet_heal", signet)
	_move("bm_i_crimson_signet", "Crimson Signet", "passive", A.SELF, "siphon_sigil", [_amount("charge", "bm_i_signet_heal", 100)],
		"Your lifesteal is doubled on a crit.", {"event": &"Event.Damage.Dealt.Critical"})
	_bm_item("crimson_signet", "Crimson Signet", [T, S], RARE, ["Fit.Lifesteal", "Fit.Survival", "Fit.Crit"], ["bm_i_crimson_signet"],
		[_stat_fx("bm_i_crimson_signet", [["lifesteal", ADD, 6]])], "+6% lifesteal; your lifesteal is doubled on a crit.")

	# Epic (17)
	_bm_item("sanguine_pact", "Sanguine Pact", [T], EPIC, ["Fit.Survival", "Fit.HpCost"], [],
		[_stat_fx("bm_i_sanguine_pact", [["hp_cost", ADD, -30]])], "Your HP costs are 30% lower.")
	_fx("bm_i_bloodstone", _attack_up(10, 2, 3))
	_move("bm_i_bloodstone", "Bloodstone", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_i_bloodstone")],
		"Each time you pay HP: +10% ATK for 2 turns (stacks 3 times).", {"event": Battle.EVENT_COST_HP})
	_bm_item("bloodstone", "Bloodstone", [T], EPIC, ["Fit.Damage", "Fit.HpCost"], ["bm_i_bloodstone"], [],
		"Each time you pay HP: +10% ATK for 2 turns (stacks 3 times).")
	_bm_piece("heartseeker_fang", "Heartseeker Fang", "Weapon", [B], EPIC, ["Fit.Lifesteal", "Fit.Damage", "Fit.Survival", "Fit.Crit"], [],
		[_stat_fx("bm_i_heartseeker_fang", [["lifesteal", ADD, 20], ["crit_rate", ADD, 15]])], "+20% lifesteal; +15% crit rate.")
	_move("bm_i_crossbow", "Hunter's Crossbow", "passive", A.SINGLE_ENEMY, "siphon_sigil", [_put("charge", "bm_silvered")],
		"Your crits Silver the target.", {"event": &"Event.Damage.Dealt.Critical"})
	_bm_piece("hunters_crossbow", "Hunter's Crossbow", "Weapon", [T], EPIC, ["Fit.Damage", "Fit.Crit"], ["bm_i_crossbow"],
		[_stat_fx("bm_i_hunters_crossbow", [["atk", ADD, 30], ["crit_rate", ADD, 10]])], "+30 ATK, +10% crit rate; your crits Silver the target.")
	_move("bm_i_longcoat", "Hunter's Longcoat", "passive", A.SELF, _keyed("purify", "bm_i_longcoat", ["cleanse"]),
		[_put("cleanse", "cleanse")], "A crit cleanses you.", {"event": &"Event.Damage.Dealt.Critical"})
	_bm_piece("hunters_longcoat", "Hunter's Longcoat", "Body", [T], EPIC, ["Fit.Survival", "Fit.Damage", "Fit.Crit"], ["bm_i_longcoat"],
		[_stat_fx("bm_i_hunters_longcoat", [["max_hp", ADD, 60], ["crit_rate", ADD, 8]])], "+60 max HP, +8% crit rate; a crit cleanses you.")
	_move("bm_i_rosary", "Rosary of Vigil", "passive", A.SINGLE_ENEMY, "siphon_sigil", [_put("charge", "bm_silvered")],
		"Your crits have a 35% chance to Silver the target.", {"event": &"Event.Damage.Dealt.Critical", "chance": 35})
	var vigil := _timed({"crit_rate": 5}, 2, [&"Status.Buff.Vigil"])
	vigil.max_stacks = 3
	vigil.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_i_vigil", vigil)
	_move("bm_i_vigil", "Rosary of Vigil", "passive", A.ALL_ALLIES, "rally_horn", [_put("rally", "bm_i_vigil")],
		"Your crits on a Silvered enemy: the party +5% crit rate for 2 turns (up to +15%).",
		{"event": &"Event.Damage.Dealt.Critical", "subject": silvered})
	_bm_item("rosary_of_vigil", "Rosary of Vigil", [T], EPIC, ["Fit.Damage", "Fit.Party", "Fit.Crit"], ["bm_i_rosary", "bm_i_vigil"], [],
		"Your crits have a 35% chance to Silver the target; your crits on a Silvered enemy give the party +5% crit rate for 2 turns (up to +15%).")
	_bm_item("full_moon_charm", "Full Moon Charm", [T], EPIC, ["Fit.Damage", "Fit.Crit"], [],
		[_low_fx("bm_i_full_moon_charm", [["crit_rate", ADD, 15]]), "bm_i_tracked"], "+15% crit rate while under 50% HP.")
	_move("bm_i_surgeons_apron", "Surgeon's Apron", "passive", A.LOWEST_ALLY, "mend", [_amount_heal("regen", 10)],
		"Each Bleed tick you cause heals the most hurt ally 10% of the tick.", {"event": Battle.EVENT_DOT_DEALT})
	_bm_piece("surgeons_apron", "Surgeon's Apron", "Body", [T], EPIC, ["Fit.Bleed", "Fit.Dot", "Fit.Healing", "Fit.Survival"], ["bm_i_surgeons_apron"],
		[_stat_fx("bm_i_apron_stats", [["max_hp", ADD, 60], ["bleed_chance", ADD, 5]])],
		"+60 max HP, +5% Bleed chance; each Bleed tick you cause heals the most hurt ally 10% of the tick.")
	_bm_item("crimson_thread", "Crimson Thread", [T], EPIC, ["Fit.Bleed", "Fit.Dot", "Fit.Damage"], [],
		[_stat_fx("bm_i_crimson_thread", [["bleed_chance", ADD, 5], ["bleed_dmg", ADD, 30]])], "+5% Bleed chance; your Bleed deals +30% damage.")
	_move("bm_i_bloodletting_bowl", "Bloodletting Bowl", "passive", A.RANDOM_OTHER_ENEMY, "bm_i_two_bleeds",
		[_put("b1", "bm_bleed"), _put("b2", "bm_bleed")], "On a kill: 2 Bleed stacks on a random other enemy.",
		{"event": &"Event.Unit.Killed"})
	_bm_item("bloodletting_bowl", "Bloodletting Bowl", [T], EPIC, ["Fit.Bleed", "Fit.Dot", "Grants.Dot"], ["bm_i_bloodletting_bowl"], ["bm_i_bleed_5"],
		"+5% Bleed chance; on a kill, 2 Bleed stacks spread to a random other enemy.")
	_move("bm_i_transfusion_kit", "Transfusion Kit", "passive", A.LOWEST_ALLY, "mend", [_amount_heal("regen", 40)],
		"Your heals also heal the most hurt ally 40% as much.", {"event": Battle.EVENT_HEAL_GIVEN, "asset_tags": FOLLOW_UP})
	_bm_item("transfusion_kit", "Transfusion Kit", [T], EPIC, ["Fit.Healing", "Fit.Party"], ["bm_i_transfusion_kit"], [],
		"Your heals also heal the most hurt ally 40% as much.")
	var ward := GameplayEffect.new()
	ward.policy = GameplayEffect.DurationPolicy.INSTANT
	var shield: Resource = load(PERCENT_OF_MAX).new()
	shield.set("attribute", "shield")
	shield.set("percent_x100", Fixed.from_typed(8))
	ward.executions.append(shield)
	ward.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_i_sanguine_ward", ward)
	_move("bm_i_sanguine_ward", "Sanguine Ward", "passive", A.ALL_ALLIES, "rally_horn", [_put("rally", "bm_i_sanguine_ward")],
		"At battle start, every ally gets a shield of 8% of their max HP.")
	_bm_piece("sanguine_ward", "Sanguine Ward", "Head", [T], EPIC, ["Fit.Survival", "Fit.Party"], ["bm_i_sanguine_ward"],
		[_stat_fx("bm_i_ward_hp", [["max_hp", ADD, 40]])], "+40 max HP; at battle start, every ally gets a shield of 8% of their max HP.")
	_bm_item("blood_moon_amulet", "Blood Moon Amulet", [T], EPIC, ["Fit.Damage", "Fit.Survival"], [],
		[_low_fx("bm_i_blood_moon_amulet", [["dmg_mult", ADD, 10], ["heal_taken", ADD, 10]]), "bm_i_tracked"],
		"While under 50% HP: +10% damage dealt and +10% healing received.")
	_fx("bm_i_eclipse", _attack_up(20, 3))
	_move("bm_i_crimson_eclipse", "Crimson Eclipse", "passive", A.SELF, "blood_pact", [_put("price", "bm_i_eclipse")],
		"At battle start, pay 10% of your max HP and gain +20% ATK for 3 turns.", {"cost": _hp_cost(10)})
	_bm_item("crimson_eclipse", "Crimson Eclipse", [T], EPIC, ["Fit.Damage", "Fit.HpCost"], ["bm_i_crimson_eclipse"], [],
		"At battle start, pay 10% of your max HP and gain +20% ATK for 3 turns.")
	_bm_item("lunar_fury", "Lunar Fury", [T], EPIC, ["Fit.FollowUp"], [],
		[_low_fx("bm_i_lunar_fury", [["follow_up_dmg", ADD, 30]]), "bm_i_tracked"], "Your follow-ups deal +30% damage while under 50% HP.")
	_bm_piece("nightcloak", "Nightcloak", "Body", [T], EPIC, ["Fit.Lifesteal", "Fit.Survival"], [],
		[_stat_fx("bm_i_nightcloak", [["max_hp", ADD, 60], ["lifesteal", ADD, 5]]), _low_fx("bm_i_nightcloak_low", [["lifesteal", ADD, 15]]),
		"bm_i_tracked"], "+60 max HP, +5% lifesteal; +15% more lifesteal while under 50% HP.")
	_bm_item("velvet_fangs", "Velvet Fangs", [T], EPIC, ["Fit.Lifesteal", "Fit.Survival"], [],
		[_stat_fx("bm_i_velvet_fangs", [["lifesteal", ADD, 8], ["overheal_shield", ADD, 15]])],
		"+8% lifesteal; lifesteal past full HP becomes a shield, up to 15% of your max HP.")

	# Legendary (9)
	_bm_item("crimson_thirst", "Crimson Thirst", [B], LEGENDARY, ["Fit.Damage"], [],
		[_stat_fx("bm_i_crimson_thirst", [["missing_hp_dmg", ADD, 0.4]])], "+2% damage for every 5% of max HP missing.")
	_fx("bm_i_redmoon_party", _mixed_infinite([["lifesteal", ADD, 10]]))
	_move("bm_i_heart_of_the_red_moon", "Heart of the Red Moon", "passive", A.ALL_ALLIES, "rally_horn",
		[_put("rally", "bm_i_redmoon_party")], "The party: +10% lifesteal.")
	_bm_item("heart_of_the_red_moon", "Heart of the Red Moon", [B], LEGENDARY, ["Fit.Lifesteal", "Fit.Party", "Fit.Survival", "Fit.HpCost"],
		["bm_i_heart_of_the_red_moon"], [_stat_fx("bm_i_redmoon_cost", [["hp_cost", ADD, -20]])],
		"The party: +10% lifesteal; your HP costs are 20% lower.")
	_move("bm_i_twin_blades", "Twin Blades", "passive", A.SELF, "", [], "Your follow-ups hit twice.",
		{"event": Battle.EVENT_ATTACK_FOLLOW_UP, "asset_tags": ECHO, "echo": 100, "subject": an_enemy})
	_bm_item("twin_blades", "Twin Blades", [T], LEGENDARY, ["Fit.FollowUp"], ["bm_i_twin_blades"], [], "Your follow-ups hit twice.")
	_move("bm_i_burst_vein", "Burst Vein", "passive", A.SINGLE_ENEMY, "bm_i_burst",
		[_put("blast", "bm_bleed_detonate"), _put("clear", "bm_bleed_purge")],
		"Your crits on a Bleeding enemy detonate its Bleed.", {"event": &"Event.Damage.Dealt.Critical", "subject": bleeding})
	_move("bm_i_burst_share", "Burst Vein", "passive", A.ALL_ALLIES, "mend", [_amount_heal("regen", 7.5)],
		"A detonation heals every ally 7.5% of its damage (30% shared by a party of four).",
		{"event": &"Event.Damage.Dealt.Detonate"})
	_bm_item("burst_vein", "Burst Vein", [B], LEGENDARY, ["Fit.Bleed", "Fit.Dot", "Fit.Healing", "Fit.FollowUp", "Fit.Party", "Fit.Crit"], ["bm_i_burst_vein", "bm_i_burst_share"],
		["bm_i_bleed_5"], "+5% Bleed chance; your crits on a Bleeding enemy detonate its Bleed (every remaining tick at once); the party heals 30% of that damage.")
	var hemophilia := _timed({"dmg_taken": 15}, 2, [&"Status.Debuff.Hemophilia"])
	hemophilia.application_query = _any_query([], [&"Immune.Hemophilia", &"Immune.Debuff"])
	hemophilia.application_cue_tags.assign(DEBUFF_CUES)
	_fx("bm_i_hemophilia", hemophilia)
	_move("bm_i_hemophilia", "Hemophilia", "passive", A.SINGLE_ENEMY, "siphon_sigil", [_put("charge", "bm_i_hemophilia")],
		"Your hits on a Bleeding enemy: it takes +15% damage from every source for 2 turns.",
		{"event": Battle.EVENT_DAMAGE_DEALT, "subject": bleeding})
	_bm_item("hemophilia", "Hemophilia", [B], LEGENDARY, ["Fit.Bleed", "Fit.Dot", "Fit.Damage"], ["bm_i_hemophilia"], ["bm_i_bleed_5"],
		"+5% Bleed chance; enemies you Bleed take +15% damage from every source.")
	_low_fx("bm_i_accord_low", [["heal_taken", ADD, 20]])
	_move("bm_i_accord_start", "Crimson Accord", "passive", A.ALL_ALLIES, _keyed("rally_horn", "bm_i_accord_start", ["low", "track"]),
		[_put("low", "bm_i_accord_low"), _put("track", "bm_i_tracked")], "Heals on allies under 50% HP are 20% stronger.")
	var rally := _attack_up(15, 2)
	_fx("bm_i_accord_rally", rally)
	_flag("bm_i_accord_used", 1, &"State.AccordUsed")
	_move("bm_i_accord_rally", "Crimson Accord", "passive", A.ALL_ALLIES, _keyed("rally_horn", "bm_i_accord_rally", ["rally", "used"]),
		[_put("rally", "bm_i_accord_rally"), _put("used", "bm_i_accord_used")],
		"Once per turn, a heal that leaves an ally above 50% HP gives the party +15% ATK for 2 turns.",
		{"event": Battle.EVENT_HEAL_GIVEN, "query": _any_query([], [&"State.AccordUsed"]),
		"subject": _any_query([Battle.HEALTH_TRACKED_TAG], [Battle.HEALTH_LOW_TAG])})
	_bm_item("crimson_accord", "Crimson Accord", [B], LEGENDARY, ["Fit.Healing", "Fit.Party", "Fit.Damage", "Fit.Survival"],
		["bm_i_accord_start", "bm_i_accord_rally"], [],
		"Your heals are 20% stronger on allies under 50% HP; once per turn, a heal that leaves an ally above 50% gives the party +15% ATK for 2 turns.")
	_move("bm_i_alphas_mark", "Alpha's Mark", "passive", A.RANDOM_OTHER_ENEMY, "bm_i_strike", [_hit("strike", 50, PHYSICAL, {"tough": 15})],
		"Each follow-up has a 30% chance to also strike a second random enemy.",
		{"event": Battle.EVENT_ATTACK_FOLLOW_UP, "chance": 30, "asset_tags": STRIKE_TAG})
	_bm_item("alphas_mark", "Alpha's Mark", [B], LEGENDARY, ["Fit.FollowUp", "Grants.FollowUp", "Fit.Break"], ["bm_i_alphas_mark"],
		[_stat_fx("bm_i_alphas_mark", [["follow_up_dmg", ADD, 25]])],
		"Your follow-ups +25% damage; each follow-up has a 30% chance to also strike a second random enemy (50% ATK).")
	var rise := _instant({"hp": 1})
	_fx("bm_i_embrace_rise", rise)
	var mend := _percent_dot(15, 2, [&"Status.Buff.Regen"])
	mend.periodic_cue_tags.assign(HEAL_CUES)
	_fx("bm_i_embrace_mend", mend)
	_fx("bm_i_embrace_thirst", _timed({"lifesteal": 2}, 2, [&"Status.Buff.Lifesteal"], GameplayEffectModifier.Operation.MULTIPLY))
	var saved := GameplayEffect.new()
	saved.policy = GameplayEffect.DurationPolicy.INFINITE
	saved.granted_tags.assign([&"State.EmbraceSaved"])
	_fx("bm_i_embrace_saved", saved)
	_move("bm_i_nights_embrace", "Night's Embrace", "passive", A.SELF,
		_keyed("blood_pact", "bm_i_nights_embrace", ["rise", "mend", "thirst", "saved"]),
		[_put("rise", "bm_i_embrace_rise"), _put("mend", "bm_i_embrace_mend"), _put("thirst", "bm_i_embrace_thirst"),
		_put("saved", "bm_i_embrace_saved")],
		"Once per battle, when you would die: survive at 1 HP, heal 30% of max HP over 2 turns and double your lifesteal for 2 turns.",
		{"event": &"Event.Unit.Dying", "query": _any_query([], [&"State.EmbraceSaved"])})
	_bm_item("nights_embrace", "Night's Embrace", [B], LEGENDARY, ["Fit.Lifesteal", "Fit.Survival"], ["bm_i_nights_embrace"],
		[_stat_fx("bm_i_nights_embrace", [["lifesteal", ADD, 10]])],
		"+10% lifesteal; once per battle, when you would die, survive at 1 HP, heal 30% of max HP over 2 turns and double your lifesteal for those 2 turns.")
	_move("bm_i_stake_silver", "Stake of Dawn", "passive", A.SINGLE_ENEMY, "siphon_sigil", [_put("charge", "bm_silvered")],
		"Your crits have a 50% chance to Silver the target.", {"event": &"Event.Damage.Dealt.Critical", "chance": 50})
	_flag("bm_i_crit_mark", 1, &"State.CritLanded")
	_move("bm_i_stake_mark", "Stake of Dawn", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_i_crit_mark")], "A crit this turn.",
		{"event": &"Event.Damage.Dealt.Critical"})
	var grant := _timed({}, 1, [Battle.ONE_MORE_GRANT_TAG])
	grant.application_query = _any_query([], [Battle.ONE_MORE_GRANT_TAG])  # once per turn
	_fx("bm_i_one_more", grant)
	_move("bm_i_stake_one_more", "Stake of Dawn", "passive", A.SELF, "siphon_sigil", [_put("charge", "bm_i_one_more")],
		"A crit that kills gives a One More (once per turn).",
		{"event": &"Event.Unit.Killed", "query": _any_query([&"State.CritLanded"])})
	_bm_item("stake_of_dawn", "Stake of Dawn", [B], LEGENDARY, ["Fit.Damage", "Fit.Crit"], ["bm_i_stake_silver", "bm_i_stake_mark",
		"bm_i_stake_one_more"], [_stat_fx("bm_i_stake_of_dawn", [["silvered_crit_dmg", ADD, 60]])],
		"Your crits have a 50% chance to Silver the target; +60% crit damage against Silvered targets; a crit that kills gives a One More (once per turn).")


# --- Step 5: level rows (level-cap 2.3 rhythm: passives at 3 and 7, the innate skill's ranks at 5 and 9, then to 50) -------

## A tag segment without this pass's file prefix (bm_blood_lance_2 -> Bloodlance2), like the other classes' tags.
func _dashboard(name: String) -> String:
	return super(name.trim_prefix("bm_"))


## The level rows of `name` (filled by _add while _class is that name), as LevelSkill resources.
func _level_skills(name: String) -> Array:
	var skills: Array = []
	for row in _rows.get(name, []):
		var skill := LevelSkill.new()
		skill.level = row["level"]
		skill.ability = load(CONTENT + "abilities/%s.tscn" % row["name"])
		skill.replaces = row["replaces"]
		skills.append(skill)
	return skills


## A new HP-cost action skill (B1): `percent`% of max HP, its Ability.Role.* tags read from its rows, plus `types`
## (Ability.Type.* tags: a passive can answer exactly this skill on Event.Ability.Used.<Type>).
func _hp_active(level: int, name: String, title: String, targeting: int, animation: String, percent: float, rows: Array,
		text: String, types: Array = []) -> void:
	var ability := BattleAbility.new()
	ability.targeting = targeting
	ability.executions.assign(rows)
	ability.animation = _animation(animation)
	ability.ability_tag = StringName("Ability." + _dashboard(name))
	ability.cost_effect = _hp_cost(percent)
	ability.asset_tags.assign(RolePass.roles_of(ability) + [&"Ability.Usage.Battle"] + types)
	_add(level, name, title, ability, text, "active (%s%% HP)" % str(percent), &"")


## A new SP action skill with Ability.Type.* `types`.
func _sp_active(level: int, name: String, title: String, targeting: int, animation: String, cost: int, rows: Array,
		text: String, types: Array = []) -> void:
	var ability := BattleAbility.new()
	ability.targeting = targeting
	ability.executions.assign(rows)
	ability.animation = _animation(animation)
	ability.ability_tag = StringName("Ability." + _dashboard(name))
	ability.cost_effect = _cost(cost)
	ability.asset_tags.assign(RolePass.roles_of(ability) + [&"Ability.Usage.Battle"] + types)
	_add(level, name, title, ability, text, "active (%d SP)" % cost, &"")


## A passive that replaces `base` (another targeting or trigger than a rank allows).
func _passive_over(level: int, name: String, title: String, base: String, targeting: int, animation: String, rows: Array,
		event: StringName, text: String) -> void:
	var ability := BattleAbility.new()
	ability.targeting = targeting
	ability.executions.assign(rows)
	ability.animation = _animation(animation)
	ability.ability_tag = StringName("Ability.Passive." + _dashboard(name))
	ability.trigger_event_tag = event
	_add(level, name, title, ability, text, "passive", _tag_of(base))


func _start_fx(name: String, changes: Array) -> String:
	_fx(name, _mixed_infinite(changes))
	return name


func _vlad_levels() -> void:
	_class = "vampire"
	var A := BattleAbility.Targeting
	_trigger(3, "bm_dark_hunger", "Dark Hunger", A.SELF, "siphon_sigil",
		[_put("charge", _start_fx("bm_dark_hunger", [["lifesteal", ADD, 10]]))], Battle.EVENT_BATTLE_START, "+10% lifesteal.")
	_rank(5, "bm_blood_lance_2", "Blood Lance II", "bm_blood_lance", {"execute": {"percent": 260}}, 0,
		"Costs 12% max HP. 260% ATK Physical to one enemy.")
	_trigger(7, "bm_nocturne", "Nocturne", A.SELF, "siphon_sigil",
		[_put("charge", _low_fx("bm_nocturne", [["atk", PERCENT, 15]]))], Battle.EVENT_BATTLE_START, "+15% ATK while under 50% HP.")
	_rank(9, "bm_blood_lance_3", "Blood Lance III", "bm_blood_lance_2", {"execute": {"percent": 300}}, 0,
		"Costs 12% max HP. 300% ATK Physical to one enemy.")
	var thirst := _timed({"bleed_chance": 100}, 3, [&"Status.Buff.Hemorrhage"])
	thirst.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_hemorrhage", thirst)
	_hp_active(12, "bm_hemorrhage", "Hemorrhage", A.SELF, _keyed("rally_horn", "bm_hemorrhage", ["price"]), 10,
		[_put("price", "bm_hemorrhage")],
		"Costs 10% max HP. For 3 turns, every hit Bleeds.")
	_rank(15, "bm_night_feast_2", "Night Feast II", "bm_night_feast", {"crush": {"percent": 360}, "quake": {"percent": 120}}, 0,
		"360% ATK Physical to one enemy and 120% to its neighbours.")
	_heal_fx("bm_blood_frenzy", 12)
	_trigger(20, "bm_blood_frenzy", "Blood Frenzy", A.SELF, "siphon_sigil", [_put("charge", "bm_blood_frenzy")],
		&"Event.Unit.Killed", "On a kill: heal 12% of max HP (the HP its last skill cost).")
	_rank(25, "bm_crimson_sweep_2", "Crimson Sweep II", "bm_crimson_sweep", {"cleave": {"percent": 150}}, 0,
		"Costs 18% max HP. 150% ATK Physical to every enemy.")
	_heal_fx("bm_tide_heal", 10)
	_hp_active(30, "bm_sanguine_tide", "Sanguine Tide", A.ALL_ENEMIES, _keyed("cleave", "bm_sanguine_tide", ["tide"]), 20,
		[_hit("tide", 180, PHYSICAL, {"tough": 45})], "Costs 20% max HP. 180% ATK Physical to every enemy; the party heals 10% of max HP.",
		[&"Ability.Type.Tide"])
	_trigger(30, "bm_tide_after", "Sanguine Tide", A.ALL_ALLIES, "mend", [_put("regen", "bm_tide_heal")], &"Event.Ability.Used.Tide",
		"After Sanguine Tide: the party heals 10% of max HP.")
	_fx("bm_thirst_2", _infinite({"missing_hp_dmg": 0.6}, false))
	_rank(35, "bm_thirst_2", "Thirst II", "bm_thirst", {"price": {"effect": "bm_thirst_2"}}, 0,
		"+0.6% damage for every 1% of max HP missing.")
	var hunger := _mixed_infinite([["lifesteal", GameplayEffectModifier.Operation.MULTIPLY, 2]])
	hunger.ongoing_suppression_query = _any_query([], [Battle.HEALTH_CRITICAL_TAG])
	_fx("bm_undying_hunger", hunger)
	_trigger(40, "bm_undying_hunger", "Undying Hunger", A.SELF, "siphon_sigil", [_put("charge", "bm_undying_hunger")],
		Battle.EVENT_BATTLE_START, "Below 25% HP, lifesteal doubles.")
	_rank(45, "bm_sanguine_tide_2", "Sanguine Tide II", "bm_sanguine_tide", {"tide": {"percent": 220}}, 0,
		"Costs 20% max HP. 220% ATK Physical to every enemy; the party heals 10% of max HP.")
	_rank(50, "bm_night_feast_3", "Night Feast III", "bm_night_feast_2", {"crush": {"percent": 420}, "quake": {"percent": 140}}, 0,
		"420% ATK Physical to one enemy and 140% to its neighbours.")


func _bloodbinder_levels() -> void:
	_class = "bloodbinder"
	var A := BattleAbility.Targeting
	_trigger(3, "bm_thick_blood", "Thick Blood", A.SELF, "siphon_sigil",
		[_put("charge", _start_fx("bm_thick_blood", [["max_hp", PERCENT, 10]]))], Battle.EVENT_BATTLE_START, "+10% max HP.")
	_fx("bm_transfusion_heal_2", _heal_of(31))
	_rank(5, "bm_transfusion_2", "Transfusion II", "bm_transfusion", {"heal": {"effect": "bm_transfusion_heal_2"}}, 0,
		"Costs 10% max HP. One ally heals 31% of their max HP.")
	_trigger(7, "bm_shared_vein", "Shared Vein", A.LOWEST_ALLY, "mend", [_amount_heal("regen", 50)], Battle.EVENT_COST_HP,
		"Each HP cost it pays also heals the most hurt ally 50% of the cost.")
	_fx("bm_transfusion_heal_3", _heal_of(37))
	_rank(9, "bm_transfusion_3", "Transfusion III", "bm_transfusion_2", {"heal": {"effect": "bm_transfusion_heal_3"}}, 0,
		"Costs 10% max HP. One ally heals 37% of their max HP.")
	var coagulate := GameplayEffect.new()
	coagulate.policy = GameplayEffect.DurationPolicy.INSTANT
	var shield: Resource = load(PERCENT_OF_MAX).new()
	shield.set("attribute", "shield")
	shield.set("percent_x100", Fixed.from_typed(20))
	coagulate.executions.append(shield)
	coagulate.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_coagulate", coagulate)
	_hp_active(12, "bm_coagulate", "Coagulate", A.SINGLE_ALLY, "bless", 12, [_put("ward", "bm_coagulate")],
		"Costs 12% max HP. One ally gets a shield of 20% of their max HP.", [&"Ability.Role.Buff"])
	_fx("bm_communion_heal_2", _heal_of(26))
	_communion_rank(15, "bm_crimson_communion_2", "Crimson Communion II", "bm_communion_heal_2", 26)
	_fx("bm_deep_pool", _infinite({"energy_regen": 25}, false))
	_trigger(20, "bm_deep_pool", "Deep Pool", A.SELF, "siphon_sigil", [_put("charge", "bm_deep_pool")], Battle.EVENT_BATTLE_START,
		"The ult bar fills 25% faster.")
	var rite := _add_buff({"lifesteal": 12}, 3, [LIFESTEAL_TAG])
	rite.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_blood_rite_2", rite)
	_rank(25, "bm_blood_rite_2", "Blood Rite II", "bm_blood_rite", {"rally": {"effect": "bm_blood_rite_2"}}, 0,
		"Costs 15% max HP. The party: +12% lifesteal for 3 turns.")
	_heal_fx("bm_red_tide_heal", 12)
	_hp_active(30, "bm_red_tide", "Red Tide", A.ALL_ENEMIES, _keyed("cleave", "bm_red_tide", ["tide"]), 15,
		[_hit("tide", 140, PHYSICAL, {"tough": 30})], "Costs 15% max HP. 140% ATK Physical to every enemy; the party heals 12% of max HP.",
		[&"Ability.Type.RedTide"])
	_trigger(30, "bm_red_tide_after", "Red Tide", A.ALL_ALLIES, "mend", [_put("regen", "bm_red_tide_heal")],
		&"Event.Ability.Used.RedTide", "After Red Tide: the party heals 12% of max HP.")
	_fx("bm_deep_pool_2", _infinite({"energy_regen": 50}, false))
	_rank(35, "bm_deep_pool_2", "Deep Pool II", "bm_deep_pool", {"charge": {"effect": "bm_deep_pool_2"}}, 0, "The ult bar fills 50% faster.")
	var drop := GameplayEffect.new()
	drop.policy = GameplayEffect.DurationPolicy.INSTANT
	var drop_shield: Resource = load(PERCENT_OF_MAX).new()
	drop_shield.set("attribute", "shield")
	drop_shield.set("percent_x100", Fixed.from_typed(25))
	drop.executions.append(drop_shield)
	_fx("bm_last_drop_shield", drop)
	_flag("bm_last_drop_used", 99, &"State.LastDropUsed")
	_trigger(40, "bm_last_drop", "Last Drop", A.SINGLE_ALLY, _keyed("bless", "bm_last_drop", ["ward", "used"]),
		[_put("ward", "bm_last_drop_shield"), _put("used", "bm_last_drop_used")], &"Event.Ally.Health.Low",
		"Once per battle, when an ally drops under 50% HP: they get a shield of 25% of their max HP.",
		{"query": _any_query([], [&"State.LastDropUsed"])})
	_rank(45, "bm_red_tide_2", "Red Tide II", "bm_red_tide", {"tide": {"percent": 180}}, 0,
		"Costs 15% max HP. 180% ATK Physical to every enemy; the party heals 12% of max HP.")
	_fx("bm_communion_heal_3", _heal_of(32))
	_communion_rank(50, "bm_crimson_communion_3", "Crimson Communion III", "bm_communion_heal_3", 32)


func _hunter_levels() -> void:
	_class = "vampire_hunter"
	var A := BattleAbility.Targeting
	_trigger(3, "bm_keen_senses", "Keen Senses", A.SELF, "siphon_sigil",
		[_put("charge", _start_fx("bm_keen_senses", [["silvered_crit_dmg", ADD, 20]]))], Battle.EVENT_BATTLE_START,
		"Crits on a Silvered target +20% crit damage.")
	_rank(5, "bm_holy_water_2", "Holy Water II", "bm_holy_water", {"flask": {"percent": 110}, "splash": {"percent": 55}}, 43,
		"110% ATK Fire to one enemy and 55% to its neighbours.")
	_trigger(7, "bm_patient_hunter", "Patient Hunter", A.SELF, _keyed("siphon_sigil", "bm_patient_hunter", ["f1", "f2"]),
		[_put("f1", "bm_focus"), _put("f2", "bm_focus")], Battle.EVENT_BATTLE_START, "Start every battle with 2 Focus.")
	_rank(9, "bm_holy_water_3", "Holy Water III", "bm_holy_water_2", {"flask": {"percent": 130}, "splash": {"percent": 65}}, 43,
		"130% ATK Fire to one enemy and 65% to its neighbours.")
	_sp_active(12, "bm_chain_shot", "Chain Shot", A.SINGLE_ENEMY, _keyed("quick_shot", "bm_chain_shot", ["s1", "s2", "s3"]), 53,
		[_hit("s1", 60, PHYSICAL, {"tough": 20}), _hit("s2", 60, PHYSICAL, {"tough": 20}), _hit("s3", 60, PHYSICAL, {"tough": 20})],
		"3 hits of 60% ATK Physical on one enemy; each builds or spends Focus.")
	_rank(15, "bm_dawnbreak_2", "Dawnbreak II", "bm_dawnbreak", {"crush": {"percent": 380}}, 0, "380% ATK Physical to one enemy, always a crit.")
	_trigger(20, "bm_relentless", "Relentless", A.SELF, "siphon_sigil", [_put("charge", "bm_focus")], &"Event.Damage.Dealt.Critical",
		"A crit keeps 1 Focus.")
	_rank(25, "bm_stake_2", "Stake II", "bm_stake", {"execute": {"percent": 260}}, 53, "260% ATK Physical to one enemy, with +25% crit rate.")
	_sp_active(30, "bm_purge_the_night", "Purge the Night", A.ALL_ENEMIES, _keyed("fire_bolt", "bm_purge_the_night", ["burn", "silver"]),
		63, [_hit("burn", 150, FIRE, {"tough": 45}), _put("silver", "bm_silvered")], "150% ATK Fire to every enemy; Silvers them all.")
	_rank(35, "bm_keen_senses_2", "Keen Senses II", "bm_keen_senses",
		{"charge": {"effect": _start_fx("bm_keen_senses_2", [["silvered_crit_dmg", ADD, 40]])}}, 0,
		"Crits on a Silvered target +40% crit damage.")
	_trigger(40, "bm_verdict_mark", "Final Verdict", A.SELF, "siphon_sigil", [_put("charge", "bm_i_crit_mark")],
		&"Event.Damage.Dealt.Critical", "A crit this turn.")
	_trigger(40, "bm_final_verdict", "Final Verdict", A.SELF, "siphon_sigil", [_on("charge", "gravity_pull", {"delay": -25})],
		&"Event.Unit.Killed", "A kill by a crit advances its next action by 25%.", {"query": _query([&"State.CritLanded"])})
	_rank(45, "bm_purge_the_night_2", "Purge the Night II", "bm_purge_the_night", {"burn": {"percent": 190}}, 63,
		"190% ATK Fire to every enemy; Silvers them all.")
	_rank(50, "bm_dawnbreak_3", "Dawnbreak III", "bm_dawnbreak_2", {"crush": {"percent": 440}}, 0, "440% ATK Physical to one enemy, always a crit.")


func _werewolf_levels() -> void:
	_class = "werewolf"
	var A := BattleAbility.Targeting
	_trigger(3, "bm_thick_hide", "Thick Hide", A.SELF, "siphon_sigil",
		[_put("charge", _start_fx("bm_thick_hide", [["def", PERCENT, 15]]))], Battle.EVENT_BATTLE_START, "+15% DEF.")
	_rank(5, "bm_pounce_2", "Pounce II", "bm_pounce", {"bite": {"percent": 210}}, 43, "210% ATK Physical to one enemy.")
	_trigger(7, "bm_pack_instinct", "Pack Instinct", A.SELF, "siphon_sigil",
		[_put("charge", _start_fx("bm_pack_instinct", [["broken_dmg", ADD, 15]]))], Battle.EVENT_BATTLE_START,
		"+15% damage against Broken enemies.")
	_rank(9, "bm_pounce_3", "Pounce III", "bm_pounce_2", {"bite": {"percent": 240}}, 43, "240% ATK Physical to one enemy.")
	_sp_active(12, "bm_savage_maul", "Savage Maul", A.BLAST_ENEMY, _keyed("cleave", "bm_savage_maul", ["maul", "splash"]), 53,
		[_hit("maul", 150, PHYSICAL, {"tough": 90, "on": ExecutionRow.Targets.PRIMARY}),
		_hit("splash", 60, PHYSICAL, {"tough": 45, "on": ExecutionRow.Targets.ADJACENT})],
		"150% ATK Physical to one enemy and 60% to its neighbours, heavy toughness damage.")
	var claws_2 := {}
	for index in 5:
		claws_2["c%d" % (index + 1)] = {"percent": 60}
	_rank(15, "bm_moonfall_frenzy_2", "Moonfall Frenzy II", "bm_moonfall_frenzy", claws_2, 0,
		"5 claws of 60% ATK Physical at random enemies; then Wolf Form for 2 turns.")
	_trigger(20, "bm_blood_moon_hunger", "Blood Moon Hunger", A.SELF, "siphon_sigil",
		[_put("charge", _start_fx("bm_blood_moon_hunger", [["health_low_at", GameplayEffectModifier.Operation.OVERRIDE, 60]]))],
		Battle.EVENT_BATTLE_START, "Wolf Form under 60% HP instead of 50%.")
	var howl := _timed({"atk": 20}, 2, [&"Status.Buff.AttackUp"], GameplayEffectModifier.Operation.PERCENT_ADD)
	howl.application_cue_tags.assign(BUFF_CUES)
	_fx("bm_howl_2", howl)
	_rank(25, "bm_howl_2", "Howl II", "bm_howl", {"rally": {"effect": "bm_howl_2"}}, 53, "Wolf Form for 2 turns; the party +20% ATK for 2 turns.")
	var keys: Array = []
	var rampage: Array = []
	for index in 8:
		keys.append("c%d" % (index + 1))
		rampage.append(_hit("c%d" % (index + 1), 40, PHYSICAL, {"tough": 20, "on": ExecutionRow.Targets.RANDOM}))
	_sp_active(30, "bm_lunar_rampage", "Lunar Rampage", A.ALL_ENEMIES, _keyed("cleave", "bm_lunar_rampage", keys), 63, rampage,
		"8 claws of 40% ATK Physical at random enemies.")
	_trigger(35, "bm_alpha", "Alpha", A.SELF, "", [], Battle.EVENT_ATTACK_FOLLOW_UP, "In Wolf Form, its follow-ups hit twice.",
		{"asset_tags": ECHO, "echo_scale": 100, "query": _any_query([&"State.WolfForm", &"Status.WolfForm"])})
	var eternal := _mixed_infinite([["lifesteal", ADD, 10]])
	eternal.granted_tags.assign([&"State.WolfForm"])
	eternal.ongoing_suppression_query = _any_query([Battle.HEALTH_LOW_TAG])  # the low-HP form gives its own lifesteal then
	_fx("bm_eternal_moon", eternal)
	_trigger(40, "bm_eternal_moon", "Eternal Moon", A.SELF, "siphon_sigil", [_put("charge", "bm_eternal_moon")],
		Battle.EVENT_BATTLE_START, "Always in Wolf Form, whatever its HP.")
	var rampage_2 := {}
	for key in keys:
		rampage_2[key] = {"percent": 50}
	_rank(45, "bm_lunar_rampage_2", "Lunar Rampage II", "bm_lunar_rampage", rampage_2, 63, "8 claws of 50% ATK Physical at random enemies.")
	var claws_3 := {}
	for index in 5:
		claws_3["c%d" % (index + 1)] = {"percent": 70}
	_rank(50, "bm_moonfall_frenzy_3", "Moonfall Frenzy III", "bm_moonfall_frenzy_2", claws_3, 0,
		"5 claws of 70% ATK Physical at random enemies; then Wolf Form for 2 turns.")


func _bloodletter_levels() -> void:
	_class = "bloodletter"
	var A := BattleAbility.Targeting
	_trigger(3, "bm_deep_cuts", "Deep Cuts", A.SELF, "siphon_sigil",
		[_put("charge", _start_fx("bm_deep_cuts", [["bleed_stacks", ADD, 2]]))], Battle.EVENT_BATTLE_START,
		"Its Bleed holds 2 more stacks.")
	_rank(5, "bm_open_vein_2", "Open Vein II", "bm_open_vein", {"cut": {"percent": 80}}, 43,
		"80% ATK Physical and 3 Bleed stacks (3 turns) on one enemy.")
	_trigger(7, "bm_clotting", "Clotting", A.ALL_ALLIES, "rally_horn",
		[_put("rally", _start_fx("bm_clotting", [["heal_taken", ADD, 10]]))], Battle.EVENT_BATTLE_START, "The party: +10% healing received.")
	_rank(9, "bm_open_vein_3", "Open Vein III", "bm_open_vein_2", {"cut": {"percent": 100}}, 43,
		"100% ATK Physical and 3 Bleed stacks (3 turns) on one enemy.")
	_sp_active(12, "bm_bloodmist", "Bloodmist", A.ALL_ENEMIES, _keyed("bleeding_out", "bm_bloodmist", ["mist"]), 53,
		[_put("mist", "bm_bleed")], "1 Bleed stack on every enemy; every ally is cleansed.", [&"Ability.Type.Bloodmist"])
	_trigger(12, "bm_bloodmist_after", "Bloodmist", A.ALL_ALLIES, _keyed("purify", "bm_bloodmist_after", ["cleanse"]),
		[_put("cleanse", "cleanse")], &"Event.Ability.Used.Bloodmist", "After Bloodmist: every ally is cleansed.")
	_rank(15, "bm_crimson_letting_2", "Crimson Letting II", "bm_crimson_letting",
		{"l1": {"effect": _bleed_for(3)}, "l2": {"effect": _bleed_for(3)}}, 0,
		"2 Bleed stacks (3 turns) on every enemy; for 2 turns, the party's hits on a Bleeding enemy heal them 15% of the damage.")
	_trigger(20, "bm_exsanguinate", "Exsanguinate", A.RANDOM_OTHER_ENEMY, "siphon_sigil", [_put("charge", "bm_bleed")],
		Battle.EVENT_DOT_DEALT, "A tick of its Bleed has a 30% chance to spread one stack to another enemy.", {"trigger_chance": 30})
	var stronger := GameplayEffect.new()
	stronger.policy = GameplayEffect.DurationPolicy.INSTANT
	var calc: Resource = load(DETONATE_CALC).new()
	calc.set("share_x100", Fixed.from_typed(140))
	stronger.executions.append(calc)
	_fx("bm_bleed_detonate_2", stronger)
	_rank(25, "bm_siphon_2", "Siphon II", "bm_siphon", {"blast": {"effect": "bm_bleed_detonate_2"}}, 53,
		"Detonates every Bleed stack on one enemy at 140%; the party heals 50% of that damage, shared.")
	_sp_active(30, "bm_red_river", "Red River", A.ALL_ENEMIES, "bm_siphon", 63,
		[_put("blast", "bm_bleed_detonate"), _put("clear", "bm_bleed_purge")],
		"Detonates the Bleed on every enemy; the party heals from every detonation.")
	_rank(35, "bm_clotting_2", "Clotting II", "bm_clotting", {"rally": {"effect": _start_fx("bm_clotting_2", [["heal_taken", ADD, 20]])}},
		0, "The party: +20% healing received.")
	_passive_over(40, "bm_lifeblood", "Lifeblood", "bm_leeching_wounds", A.ALL_ALLIES, "mend", [_amount_heal("regen", 15)],
		Battle.EVENT_DOT_DEALT, "Each tick of a Bleed it applied heals the whole party 15% of the tick.")
	_rank(45, "bm_red_river_2", "Red River II", "bm_red_river", {"blast": {"effect": "bm_bleed_detonate_2"}}, 63,
		"Detonates the Bleed on every enemy at 140%; the party heals from every detonation.")
	_rank(50, "bm_crimson_letting_3", "Crimson Letting III", "bm_crimson_letting_2",
		{"l1": {"effect": _bleed_for(4)}, "l2": {"effect": _bleed_for(4)}}, 0,
		"2 Bleed stacks (4 turns) on every enemy; for 2 turns, the party's hits on a Bleeding enemy heal them 15% of the damage.")


## A rank of Crimson Communion (a meter ult on the ult charge, D29): the level pass's _rank keeps no meter fields.
func _communion_rank(level: int, name: String, title: String, heal: String, percent: int) -> void:
	var ability := BattleAbility.new()
	ability.targeting = BattleAbility.Targeting.ALL_ALLIES
	ability.animation = _animation("bm_crimson_communion")
	ability.executions.assign([_put("bless", heal), _put("cleanse", "cleanse"), _put("rite", "bm_communion_lifesteal")])
	ability.ability_tag = StringName("Ability.Ult." + _dashboard(name))
	ability.activation_query = load(CONTENT + "queries/not_controlled.tres")
	ability.meter_attribute = "energy"
	ability.meter_threshold_of = "max_energy"
	ability.meter_threshold_percent_x100 = Fixed.from_typed(100)
	ability.asset_tags.assign(RolePass.roles_of(ability))
	_add(level, name, title, ability, "Casts itself when the ult bar is full: every ally heals %d%% of their max HP, is cleansed and gets +10%% lifesteal for 2 turns." % percent,
		"ult (auto)", _tag_of("bm_crimson_communion" if level < 50 else "bm_crimson_communion_2"))
