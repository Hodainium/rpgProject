## AbilityName: what the screens call an ability (GodotGAS ability_name, else the scene file's name, else the tag),
## on fixture abilities; the field options and the ult message carry it.
extends TestCase

const PARTY: Array = ["fixture.character.knight", "fixture.character.medic"]

var _nodes: Array[Node] = []


func after_each() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.free()
	_nodes.clear()
	super()


func test_ability_name_sources() -> void:
	var ability: GameplayAbility = load("res://tests/fixtures/abilities/ult_purify.tscn").instantiate()
	_nodes.append(ability)
	eq(AbilityName.of(ability), "Ult Purify", "no ability_name: the scene file's name, words split")
	ability.ability_name = "Cleansing Light"
	eq(AbilityName.of(ability), "Cleansing Light", "ability_name wins when set")
	var bare := BattleAbility.new()
	_nodes.append(bare)
	bare.ability_tag = &"Fixture.Ability.Plain"
	eq(AbilityName.of(bare), "Plain", "no scene: the tag's last segment")
	eq(AbilityName.of(null), "?", "nothing: a question mark")


func test_ability_name_in_field_options_and_messages() -> void:
	var run := TestCase.start_run(host, "7", PARTY)
	_nodes.append(run)
	var options := run.field_options()
	check(not options.is_empty(), "the fixture party has field options")
	for option in options:
		check(option.has("name") and option["name"] != "" and not String(option["name"]).contains("."),
			"a field option carries a readable name: %s" % [option])
	var battle := new_battle(preload("res://tests/combat/test_ult_interrupts.gd").ult_snapshot())
	var ultist := battle.units().filter(func(unit: BattleUnit) -> bool: return unit.is_party())[0] as BattleUnit
	var ult: BattleAbility = ultist.ultimate_abilities()[0]
	eq(AbilityName.of_tag(ultist, ult.ability_tag), AbilityName.of(ult), "by tag on a unit that has it")
	check(not AbilityName.of(ult).contains("."), "an ult's name is readable: " + AbilityName.of(ult))
	eq(AbilityName.of_tag(ultist, &"Fixture.Ability.Missing"), "Missing", "a tag the unit lacks: its last segment")
