## One-time builder for C6 (spec playable-demo 3.11): class growth effects, the Waystation rest stop, three healing
## events and four foods, written into res://content/demo/ through ResourceSaver like build_classes.
##
## Same rules as build_demo, whose helpers it reuses: it never overwrites, writes nowhere but content/demo/ and never
## touches an existing file. Hooking them up (each class's level_effect, the enemies' drops, The Descent's XP curve and
## rest event) is done by hand with your approval. Values are starting values; tune them in the files.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_progression.tscn
extends "res://game/tools/build_classes.gd"


func _ready() -> void:
	if not ResourceLoader.exists(GENERATED_SET) or load(PERCENT_OF_MAX) == null:
		_quit("Needs %s and %s (run --import once first)." % [GENERATED_SET, PERCENT_OF_MAX])
		return
	_attributes = load(ATTRIBUTES)
	_growth()
	_food()
	_events()
	print("build_progression: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _made:
		print("  made    ", path)
	for path in _skipped:
		print("  skipped ", path)
	for path in _failed:
		print("  FAILED  ", path)
	get_tree().quit(1 if not _failed.is_empty() else 0)


## Growth per level (FREE stacking: one stack per level above 1).
func _growth() -> void:
	_save("effects/growth_damage", _infinite({"max_hp": 6, "atk": 8, "def": 4}, true))
	_save("effects/growth_support", _infinite({"max_hp": 7, "atk": 6, "def": 5}, true))
	_save("effects/growth_tank", _infinite({"max_hp": 9, "atk": 4, "def": 7}, true))


## Instant: `typed`% of max MP restored.
func _mp_percent(typed: float) -> GameplayEffect:
	var effect := _percent_of_max(typed)
	effect.executions[0].set("attribute", "mp")
	effect.executions[0].set("max_attribute", "max_mp")
	return effect


func _food() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var food := &"Pool.Food"
	var consumable := ItemDefinition.UseMode.CONSUMABLE
	_save("effects/food_heal_15", _percent_of_max(15))
	_save("effects/food_heal_30", _percent_of_max(30))
	_save("effects/food_heal_25", _percent_of_max(25))
	_save("effects/food_mp_40", _mp_percent(40))
	for spec in [["rations", "Ability.Item.Rations", B.SINGLE_ALLY, "food_heal_15"],
			["roast_haunch", "Ability.Item.Roasthaunch", B.SINGLE_ALLY, "food_heal_30"],
			["honey_cake", "Ability.Item.Honeycake", B.SINGLE_ALLY, "food_mp_40"],
			["hearty_feast", "Ability.Item.Heartyfeast", B.ALL_ALLIES, "food_heal_25"]]:
		_ability(spec[0], spec[1], spec[2], [_row("eat", spec[3], D.USE_EFFECT, 0, T.ALL)], _jump(0.5), [[0.25, "eat"]],
			{"sound": ["Recovery5", 0.1, -6.0]})
	_usable("rations", "Rations", [food, COMMON], 2, "rations", consumable, 1, "One ally heals 15% of max HP.")
	_usable("roast_haunch", "Roast Haunch", [food, COMMON], 3, "roast_haunch", consumable, 1, "One ally heals 30% of max HP.")
	_usable("honey_cake", "Honey Cake", [food, COMMON], 3, "honey_cake", consumable, 1, "One ally regains 40% of max MP.")
	_usable("hearty_feast", "Hearty Feast", [food, RARE], 6, "hearty_feast", consumable, 1, "The party heals 25% of max HP.")


func _heal_party(name: String, percent: float, include_dead: bool) -> ApplyPartyEffect:
	var heal := ApplyPartyEffect.new()
	heal.effect = _save("effects/" + name, _percent_of_max(percent))
	heal.include_dead = include_dead
	return heal


func _events() -> void:
	# The rest stop between floors (spec 3.11 D29): rest, train, or move on.
	var restore_mp := ApplyPartyEffect.new()
	restore_mp.effect = _save("effects/waystation_mp", _mp_percent(50))
	var waystation := EventDefinition.new()
	waystation.id = &"demo.event.waystation"
	waystation.display_name = "Waystation"
	waystation.pages.assign([_page("A quiet waystation between floors. The lamps are warm.", [
		_choice("Rest (heal 50% HP and MP; the fallen get up)", [], [_heal_party("waystation_heal", 50, true), restore_mp]),
		_choice("Train (everyone gains a level)", [], [GainLevel.new()]),
		_choice("Move on", [], [])])])
	_save("events/waystation", waystation)
	# Healing events, drawn like any other (Event.Demo).
	var bathe_cost := CoinsAtLeast.new()
	bathe_cost.amount = 10
	var pay_ten := LoseCoins.new()
	pay_ten.amount = 10
	var spring := EventDefinition.new()
	spring.id = &"demo.event.healing_spring"
	spring.display_name = "Healing Spring"
	spring.tags.assign([&"Event.Demo"])
	spring.pages.assign([_page("Warm water bubbles up between the stones.", [
		_choice("Drink (heal 35%)", [], [_heal_party("spring_drink", 35, false)]),
		_choice("Bathe (10 coins: heal 70%)", [bathe_cost], [pay_ten, _heal_party("spring_bathe", 70, false)]),
		_choice("Leave", [], [])])])
	_save("events/healing_spring", spring)
	var medic_cost := CoinsAtLeast.new()
	medic_cost.amount = 15
	var pay_fifteen := LoseCoins.new()
	pay_fifteen.amount = 15
	var medic := EventDefinition.new()
	medic.id = &"demo.event.wandering_medic"
	medic.display_name = "Wandering Medic"
	medic.tags.assign([&"Event.Demo"])
	medic.pages.assign([_page("\"Fifteen coins and I'll patch up the lot of you, even the ones lying down.\"", [
		_choice("Pay 15 coins (full heal, the fallen get up)", [medic_cost], [pay_fifteen, _heal_party("medic_heal", 100, true)]),
		_choice("Decline", [], [])])])
	_save("events/wandering_medic", medic)
	var lesson := GainXp.new()
	lesson.amount = 40
	var purse := GainCoins.new()
	purse.amount = 10
	var tutor := EventDefinition.new()
	tutor.id = &"demo.event.old_tutor"
	tutor.display_name = "Old Tutor"
	tutor.tags.assign([&"Event.Demo"])
	tutor.pages.assign([_page("An old tutor offers a lesson, or a purse for listening.", [
		_choice("Take the lesson (everyone gains a level)", [], [GainLevel.new()]),
		_choice("Take the purse (40 XP each and 10 coins)", [], [lesson, purse]),
		_choice("Leave", [], [])])])
	_save("events/old_tutor", tutor)
