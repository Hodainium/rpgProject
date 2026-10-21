## One-time builder for the item-pass content (spec item-pass 3.6, 3.7): the new items, armor, and the effects,
## abilities and animations they need, written into res://content/demo/ through ResourceSaver like build_demo.
##
## Same rules as build_demo, whose helpers it reuses: it never overwrites (an existing file is skipped and used), it
## writes nowhere but content/demo/, and it never touches an existing file. Edits to existing demo files (enemies,
## abilities, the damage ExecCalc, the run structure) are made by hand with your approval, not here.
## Values are the reviewed list's starting values, typed as a designer would.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_item_pass.tscn
extends "res://game/tools/build_demo.gd"

const PERCENT_OF_MAX: String = CONTENT + "exec_calcs/exec_calc_percent_of_max.gd"
const FOLLOW_UP := [&"Ability.Type.FollowUp"]
const ADD := GameplayEffectModifier.Operation.ADD
const PERCENT := GameplayEffectModifier.Operation.PERCENT_ADD


func _ready() -> void:
	if not ResourceLoader.exists(GENERATED_SET) or load(PERCENT_OF_MAX) == null:
		_quit("Needs %s and %s (run --import once first)." % [GENERATED_SET, PERCENT_OF_MAX])
		return
	_r["effects/damage"] = load(CONTENT + "effects/damage.tres")
	_item_effects()
	_item_abilities()
	_items()
	_armor()
	print("build_item_pass: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _made:
		print("  made    ", path)
	for path in _skipped:
		print("  skipped ", path)
	for path in _failed:
		print("  FAILED  ", path)
	get_tree().quit(1 if not _failed.is_empty() else 0)


# --- Effects -----------------------------------------------------------------------------------------------------------

func _item_effects() -> void:
	# Stat items and armor: infinite effects, granted through the AbilitySet.
	_save("effects/iron_ring", _infinite({"def": 40}, false))
	_save("effects/swift_charm", _infinite({"spd": 12}, false))
	_save("effects/lucky_coin", _infinite({"crit_rate": 10}, false))              # +10% (crit_rate is a stored %)
	_save("effects/glass_lens", _infinite({"crit_dmg": 40, "max_hp": -150}, false))
	_save("effects/mana_crystal", _infinite({"max_mp": 40}, false))
	_save("effects/heart_locket", _infinite({"max_hp": 250}, false))
	_save("effects/war_drum", _infinite({"spd": 6}, false))
	_save("effects/guardian_totem", _infinite({"def": 25}, false))
	_save("effects/shatter_hammer", _infinite({"toughness_dmg": 50}, false))      # +50% toughness damage
	_save("effects/predators_fang", _infinite({"broken_dmg": 25}, false))         # +25% damage to Broken targets
	_save("effects/leather_cap", _infinite({"def": 20, "max_hp": 100}, false))
	_save("effects/seers_circlet", _infinite({"crit_rate": 5, "max_mp": 20}, false))
	_save("effects/chain_vest", _infinite({"def": 60}, false))
	_save("effects/mage_robe", _mixed_infinite([["max_mp", ADD, 50], ["atk", PERCENT, 5]]))
	_save("effects/bracers", _infinite({"atk": 8}, true))
	_save("effects/swift_boots", _infinite({"spd": 10}, false))
	_save("effects/greaves", _infinite({"def": 50, "spd": -4}, false))
	# Triggered passives and usables: instant effects.
	_save("effects/vampire_heal", _instant({"hp": 15}))
	_save("effects/battle_horn_charge", _instant({"energy": 30}))
	_save("effects/bounty_reward", _instant({"energy": 20, "hp": 50}))
	_save("effects/sharp_eye_charge", _instant({"energy": 10}))
	_save("effects/scholars_insight", _instant({"energy": 15, "mp": 5}))
	_save("effects/momentum_charge", _instant({"energy": 10}))
	_save("effects/glass_heart_heal", _instant({"hp": 80}))
	_save("effects/breakers_charge", _instant({"energy": 20}))
	_save("effects/encore_heal", _instant({"hp": 60}))
	_save("effects/ether_mp", _instant({"mp": 60}))
	_save("effects/gloves_charge", _instant({"energy": 10}))
	_save("effects/hourglass_heal", _percent_of_max(5))
	_save("effects/stew_heal", _percent_of_max(30))
	_save("effects/salts_revive", _percent_of_max(20))
	# Timed effects (turn-based): buffs, the Burn DoT, and the "Exposed" weaknesses.
	_save("effects/breakers_fury", _buff({"atk": 15}, 2, [&"Status.Buff.AttackUp"]))
	_save("effects/rally", _buff({"atk": 20}, 2, [&"Status.Buff.AttackUp"]))
	_save("effects/burn", _burn(2))
	_save("effects/exposed_physical", _tagged([&"Weakness.Physical", &"Status.Debuff.Exposed"], 2))
	_save("effects/exposed_fire", _tagged([&"Weakness.Fire", &"Status.Debuff.Exposed"], 1))


func _mixed_infinite(changes: Array) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INFINITE
	for change in changes:
		effect.modifiers.append(_modifier(change[0], change[1], change[2]))
	return effect


## +percent of the attributes for `turns` of the holder's turns (TURN_BASED, counted down at its turn end).
func _buff(changes: Dictionary, turns: int, granted: Array) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.TURN_BASED
	effect.duration_turns = turns
	effect.granted_tags.assign(granted)
	for attribute_name in changes:
		effect.modifiers.append(_modifier(attribute_name, PERCENT, changes[attribute_name]))
	return effect


## Instant: the target regains `typed`% of its maximum HP (a revive on a dead unit).
func _percent_of_max(typed: float) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INSTANT
	var calc: GameplayExecutionCalculation = load(PERCENT_OF_MAX).new()
	calc.set("percent_x100", Fixed.from_typed(typed))
	effect.executions.append(calc)
	return effect


## A DoT: the damage ExecCalc each turn start, with the flat damage the applying row sets.
func _burn(turns: int) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.TURN_BASED
	effect.period = 1.0
	effect.duration_turns = turns
	effect.granted_tags.assign([&"Status.Debuff.Burn"])
	effect.executions.append(load(DAMAGE_CALC).new())
	return effect


func _tagged(tags: Array, turns: int) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.TURN_BASED
	effect.duration_turns = turns
	effect.granted_tags.assign(tags)
	return effect


# --- Abilities ---------------------------------------------------------------------------------------------------------

func _item_abilities() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	var ice := [&"Damage.Type.Ice"]
	var fire := [&"Damage.Type.Fire"]
	# Triggered passives.
	_ability("thorn_mail", "Ability.Passive.Thornmail", B.SINGLE_ENEMY, [_row("thorns", "damage", D.FLAT, 60, T.ALL, physical)],
		_flash(0.4), [[0.2, "thorns"]], {"trigger": &"Event.Damage.Taken", "sound": ["Blow4", 0.1, -6.0]})
	_ability("vampire_fang", "Ability.Passive.Vampirefang", B.SELF, [_row("drain", "vampire_heal", D.USE_EFFECT, 0, T.ALL)],
		_still(0.05), [[0.0, "drain"]], {"trigger": &"Event.Damage.Dealt"})
	_ability("cinder_glove", "Ability.Passive.Cinderglove", B.SINGLE_ENEMY, [_row("ignite", "burn", D.FLAT, 40, T.ALL, fire)],
		_flash(0.4), [[0.2, "ignite"]], {"trigger": &"Event.Damage.Dealt.Fire", "sound": ["Fire2", 0.0, -6.0]})
	_ability("battle_horn", "Ability.Passive.Battlehorn", B.SELF, [_row("charge", "battle_horn_charge", D.USE_EFFECT, 0, T.ALL)],
		_jump(0.5), [[0.2, "charge"]], {"trigger": &"Event.Battle.Start", "sound": ["Buff", 0.0, 0.0]})
	_ability("hourglass", "Ability.Passive.Hourglass", B.SELF, [_row("mend", "hourglass_heal", D.USE_EFFECT, 0, T.ALL)],
		_still(0.05), [[0.0, "mend"]], {"trigger": &"Event.Turn.Start"})
	_ability("frost_needle", "Ability.Passive.Frostneedle", B.SINGLE_ENEMY, [_row("needle", "damage", D.FLAT, 30, T.ALL, ice)],
		_flash(0.4), [[0.2, "needle"]], {"trigger": &"Event.Damage.Dealt.Physical", "sound": ["Ice2", 0.0, -6.0]})
	_ability("bounty_mark", "Ability.Passive.Bountymark", B.SELF, [_row("bounty", "bounty_reward", D.USE_EFFECT, 0, T.ALL)],
		_spin(0.5), [[0.25, "bounty"]], {"trigger": &"Event.Unit.Killed", "sound": ["Item1", 0.0, 0.0]})
	_ability("sharp_eye", "Ability.Passive.Sharpeye", B.SELF, [_row("charge", "sharp_eye_charge", D.USE_EFFECT, 0, T.ALL)],
		_still(0.05), [[0.0, "charge"]], {"trigger": &"Event.Damage.Dealt.Critical"})
	_ability("executioners_seal", "Ability.Passive.Executioner", B.SINGLE_ENEMY,
		[_row("execute", "damage", D.SCALED, 50, T.ALL, physical)], _jump(0.6), [[0.3, "execute"]],
		{"trigger": &"Event.Damage.Dealt.Critical", "asset_tags": FOLLOW_UP, "sound": ["Attack1", 0.2, -8.0]})
	_ability("hunters_mark", "Ability.Passive.Huntersmark", B.SINGLE_ENEMY,
		[_row("shot", "damage", D.SCALED, 40, T.ALL, physical)], _jump(0.6), [[0.3, "shot"]],
		{"trigger": &"Event.Damage.Dealt.Weakness", "asset_tags": FOLLOW_UP, "sound": ["Shot1", 0.2, -8.0]})
	_ability("scholars_tome", "Ability.Passive.Scholarstome", B.SELF, [_row("insight", "scholars_insight", D.USE_EFFECT, 0, T.ALL)],
		_still(0.05), [[0.0, "insight"]], {"trigger": &"Event.Damage.Dealt.Weakness"})
	_ability("momentum_charm", "Ability.Passive.Momentum", B.SELF, [_row("charge", "momentum_charge", D.USE_EFFECT, 0, T.ALL)],
		_still(0.05), [[0.0, "charge"]], {"trigger": &"Event.Attack.FollowUp"})
	_ability("glass_heart", "Ability.Passive.Glassheart", B.SELF, [_row("mend", "glass_heart_heal", D.USE_EFFECT, 0, T.ALL)],
		_flash(0.4), [[0.2, "mend"]], {"trigger": &"Event.Damage.Taken.Critical", "sound": ["Recovery5", 0.0, -6.0]})
	_ability("breakers_oath", "Ability.Passive.Breakersoath", B.SELF,
		[_row("charge", "breakers_charge", D.USE_EFFECT, 0, T.ALL), _row("fury", "breakers_fury", D.USE_EFFECT, 0, T.ALL)],
		_spin(0.6), [[0.2, "charge"], [0.3, "fury"]], {"trigger": &"Event.Damage.Dealt.Break", "sound": ["Buff", 0.0, 0.0]})
	_ability("encore_ribbon", "Ability.Passive.Encore", B.SELF, [_row("mend", "encore_heal", D.USE_EFFECT, 0, T.ALL)],
		_jump(0.5), [[0.2, "mend"]], {"trigger": &"Event.Battle.OneMore", "sound": ["Chime1", 0.0, -4.0]})
	# Armor passives.
	_ability("hunters_gloves", "Ability.Passive.Huntersgloves", B.SELF, [_row("charge", "gloves_charge", D.USE_EFFECT, 0, T.ALL)],
		_still(0.05), [[0.0, "charge"]], {"trigger": &"Event.Damage.Dealt.Weakness"})
	_ability("duelists_band", "Ability.Passive.Duelistsband", B.SINGLE_ENEMY,
		[_row("riposte", "damage", D.SCALED, 30, T.ALL, physical)], _jump(0.5), [[0.25, "riposte"]],
		{"trigger": &"Event.Damage.Dealt.Critical", "asset_tags": FOLLOW_UP, "sound": ["Attack2", 0.1, -10.0]})
	_ability("ember_pendant", "Ability.Passive.Emberpendant", B.SINGLE_ENEMY,
		[_row("expose", "exposed_fire", D.USE_EFFECT, 0, T.ALL)], _flash(0.3), [[0.15, "expose"]],
		{"trigger": &"Event.Damage.Dealt.Fire", "sound": ["Fire1", 0.0, -8.0]})
	# Usable items.
	var fire_blast := _row("blast", "damage", D.FLAT, 300, T.ALL, fire)
	fire_blast.toughness_x100 = Fixed.from_typed(60)
	_ability("fire_bomb", "Ability.Item.Firebomb", B.BLAST_ENEMY, [fire_blast], _jump(0.6), [[0.35, "blast"]],
		{"sound": ["Explosion1", 0.3, -4.0]})
	var frost_blast := _row("blast", "damage", D.FLAT, 250, T.ALL, ice)
	frost_blast.toughness_x100 = Fixed.from_typed(60)
	_ability("frost_bomb", "Ability.Item.Frostbomb", B.BLAST_ENEMY, [frost_blast], _spin(0.6), [[0.35, "blast"]],
		{"sound": ["Ice5", 0.3, -4.0]})
	_ability("ether", "Ability.Item.Ether", B.SINGLE_ALLY, [_row("restore", "ether_mp", D.USE_EFFECT, 0, T.ALL)],
		_flash(0.5), [[0.3, "restore"]], {"sound": ["Recovery8", 0.0, 0.0]})
	_ability("rally_horn", "Ability.Item.Rally", B.ALL_ALLIES, [_row("rally", "rally", D.USE_EFFECT, 0, T.ALL)],
		_jump(0.6), [[0.3, "rally"]], {"sound": ["Song", 0.0, -4.0]})
	_ability("smelling_salts", "Ability.Item.Salts", B.SINGLE_DEAD_ALLY, [_row("revive", "salts_revive", D.USE_EFFECT, 0, T.ALL)],
		_spin(0.6), [[0.4, "revive"]], {"sound": ["Raise2", 0.0, -2.0]})
	_ability("analyzer_lens", "Ability.Item.Analyzer", B.SINGLE_ENEMY, [_row("expose", "exposed_physical", D.USE_EFFECT, 0, T.ALL)],
		_flash(0.5), [[0.3, "expose"]], {"sound": ["Flash1", 0.0, -6.0]})


# --- Items -------------------------------------------------------------------------------------------------------------

func _items() -> void:
	var common := &"Item.Rarity.Common"
	var rare := &"Item.Rarity.Rare"
	var t := &"Pool.Treasure"
	var s := &"Pool.Shop"
	var b := &"Pool.Boss"
	var party := {"applies_to": ItemDefinition.AppliesTo.PARTY}
	# Stat (holder).
	_described("iron_ring", "Iron Ring", [t, s, common], 5, _ability_set([], ["iron_ring"]), "+40 DEF.")
	_described("swift_charm", "Swift Charm", [t, s, common], 6, _ability_set([], ["swift_charm"]), "+12 SPD.")
	_described("lucky_coin", "Lucky Coin", [t, common], 5, _ability_set([], ["lucky_coin"]), "+10% crit rate.")
	_described("glass_lens", "Glass Lens", [t, rare], 7, _ability_set([], ["glass_lens"]), "+40% crit damage, but −150 max HP.")
	_described("mana_crystal", "Mana Crystal", [t, s, common], 5, _ability_set([], ["mana_crystal"]), "+40 max MP.")
	_described("heart_locket", "Heart Locket", [t, s, common], 6, _ability_set([], ["heart_locket"]), "+250 max HP.")
	# Party-wide.
	_described("war_drum", "War Drum", [t, b, rare], 9, _ability_set([], ["war_drum"]), "The whole party: +6 SPD.", party)
	_described("guardian_totem", "Guardian Totem", [b, rare], 9, _ability_set([], ["guardian_totem"]), "The whole party: +25 DEF.", party)
	# Triggered.
	_described("thorn_mail", "Thorn Mail", [t, rare], 8, _ability_set(["thorn_mail"], []), "When hit, strike back for 60 Physical damage.")
	_described("vampire_fang", "Vampire Fang", [t, rare], 8, _ability_set(["vampire_fang"], []), "Heal 15 HP whenever you deal damage.")
	_described("cinder_glove", "Cinder Glove", [t, rare], 7, _ability_set(["cinder_glove"], []), "Fire damage sets the target ablaze: 40 Fire damage for 2 turns.")
	_described("battle_horn", "Battle Horn", [t, s, common], 6, _ability_set(["battle_horn"], []), "Start every battle with +30 ult charge.")
	_described("hourglass", "Hourglass", [t, rare], 8, _ability_set(["hourglass"], []), "Heal 5% of max HP at the start of each of your turns.")
	_described("frost_needle", "Frost Needle", [t, common], 6, _ability_set(["frost_needle"], []), "Physical damage also deals 30 Ice damage.")
	_described("bounty_mark", "Bounty Mark", [t, b, rare], 9, _ability_set(["bounty_mark"], []), "On a kill: +20 ult charge and heal 50 HP.")
	# Crit, weakness, break, follow-up, One More.
	_described("sharp_eye", "Sharp Eye", [t, common], 6, _ability_set(["sharp_eye"], []), "Critical hits give +10 ult charge.")
	_described("executioners_seal", "Executioner's Seal", [t, b, rare], 10, _ability_set(["executioners_seal"], []), "Critical hits trigger a follow-up: 50% ATK Physical.")
	_described("hunters_mark", "Hunter's Mark", [t, rare], 9, _ability_set(["hunters_mark"], []), "Hitting a weakness triggers a follow-up: 40% ATK Physical.")
	_described("scholars_tome", "Scholar's Tome", [t, s, common], 6, _ability_set(["scholars_tome"], []), "Hitting a weakness gives +15 ult charge and 5 MP.")
	_described("momentum_charm", "Momentum Charm", [t, common], 6, _ability_set(["momentum_charm"], []), "Each follow-up attack gives +10 ult charge.")
	_described("glass_heart", "Glass Heart", [t, common], 5, _ability_set(["glass_heart"], []), "Heal 80 HP when you take a critical hit.")
	_described("shatter_hammer", "Shatter Hammer", [t, rare], 8, _ability_set([], ["shatter_hammer"]), "+50% toughness damage.")
	_described("breakers_oath", "Breaker's Oath", [t, b, rare], 9, _ability_set(["breakers_oath"], []), "Breaking an enemy: +20 ult charge and +15% ATK for 2 turns.")
	_described("encore_ribbon", "Encore Ribbon", [t, common], 6, _ability_set(["encore_ribbon"], []), "Heal 60 HP whenever you get a One More.")
	_described("predators_fang", "Predator's Fang", [t, rare], 9, _ability_set([], ["predators_fang"]), "+25% damage to Broken enemies.")
	# Usable.
	var consumable := ItemDefinition.UseMode.CONSUMABLE
	var cooldown := ItemDefinition.UseMode.COOLDOWN
	_usable("fire_bomb", "Fire Bomb", [s, common], 4, "fire_bomb", consumable, 1, "Blast: 300 Fire damage (breaks Slimes).")
	_usable("frost_bomb", "Frost Bomb", [s, common], 4, "frost_bomb", consumable, 1, "Blast: 250 Ice damage (breaks Bats).")
	_usable("ether", "Ether", [s, common], 5, "ether", cooldown, 3, "One ally regains 60 MP. Ready again after 3 won battles.")
	_usable("rally_horn", "Rally Horn", [t, s, rare], 8, "rally_horn", cooldown, 2, "The party gets +20% ATK for 2 turns. Ready again after 2 won battles.")
	_usable("smelling_salts", "Smelling Salts", [s, rare], 9, "smelling_salts", cooldown, 4, "Revive an ally with 20% HP. Ready again after 4 won battles.")
	_usable("analyzer_lens", "Analyzer Lens", [t, s, rare], 8, "analyzer_lens", cooldown, 2, "An enemy becomes weak to Physical for 2 turns. Ready again after 2 won battles.")
	# Run hooks.
	_described("coin_purse", "Coin Purse", [t, s, common], 5, null, "+1 coin for every room you clear.",
		{"on_room_cleared": _outcomes([_coins(1)])})
	_described("golden_idol", "Golden Idol", [t, common], 3, null, "Worth 10 coins the moment you pick it up.",
		{"on_pickup": _outcomes([_coins(10)])})
	var stew := ApplyPartyEffect.new()
	stew.effect = _r["effects/stew_heal"]
	_described("hearty_stew", "Hearty Stew", [t, s, common], 6, null, "At the start of each floor the living party heals 30% of max HP.",
		{"on_floor_start": _outcomes([stew])})
	var surprise := GiveItem.new()
	surprise.item_query = _query([t])
	_described("mystery_box", "Mystery Box", [s, rare], 7, null, "Opens into a random Treasure item.",
		{"on_pickup": _outcomes([surprise, RemoveItem.new()])})


func _described(name: String, title: String, tags: Array, price: int, grants: AbilitySet, description: String,
		extra: Dictionary = {}) -> void:
	_item(name, title, tags, price, grants, extra.merged({"description": description}))


func _usable(name: String, title: String, tags: Array, price: int, ability: String, mode: ItemDefinition.UseMode,
		battles: int, description: String) -> void:
	_described(name, title, tags, price, null, description, {"kind": ItemDefinition.Kind.USABLE,
		"use_ability": _r["abilities/" + ability], "use_mode": mode, "cooldown_battles": battles})


func _coins(amount: int) -> GainCoins:
	var outcome := GainCoins.new()
	outcome.amount = amount
	return outcome


func _outcomes(list: Array) -> Array[RunOutcome]:
	var typed: Array[RunOutcome] = []
	typed.assign(list)
	return typed


# --- Armor -------------------------------------------------------------------------------------------------------------

func _armor() -> void:
	var common := &"Item.Rarity.Common"
	var rare := &"Item.Rarity.Rare"
	var t := &"Pool.Treasure"
	var s := &"Pool.Shop"
	var b := &"Pool.Boss"
	_piece("leather_cap", "Leather Cap", "Head", [t, s, common], 5, _ability_set([], ["leather_cap"]), "+20 DEF, +100 max HP.")
	_piece("seers_circlet", "Seer's Circlet", "Head", [t, s, rare], 8, _ability_set([], ["seers_circlet"]), "+5% crit rate, +20 max MP.")
	_piece("chain_vest", "Chain Vest", "Body", [t, s, common], 6, _ability_set([], ["chain_vest"]), "+60 DEF.")
	_piece("mage_robe", "Mage Robe", "Body", [t, s, common], 6, _ability_set([], ["mage_robe"]), "+50 max MP, +5% ATK.")
	_piece("bracers", "Bracers", "Arms", [t, s, common], 6, _ability_set([], ["bracers"]), "+8% ATK.")
	_piece("hunters_gloves", "Hunter's Gloves", "Arms", [t, rare], 8, _ability_set(["hunters_gloves"], []), "Hitting a weakness gives +10 ult charge.")
	_piece("swift_boots", "Swift Boots", "Legs", [t, s, common], 6, _ability_set([], ["swift_boots"]), "+10 SPD.")
	_piece("greaves", "Greaves", "Legs", [t, s, common], 5, _ability_set([], ["greaves"]), "+50 DEF, but −4 SPD.")
	_piece("duelists_band", "Duelist's Band", "Accessory", [t, b, rare], 10, _ability_set(["duelists_band"], []), "Critical hits trigger a follow-up: 30% ATK Physical.")
	_piece("ember_pendant", "Ember Pendant", "Accessory", [t, b, rare], 10, _ability_set(["ember_pendant"], []), "Fire damage makes the target weak to Fire for 1 turn.")


func _piece(name: String, title: String, slot: String, tags: Array, price: int, grants: AbilitySet, description: String) -> void:
	var piece := EquipmentDefinition.new()
	piece.id = StringName("demo.equipment." + name)
	piece.display_name = title
	piece.description = description
	piece.slot = StringName("Equipment.Slot." + slot)
	piece.tags.assign(tags)
	piece.price = price
	piece.grants = grants
	_save("equipment/" + name, piece)
