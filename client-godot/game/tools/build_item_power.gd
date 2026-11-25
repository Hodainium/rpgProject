## Builder for spec item-power 2.3: the 40 new items and gear (10 Legendary, 6 Void trades, 8 Epic, 8 Rare, 4 weapons, 4
## armor) and the Philosopher's Gold the Philosopher's Coin gives, with their abilities and effects, written into
## res://content/demo/ through ResourceSaver like the other content builders, whose helpers it reuses.
##
## It writes only this pass's own new files and never overwrites one that exists (they are the user's to tune). Every move reuses an existing animation (its `execute` keys name the rows, its sound comes
## with it). Values are the spec's first proposals, typed as a designer would; tune them in the files.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_item_power.tscn
## It prints each file, then each pool's rarity counts and the Treasure / Boss overlap before and after.
extends "res://game/tools/build_full_descent.gd"

const CORE_SET := &"Card.Set.Core"
const DESCENT_SET := &"Card.Set.Descent"
const T := &"Pool.Treasure"
const S := &"Pool.Shop"
const B := &"Pool.Boss"
const C := &"Pool.Chest"
const STRIKE := [&"Ability.Type.Strike"]
const EVENT_AMOUNT_CALC: String = CONTENT + "exec_calcs/exec_calc_event_amount.gd"
const FINISH: String = CONTENT + "exec_calcs/exec_calc_finish.gd"
const PHYSICAL := [&"Damage.Type.Physical"]
const HEAL_CUES: Array[StringName] = [&"Cue.Fx.Heal", &"Cue.Sfx.Heal"]
const BUFF_CUES: Array[StringName] = [&"Cue.Fx.Apply.Buff", &"Cue.Sfx.Apply.Buff"]



func _ready() -> void:
	for script in [PERCENT_OF_MAX, EVENT_AMOUNT_CALC, FINISH]:
		if load(script) == null:
			_quit("Missing %s (run --import once first)." % script)
			return
	for name in ["damage", "poison", "burn", "taunt", "gravity_pull"]:
		_r["effects/" + name] = load(CONTENT + "effects/%s.tres" % name)
	for name in ["toxic_echo", "executioners_seal", "duelists_band", "heartstring", "corrupted_coil", "corrupted_oath", "censer",
			"halo", "corrupted_vampire", "mimic_tooth", "momentum_charm", "thorn_mail"]:
		_r["animations/" + name] = load(CONTENT + "animations/%s.tres" % name)
	for key in _r:
		if _r[key] == null:
			_quit("Missing %s%s" % [CONTENT, key])
			return
	var before := _pool_counts()
	_legendaries()
	_void_trades()
	_epics()
	_rares()
	_gear()
	print("build_item_power: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _made:
		print("  made    ", path)
	for path in _skipped:
		print("  skipped ", path)
	for path in _failed:
		print("  FAILED  ", path)
	_print_pools("before", before)
	_print_pools("after", _pool_counts())
	get_tree().quit(1 if not _failed.is_empty() else 0)


# --- Small builders ------------------------------------------------------------------------------------------------------

func _save(key: String, resource: Resource) -> Resource:
	var path := CONTENT + key + ".tres"
	if not _exists(path):
		_write(path, resource)
	_r[key] = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	return _r[key]


## A new passive on an existing animation. rows: [[row id, effect name, mode, typed, damage tags], ...] or ExecutionRows;
## the row ids are the animation's execute keys.
func _proc(name: String, title: String, targeting: int, rows: Array, animation: String, trigger: StringName,
		description: String, extras: Dictionary = {}) -> void:
	var path := CONTENT + "abilities/%s.tscn" % name
	if not _exists(path):
		var ability := BattleAbility.new()
		ability.name = name.to_pascal_case()
		ability.ability_name = title
		ability.ability_tag = StringName("Ability.Passive." + name.to_pascal_case())
		ability.targeting = targeting
		var typed_rows: Array[ExecutionRow] = []
		for row in rows:
			typed_rows.append(row if row is ExecutionRow
				else _row(row[0], row[1], row[2], row[3], ExecutionRow.Targets.ALL, row[4] if row.size() > 4 else []))
		ability.executions = typed_rows
		ability.animation = _r["animations/" + animation] if animation != "" else null
		ability.trigger_event_tag = trigger
		ability.asset_tags.assign(extras.get("asset_tags", []))
		ability.activation_query = extras.get("query")
		ability.cost_effect = _r["effects/" + extras["cost"]] if extras.has("cost") else null
		ability.trigger_chance_x100 = Fixed.from_typed(extras.get("trigger_chance", 0))
		ability.echo_scale_x100 = Fixed.from_typed(extras.get("echo_scale", 0))
		ability.description = description
		_pack(path, ability)
	_r["abilities/" + name] = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)


## A follow-up: `percent`% ATK Physical.
func _follow_up(name: String, title: String, targeting: int, percent: float, animation: String, trigger: StringName,
		description: String, extras: Dictionary = {}) -> void:
	_proc(name, title, targeting, [[_row_of(animation), "damage", ExecutionRow.DamageMode.SCALED, percent, PHYSICAL]], animation,
		trigger, description, {"asset_tags": FOLLOW_UP}.merged(extras, true))


## The first execute key of an existing animation.
func _row_of(animation: String) -> String:
	return String(ExecutionReader.sequence_for(_r["animations/" + animation])[0])


func _one(effect: String, animation: String) -> ExecutionRow:
	return _row(_row_of(animation), effect, ExecutionRow.DamageMode.USE_EFFECT, 0, ExecutionRow.Targets.ALL)


func _advance(percent: float) -> ExecutionRow:
	var row := _one("gravity_pull", "momentum_charm")  # gravity_pull is a bare effect: only the row's delay does something
	row.delay_x100 = Fixed.from_typed(-percent)
	return row


func _heal(typed: float, from_holder: bool = true) -> GameplayEffect:
	var effect := _percent_of_max(typed)
	effect.executions[0].set("target_bonus", "heal_taken")
	if from_holder:
		effect.executions[0].set("source_bonus", "heal_mult")
	effect.application_cue_tags.assign(HEAL_CUES)
	return effect


func _attack_up(percent: float, turns: int, stacks: int = 0) -> GameplayEffect:
	var effect := _buff({"atk": percent}, turns, [&"Status.Buff.AttackUp"])
	effect.persistent_cue_tags.assign([&"Cue.Fx.Buff.AttackUp"])
	effect.application_cue_tags.assign(BUFF_CUES)
	return _refresh(effect, stacks) if stacks > 0 else effect


## An item of this pass: `tags` are its pools, then rarity, set and fit / grant tags. Price by rarity (7 / 9 / 12; Void 0).
func _power(name: String, title: String, pools: Array, rarity: StringName, card_set: StringName, fits: Array,
		abilities: Array, effects: Array, description: String, extra: Dictionary = {}) -> void:
	var tags: Array = pools + [rarity, card_set]
	for fit in fits:
		tags.append(StringName("Item." + fit))
	_described(name, title, tags, _price(pools, rarity), _ability_set(abilities, effects) if not (abilities + effects).is_empty() else null,
		description, extra)


func _piece_of(name: String, title: String, slot: String, rarity: StringName, card_set: StringName, fits: Array,
		abilities: Array, effects: Array, description: String) -> void:
	var tags: Array = [T, S, C, rarity, card_set]
	for fit in fits:
		tags.append(StringName("Item." + fit))
	_piece(name, title, slot, tags, _price([], rarity), _ability_set(abilities, effects), description)


func _price(pools: Array, rarity: StringName) -> int:
	if pools.has(VOID_POOL):
		return 0
	return {RARE: 7, EPIC: 9, LEGENDARY: 12}[rarity]


# --- Legendaries (10) ----------------------------------------------------------------------------------------------------

func _legendaries() -> void:
	var D := ExecutionRow.DamageMode
	var A := BattleAbility.Targeting
	var party := {"applies_to": ItemDefinition.AppliesTo.PARTY}
	_follow_up("chain_bell", "Chain Bell", A.ALL_ENEMIES, 60, "toxic_echo", &"Event.Damage.Dealt",
		"30% on each hit: a follow-up of 60% ATK Physical on every enemy.", {"trigger_chance": 30})
	_power("chain_bell", "Chain Bell", [T], LEGENDARY, CORE_SET, ["Fit.FollowUp", "Grants.FollowUp"], ["chain_bell"], [],
		"Every hit has a 30% chance to ring across every enemy for 60% ATK Physical (a follow-up).")

	for strike in [1, 2, 3]:
		_proc("feast_knife_%d" % strike, "Feast Knife", A.RANDOM_ENEMY, [["execute", "damage", D.SCALED, 120, PHYSICAL]],
			"executioners_seal", &"Event.Unit.Killed", "On a kill: 120% ATK Physical to a random enemy.", {"asset_tags": STRIKE})
	_power("feast_knife", "Feast Knife", [B], LEGENDARY, CORE_SET, ["Fit.FollowUp"],
		["feast_knife_1", "feast_knife_2", "feast_knife_3"], [],
		"On a kill: 3 strikes of 120% ATK Physical, each on a random enemy. The strikes count as your own hits.")

	_follow_up("vengeful_aegis", "Vengeful Aegis", A.SINGLE_ENEMY, 100, "duelists_band", &"Event.Ally.Damage.Taken",
		"When an ally is hit: a follow-up of 100% ATK Physical on the attacker.")
	_power("vengeful_aegis", "Vengeful Aegis", [B], LEGENDARY, CORE_SET, ["Fit.FollowUp", "Grants.FollowUp"], ["vengeful_aegis"], [],
		"Whenever an ally is hit, strike the attacker for 100% ATK Physical (a follow-up).")

	_save("effects/sun_heart", _infinite({"sp_basic": 100}, true))
	_proc("sun_heart", "Sun Heart", A.OTHER_ENEMIES, [["execute", "damage", D.SCALED, 60, PHYSICAL]], "executioners_seal",
		&"Event.Ability.Used.Basic", "Basic attacks also hit every other enemy for 60% ATK Physical.", {"asset_tags": STRIKE})
	_power("sun_heart", "Sun Heart", [T], LEGENDARY, CORE_SET, ["Fit.Damage", "Fit.FollowUp", "Fit.Sp"], ["sun_heart"], ["sun_heart"],
		"Your basic attacks also hit every other enemy for 60% ATK Physical and give +100% SP.")

	var rise := _percent_of_max(50)  # no heal_taken: a save works for a holder that can't be healed
	rise.application_cue_tags.assign(HEAL_CUES)
	_save("effects/undying_ember_rise", rise)
	_save("effects/undying_ember_fury", _attack_up(50, 3))
	var saved := GameplayEffect.new()
	saved.policy = GameplayEffect.DurationPolicy.INFINITE
	saved.granted_tags.assign([&"State.DeathSaved"])
	_save("effects/undying_ember_saved", saved)
	var ember := _still(0.3)
	_ember_animation(ember)
	_proc("undying_ember", "Undying Ember", A.SELF, [["rise", "undying_ember_rise", D.USE_EFFECT, 0],
		["fury", "undying_ember_fury", D.USE_EFFECT, 0], ["saved", "undying_ember_saved", D.USE_EFFECT, 0]], "undying_ember",
		&"Event.Unit.Dying", "A killing blow leaves you at 50% HP with +50% ATK for 3 turns (once per battle).",
		{"query": _query([], [&"State.DeathSaved"])})
	_power("undying_ember", "Undying Ember", [B], LEGENDARY, CORE_SET, ["Fit.Survival", "Fit.Damage"], ["undying_ember"], [],
		"Once per battle, a killing blow leaves you at 50% HP with +50% ATK for 3 turns.")

	_save("effects/shatter_covenant", _infinite({"toughness_dmg": 200, "broken_dmg": 60}, false))
	_power("shatter_covenant", "Shatter Covenant", [T], LEGENDARY, CORE_SET, ["Fit.Break", "Grants.Break"], [], ["shatter_covenant"],
		"Triple toughness damage; Broken enemies take +60% damage from you.")

	_save("effects/philosophers_gold", _infinite({"atk": 5, "def": 5, "max_hp": 5}, true))
	# The Coin's gift: no pool and no card, one more copy at every floor's start (copies stack, spec 2.2).
	var gold_set: AbilitySet = _ability_set([], ["philosophers_gold"])
	gold_set.tags.assign([&"Item.Gold"])  # the mirrors (Collector, Reflection) skip it like food: not copied, still counted
	_item("philosophers_gold", "Philosopher's Gold", [RARE, &"Item.Fit.Damage", &"Item.Fit.Survival"], 0,
		gold_set, {"description": "+5% ATK, DEF and max HP."})
	var gift := GiveItem.new()
	gift.item = _r["items/philosophers_gold"]
	gift.recipient = GiveItem.Recipient.HOLDER
	_power("philosophers_coin", "Philosopher's Coin", [T, S], LEGENDARY, CORE_SET, ["Fit.Damage", "Fit.Survival", "Fit.Run"], [], [],
		"At each floor's start: Philosopher's Gold (+5% ATK, DEF and max HP for the rest of the run; it adds up).",
		{"on_floor_start": _outcomes([gift])})

	_proc("twin_soul", "Twin Soul", A.SELF, [], "", &"Event.Ability.Used.Skill", "Your skills cast again at 60%.",
		{"asset_tags": [&"Ability.Type.Echo"], "echo_scale": 60})
	_power("twin_soul", "Twin Soul", [B], LEGENDARY, DESCENT_SET, ["Fit.Damage", "Fit.Healing"], ["twin_soul"], [],
		"Your skills cast again at 60%.")

	_follow_up("plague_crown", "Plague Crown", A.SINGLE_ENEMY, 50, "toxic_echo", &"Event.Damage.Dealt.Dot",
		"Each tick of your DoTs: a follow-up of 50% ATK Physical on that enemy.")
	var spread := _one("poison", "mimic_tooth")
	spread.event_effect = true
	_proc("plague_crown_spread", "Plague Crown", A.RANDOM_OTHER_ENEMY, [spread], "mimic_tooth", &"Event.Damage.Dealt.Dot",
		"Each tick of your DoTs spreads one stack to another enemy.")
	_power("plague_crown", "Plague Crown", [T], LEGENDARY, DESCENT_SET, ["Fit.FollowUp", "Fit.Dot", "Grants.FollowUp", "Grants.Dot"],
		["plague_crown", "plague_crown_spread"], [],
		"Each tick of your DoTs: a follow-up of 50% ATK on that enemy, and one stack spreads to another enemy.")

	_follow_up("echo_crown_ally", "Echo Crown", A.RANDOM_ENEMY, 100, "executioners_seal", &"Event.Ally.Ability.Used.Ultimate",
		"After an ally's ult: a follow-up of 100% ATK Physical on a random enemy.")
	_follow_up("echo_crown_self", "Echo Crown", A.RANDOM_ENEMY, 100, "executioners_seal", &"Event.Ability.Used.Ultimate",
		"After your ult: a follow-up of 100% ATK Physical on a random enemy.")
	_power("echo_crown", "Echo Crown", [B], LEGENDARY, DESCENT_SET, ["Fit.FollowUp", "Fit.Party", "Grants.FollowUp"],
		["echo_crown_ally", "echo_crown_self"], [],
		"The party: after any ally's ult, every ally makes a follow-up of 100% ATK Physical.", party)


func _ember_animation(animation: Animation) -> void:
	var track := animation.add_track(Animation.TYPE_METHOD)
	animation.track_set_path(track, NodePath("."))
	for key in [[0.1, "rise"], [0.15, "fury"], [0.2, "saved"]]:
		animation.track_insert_key(track, key[0], {"method": &"execute", "args": [StringName(key[1])]})
	animation.resource_name = "undying_ember"
	_save("animations/undying_ember", animation)


# --- Void trades (6) -----------------------------------------------------------------------------------------------------

func _void_trades() -> void:
	var D := ExecutionRow.DamageMode
	var A := BattleAbility.Targeting
	var v := [VOID_POOL, CORRUPTED]
	_save("effects/void_heart", _infinite({"dmg_mult": 100, "heal_taken": -1000}, false))
	_power("void_heart", "Void Heart", v, LEGENDARY, CORE_SET, ["Fit.Damage"], [], ["void_heart"],
		"You deal double damage, but healing does nothing for you.")

	_save("effects/hollow_crown", _infinite({"max_hp": -20}, true))
	_follow_up("hollow_crown", "Hollow Crown", A.RANDOM_ENEMY, 60, "executioners_seal", &"Event.Attack.FollowUp",
		"Each of your follow-ups triggers another: 60% ATK Physical on a random enemy.")
	_power("hollow_crown", "Hollow Crown", v, LEGENDARY, CORE_SET, ["Fit.FollowUp"], ["hollow_crown"], ["hollow_crown"],
		"Each of your follow-ups triggers another (60% ATK Physical), up to ten in a row. −20% max HP.")

	_save("effects/void_tether_cost", _percent_of_max(-5))
	_follow_up("void_tether", "Void Tether", A.SINGLE_ENEMY, 150, "duelists_band", &"Event.Ally.Damage.Taken",
		"When an ally is hit: 5% of your max HP for a follow-up of 150% ATK Physical on the attacker.", {"cost": "void_tether_cost"})
	_power("void_tether", "Void Tether", v, EPIC, CORE_SET, ["Fit.FollowUp", "Grants.FollowUp"], ["void_tether"], [],
		"Whenever an ally is hit, strike the attacker for 150% ATK Physical (a follow-up); each strike costs 5% of your max HP.")

	_save("effects/null_lens", _infinite({"crit_dmg": 200, "crit_rate": -50}, false))
	_power("null_lens", "Null Lens", v, EPIC, CORE_SET, ["Fit.Damage"], [], ["null_lens"], "+200% crit damage, −50% crit rate.")

	_save("effects/starving_maw_heal", _heal(30))
	_save("effects/starving_maw_feast", _infinite({"atk": 10}, true))
	# The hunger is the cost of a passive at each turn start (like the Tether's): it outlives a death and a revive, sends no hit
	# event, and stops below 5% HP instead of killing.
	_save("effects/starving_maw_hunger", _percent_of_max(-5))
	_proc("starving_maw_hunger", "Starving Maw", A.SELF, [_one("gravity_pull", "momentum_charm")], "momentum_charm",
		&"Event.Turn.Start", "Lose 5% of max HP each turn.", {"cost": "starving_maw_hunger"})
	_proc("starving_maw", "Starving Maw", A.SELF, [["charge", "starving_maw_heal", D.USE_EFFECT, 0],
		["fury", "starving_maw_feast", D.USE_EFFECT, 0]], "corrupted_oath", &"Event.Unit.Killed",
		"On a kill: heal 30% of max HP and gain +10% ATK for the battle.")
	_power("starving_maw", "Starving Maw", v, EPIC, CORE_SET, ["Fit.Damage", "Fit.Survival"], ["starving_maw", "starving_maw_hunger"], [],
		"On a kill: heal 30% of max HP and gain +10% ATK for the battle (it adds up). You lose 5% of max HP each turn.")

	# The user, 2026-11-23: +60, not the spec's first +100, which chained ults without end.
	_save("effects/echo_of_nothing_charge", _instant({"energy": 60}))
	_save("effects/echo_of_nothing", _infinite({"max_hp": -30}, true))
	_proc("echo_of_nothing", "Echo of Nothing", A.SELF, [_one("echo_of_nothing_charge", "corrupted_coil")], "corrupted_coil",
		&"Event.Ability.Used.Ultimate", "After your ult: +60 ult charge.")
	_power("echo_of_nothing", "Echo of Nothing", v, EPIC, CORE_SET, ["Fit.Ult"], ["echo_of_nothing"], ["echo_of_nothing"],
		"After each of your ults, +60 ult charge. −30% max HP.")


# --- Epics (8) -----------------------------------------------------------------------------------------------------------

func _epics() -> void:
	var D := ExecutionRow.DamageMode
	var A := BattleAbility.Targeting
	var party := {"applies_to": ItemDefinition.AppliesTo.PARTY}
	_follow_up("chain_hook", "Chain Hook", A.RANDOM_OTHER_ENEMY, 60, "toxic_echo", &"Event.Damage.Dealt",
		"25% on each hit: a follow-up of 60% ATK Physical on a random other enemy.", {"trigger_chance": 25})
	_power("chain_hook", "Chain Hook", [T, S], EPIC, CORE_SET, ["Fit.FollowUp", "Grants.FollowUp"], ["chain_hook"], [],
		"Every hit has a 25% chance of a follow-up on a random other enemy: 60% ATK Physical.")

	_save("effects/reapers_mark", _attack_up(25, 2, 3))
	var reap := _one("reapers_mark", "momentum_charm")
	reap.delay_x100 = Fixed.from_typed(-30)
	_proc("reapers_mark", "Reaper's Mark", A.SELF, [reap], "momentum_charm", &"Event.Unit.Killed",
		"On a kill: +25% ATK for 2 turns (up to 3 stacks) and a 30% action advance.")
	_power("reapers_mark", "Reaper's Mark", [T, S], EPIC, CORE_SET, ["Fit.Damage", "Fit.Speed"], ["reapers_mark"], [],
		"On a kill: +25% ATK for 2 turns (up to 3 stacks) and a 30% action advance.")

	_follow_up("guardians_vow", "Guardian's Vow", A.SINGLE_ENEMY, 80, "duelists_band", &"Event.Ally.Damage.Taken",
		"When an ally is hit: a follow-up of 80% ATK Physical on the attacker.")
	_save("effects/guardians_vow_heal", _heal(10))
	_proc("guardians_vow_heal", "Guardian's Vow", A.SINGLE_ALLY, [_one("guardians_vow_heal", "heartstring")], "heartstring",
		&"Event.Ally.Damage.Taken", "When an ally is hit: heal them 10% of their max HP.")
	_power("guardians_vow", "Guardian's Vow", [T], EPIC, CORE_SET, ["Fit.FollowUp", "Fit.Healing", "Grants.FollowUp"],
		["guardians_vow", "guardians_vow_heal"], [],
		"When an ally is hit, counter for 80% ATK Physical (a follow-up) and heal them 10% of their max HP.")

	_proc("venom_spur", "Venom Spur", A.SINGLE_ENEMY, [_one("poison", "mimic_tooth")], "mimic_tooth", &"Event.Damage.Dealt",
		"Every hit adds 1 Poison stack.")
	_power("venom_spur", "Venom Spur", [T, S], EPIC, CORE_SET, ["Fit.Dot", "Grants.Dot"], ["venom_spur"], [],
		"Every hit adds 1 Poison stack.")

	_save("effects/second_wind_heal", _heal(15))
	for pair in [["second_wind_start", &"Event.Battle.Start"], ["second_wind_kill", &"Event.Unit.Killed"]]:
		_proc(pair[0], "Second Wind", A.SELF, [_one("second_wind_heal", "heartstring")], "heartstring", pair[1],
			"Heal 15% of max HP.")
	_power("second_wind", "Second Wind", [T, S], EPIC, CORE_SET, ["Fit.Survival"], ["second_wind_start", "second_wind_kill"], [],
		"Heal 15% of max HP at battle start and on every kill.")

	_save("effects/lifebloom_seed", _infinite({"max_hp": 10}, true))
	var bloom := _refresh(_percent_dot(8, 3, [&"Status.Buff.Regen"]))
	bloom.persistent_cue_tags.assign([&"Cue.Fx.Buff.Regen"])
	bloom.application_cue_tags.assign(BUFF_CUES)
	bloom.periodic_cue_tags.assign(HEAL_CUES)
	_save("effects/lifebloom_regen", bloom)
	_proc("lifebloom_seed", "Lifebloom Seed", A.SELF, [_one("lifebloom_regen", "censer")], "censer", &"Event.Battle.Start",
		"Regen at battle start: 8% of max HP for 3 turns.")
	_power("lifebloom_seed", "Lifebloom Seed", [B], EPIC, CORE_SET, ["Fit.Survival", "Fit.Party"], ["lifebloom_seed"], ["lifebloom_seed"],
		"The party: +10% max HP, and Regen at battle start (8% of max HP for 3 turns).", party)

	_save("effects/battle_hymn", _mixed_infinite([["atk", PERCENT, 15], ["spd", ADD, 10]]))
	_power("battle_hymn", "Battle Hymn", [B], EPIC, CORE_SET, ["Fit.Damage", "Fit.Speed", "Fit.Party"], [], ["battle_hymn"],
		"The party: +15% ATK and +10 SPD.", party)

	_save("effects/bulwark_sigil", _infinite({"max_hp": 30, "def": 30}, true))
	_power("bulwark_sigil", "Bulwark Sigil", [T, S], EPIC, CORE_SET, ["Fit.Survival"], [], ["bulwark_sigil"], "+30% max HP and +30% DEF.")


# --- Rares (8) -----------------------------------------------------------------------------------------------------------

func _rares() -> void:
	var D := ExecutionRow.DamageMode
	var A := BattleAbility.Targeting
	_follow_up("static_ring", "Static Ring", A.SINGLE_ENEMY, 50, "toxic_echo", &"Event.Damage.Dealt",
		"20% on each hit: a follow-up of 50% ATK Physical on the same target.", {"trigger_chance": 20})
	_power("static_ring", "Static Ring", [T, S, C], RARE, CORE_SET, ["Fit.FollowUp", "Grants.FollowUp"], ["static_ring"], [],
		"Every hit has a 20% chance of a follow-up on the same target: 50% ATK Physical.")

	_follow_up("hunters_snare", "Hunter's Snare", A.SINGLE_ENEMY, 50, "toxic_echo", &"Event.Damage.Dealt.Weakness",
		"Weakness hits: a follow-up of 50% ATK Physical.")
	_power("hunters_snare", "Hunter's Snare", [T, S], RARE, CORE_SET, ["Fit.FollowUp", "Grants.FollowUp"], ["hunters_snare"], [],
		"Hitting a weakness triggers a follow-up: 50% ATK Physical.")

	var feast := _heal(8)
	feast.modifiers.append(_modifier("energy", ADD, 15))
	_save("effects/blood_charm", feast)
	_proc("blood_charm", "Blood Charm", A.SELF, [_one("blood_charm", "heartstring")], "heartstring", &"Event.Unit.Killed",
		"On a kill: heal 8% of max HP and +15 ult charge.")
	_power("blood_charm", "Blood Charm", [T, S, C], RARE, CORE_SET, ["Fit.Survival", "Fit.Ult"], ["blood_charm"], [],
		"On a kill: heal 8% of max HP and gain 15 ult charge.")

	_save("effects/thick_hide", _infinite({"max_hp": 20, "def": 15}, true))
	_power("thick_hide", "Thick Hide", [T, S, C], RARE, CORE_SET, ["Fit.Survival"], [], ["thick_hide"], "+20% max HP and +15% DEF.")

	var burn := _row("bleed", "burn", D.FLAT, 30, ExecutionRow.Targets.ALL, [&"Damage.Type.Fire"])
	_proc("kindling_burn", "Kindling", A.SINGLE_ENEMY, [burn], "mimic_tooth", &"Event.Damage.Dealt.Fire",
		"40% on each Fire hit: the target Burns.", {"trigger_chance": 40})
	_power("kindling", "Kindling", [T, S], RARE, CORE_SET, ["Fit.Dot", "Grants.Dot"], ["kindling_burn"], [],
		"Fire hits have a 40% chance to add a Burn (30 Fire damage for 2 turns).")

	_proc("quick_draw", "Quick Draw", A.SELF, [_advance(40)], "momentum_charm", &"Event.Battle.Start", "A 40% action advance at battle start.")
	_power("quick_draw", "Quick Draw", [T, S, C], RARE, CORE_SET, ["Fit.Speed"], ["quick_draw"], [], "A 40% action advance at battle start.")

	_save("effects/focus_stone", _mixed_infinite([["atk", PERCENT, 25], ["crit_rate", ADD, 10]]))
	_power("focus_stone", "Focus Stone", [T, S], RARE, CORE_SET, ["Fit.Damage"], [], ["focus_stone"], "+25% ATK and +10% crit rate.")

	_save("effects/menders_bell", _infinite({"heal_mult": 40, "sp_gain": 15}, false))
	_power("menders_bell", "Mender's Bell", [T, S, C], RARE, CORE_SET, ["Fit.Healing", "Fit.Sp"], [], ["menders_bell"],
		"+40% healing given and +15% SP gain.")


# --- Weapons (4) and armor (4) -------------------------------------------------------------------------------------------

func _gear() -> void:
	var D := ExecutionRow.DamageMode
	var A := BattleAbility.Targeting
	_save("effects/executioners_greatsword", _infinite({"atk": 50}, true))
	var finish := GameplayEffect.new()
	finish.policy = GameplayEffect.DurationPolicy.INSTANT
	finish.executions.append(load(FINISH).new())
	_save("effects/greatsword_finish", finish)
	_proc("executioners_greatsword", "Executioner's Greatsword", A.SINGLE_ENEMY, [_one("greatsword_finish", "executioners_seal")],
		"executioners_seal", &"Event.Damage.Dealt", "A hit that leaves an enemy (not a boss) below 25% HP finishes it.")
	_piece_of("executioners_greatsword", "Executioner's Greatsword", "Weapon", LEGENDARY, CORE_SET, ["Fit.Damage", "Fit.FollowUp"],
		["executioners_greatsword"], ["executioners_greatsword"],
		"+50% ATK. A hit that leaves an enemy (not a boss) below 25% HP finishes it.")

	for strike in [1, 2]:
		_follow_up("storm_spear_%d" % strike, "Storm Spear", A.RANDOM_OTHER_ENEMY, 60, "toxic_echo", &"Event.Ability.Used.Basic",
			"Basic attacks: a follow-up of 60% ATK Physical on a random other enemy.")
	_piece_of("storm_spear", "Storm Spear", "Weapon", EPIC, CORE_SET, ["Fit.FollowUp", "Grants.FollowUp"],
		["storm_spear_1", "storm_spear_2"], [], "Basic attacks trigger 2 follow-ups on random other enemies: 60% ATK Physical each.")

	var lifesteal := GameplayEffect.new()
	lifesteal.policy = GameplayEffect.DurationPolicy.INSTANT
	var drink: GameplayExecutionCalculation = load(EVENT_AMOUNT_CALC).new()
	drink.set("target_bonus", "heal_taken")
	lifesteal.executions.append(drink)
	lifesteal.application_cue_tags.assign(HEAL_CUES)
	_save("effects/bloodthirst_heal", lifesteal)
	var drain := _row("drain", "bloodthirst_heal", D.USE_EFFECT, 0, ExecutionRow.Targets.ALL)
	drain.damage_mode = D.EVENT_AMOUNT
	drain.multiplier_x100 = Fixed.from_typed(25)
	_proc("bloodthirst_blade", "Bloodthirst Blade", A.SELF, [drain], "corrupted_vampire", &"Event.Damage.Dealt",
		"Heal 25% of the damage you deal.")
	_piece_of("bloodthirst_blade", "Bloodthirst Blade", "Weapon", EPIC, DESCENT_SET, ["Fit.Damage", "Fit.Survival"],
		["bloodthirst_blade"], [], "Heal 25% of the damage you deal.")

	_save("effects/runebound_staff", _mixed_infinite([["atk", PERCENT, 40], ["sp_cost", ADD, -25]]))
	_piece_of("runebound_staff", "Runebound Staff", "Weapon", LEGENDARY, DESCENT_SET, ["Fit.Damage", "Fit.Sp"], [], ["runebound_staff"],
		"+40% ATK. Your abilities cost 25% less SP.")

	_save("effects/thornheart_plate", _infinite({"max_hp": 30}, true))
	var reflect := GameplayEffect.new()
	reflect.policy = GameplayEffect.DurationPolicy.INSTANT
	var thorns: GameplayExecutionCalculation = load(EVENT_AMOUNT_CALC).new()
	thorns.set("loss", true)
	reflect.executions.append(thorns)
	_save("effects/thornheart_reflect", reflect)
	var back := _row("thorns", "thornheart_reflect", D.USE_EFFECT, 0, ExecutionRow.Targets.ALL)
	back.damage_mode = D.EVENT_AMOUNT
	back.multiplier_x100 = Fixed.from_typed(50)
	_proc("thornheart_plate", "Thornheart Plate", A.SINGLE_ENEMY, [back], "thorn_mail", &"Event.Damage.Taken",
		"Reflect 50% of the damage you take to the attacker.")
	_piece_of("thornheart_plate", "Thornheart Plate", "Body", LEGENDARY, CORE_SET, ["Fit.Survival", "Grants.Tank"],
		["thornheart_plate"], ["thornheart_plate"], "+30% max HP. Reflect 50% of the damage you take to the attacker.")

	_save("effects/sentinel_plate", _infinite({"dmg_taken": -30}, false))
	_proc("sentinel_plate", "Sentinel Plate", A.SELF, [_one("taunt", "halo")], "halo", &"Event.Battle.Start",
		"Taunt for 2 turns at battle start.")
	_piece_of("sentinel_plate", "Sentinel Plate", "Body", EPIC, CORE_SET, ["Fit.Survival", "Grants.Tank"],
		["sentinel_plate"], ["sentinel_plate"], "−30% damage taken. Taunt for 2 turns at battle start.")

	_save("effects/mantle_of_haste", _infinite({"spd": 25}, false))
	_proc("mantle_of_haste", "Mantle of Haste", A.SELF, [_advance(50)], "momentum_charm", &"Event.Battle.Start",
		"A 50% action advance at battle start.")
	_piece_of("mantle_of_haste", "Mantle of Haste", "Body", EPIC, DESCENT_SET, ["Fit.Speed"], ["mantle_of_haste"], ["mantle_of_haste"],
		"+25 SPD. A 50% action advance at battle start.")

	var banner := _infinite({"atk": 25, "def": 15}, true)
	_save("effects/warlords_crown", banner)
	_proc("warlords_crown", "Warlord's Crown", A.ALL_ALLIES, [_one("warlords_crown", "censer")], "censer", &"Event.Battle.Start",
		"The party: +25% ATK and +15% DEF for the battle.")
	_piece_of("warlords_crown", "Warlord's Crown", "Head", LEGENDARY, DESCENT_SET, ["Fit.Damage", "Fit.Survival", "Fit.Party"],
		["warlords_crown"], [], "The party: +25% ATK and +15% DEF in battle.")


# --- The pools, before and after (spec 2.3) ------------------------------------------------------------------------------

func _pool_counts() -> Dictionary:
	var result := {"pools": {}, "overlap": 0}
	for folder in ["items", "equipment"]:
		for file in DirAccess.get_files_at(CONTENT + folder):
			if not file.ends_with(".tres"):
				continue
			var thing: Resource = load(CONTENT + folder + "/" + file)
			var tags: Array = thing.get("tags")
			var rarity := "?"
			for tag in tags:
				if String(tag).begins_with("Item.Rarity."):
					rarity = String(tag).trim_prefix("Item.Rarity.")
			for tag in tags:
				if String(tag).begins_with("Pool."):
					var row: Dictionary = result["pools"].get_or_add(String(tag), {})
					row[rarity] = int(row.get(rarity, 0)) + 1
			if tags.has(T) and tags.has(B):
				result["overlap"] += 1
	return result


func _print_pools(label: String, counts: Dictionary) -> void:
	print("pools %s (items and gear; Treasure/Boss overlap %d):" % [label, counts["overlap"]])
	var names: Array[String] = []
	names.assign(counts["pools"].keys())
	names.sort()
	for name in names:
		print("  %-14s %s" % [name, counts["pools"][name]])
