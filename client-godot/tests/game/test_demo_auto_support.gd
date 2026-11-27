## Content test for spec auto-support 6: on the real demo content, Auto heals the party with a party heal when three allies
## are hurt (not the single Heal), a level-30 Bard opens a boss fight with a party anthem, and RestoreReader reads what the
## content's two heal ExecCalcs really restore (heal_mult and heal_taken included). By direction only, never by the tuned
## number. Skipped without the demo.
extends TestCase

const DEMO: String = "res://content/demo/"

static var _demo: ContentIndex


static func _content_index() -> ContentIndex:
	if _demo == null:
		_demo = ContentIndex.new("res://content/")
	return _demo


func _ready_to_test() -> bool:
	if ResourceLoader.exists(DEMO + "characters/cleric.tres") and ResourceLoader.exists(DEMO + "encounters/golem.tres"):
		return true
	print("    skipped: no demo content under ", DEMO)
	return false


## `classes` at `level` (P1 first) against the Golem, with no ult charge and full SP.
func _battle(classes: Array, level: int = 30) -> Battle:
	var party: Array = []
	for index in classes.size():
		party.append({"slot": index + 1, "unitDefId": "demo.character." + classes[index], "level": level, "energy": 0,
			"skills": [], "equipmentIds": [], "items": [], "useSlots": []})
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	var error := battle.setup({"schemaVersion": 2, "battleId": "demo-auto-support", "seed": "5",
		"encounterId": "demo.encounter.golem", "party": party}, _content_index())
	check(error == "", "demo battle setup: " + error)
	for unit in battle.units():
		if unit.is_party() and unit.asc.has_attribute(BattleUnit.MAX_MP):
			_set_stat(unit, BattleUnit.MP, unit.stat(BattleUnit.MAX_MP))
	return battle


static func _set_stat(unit: BattleUnit, attribute: String, value: int) -> void:
	unit.asc.initialize_attribute_overrides({attribute: float(value)} as Dictionary[String, float])


@warning_ignore("integer_division")
static func _hurt_to(unit: BattleUnit, percent: int) -> void:
	_set_stat(unit, BattleUnit.HP, unit.stat(BattleUnit.MAX_HP) * percent / 100)


static func _policy() -> AutoPolicy:
	return AutoPolicy.new(AutoPolicy.Options.new(), _content_index())


func test_a_cleric_heals_three_hurt_allies_with_a_party_heal() -> void:
	if not _ready_to_test():
		return
	var battle := _battle(["cleric", "warrior", "bard", "ranger"])
	for id in [&"P2", &"P3", &"P4"]:
		_hurt_to(battle.unit_by_id(id), 55)
	var cleric := battle.unit_by_id(&"P1")
	var policy := _policy()
	var pick := policy.choose(battle, cleric)
	eq(policy.last_reason, "heal", "three allies under 70%%: a heal (%s)" % pick)
	var ability := cleric.ability_by_tag(pick.get("ability", &""))
	check(ability != null and ability.targeting == BattleAbility.Targeting.ALL_ALLIES,
		"a party heal (Mass Heal or Benediction), not a single heal: %s" % pick)
	check(pick.get("ability") != &"Ability.Heal", "never the first heal in grant order")


func test_a_bard_opens_a_boss_fight_with_a_party_anthem() -> void:
	if not _ready_to_test():
		return
	var battle := _battle(["bard", "warrior", "cleric"])
	var bard := battle.unit_by_id(&"P1")
	var policy := _policy()
	var pick := policy.choose(battle, bard)
	eq(policy.last_reason, "party buff", "the opening move is a party buff (%s)" % pick)
	var ability := bard.ability_by_tag(pick.get("ability", &""))
	check(ability != null and ability.targeting == BattleAbility.Targeting.ALL_ALLIES
		and ability.asset_tags.has(AutoPolicy.ROLE_BUFF), "an anthem for the whole party: %s" % pick)


## Mass Heal (ExecCalcRestore, a level-20 Cleric) and Benediction (ExecCalcPercentOfMax, then its Regen ticks; level 30, where
## it has replaced Mass Heal) restore on each ally what the reader says, with a raised heal_taken on one of them.
func test_restore_reader_reads_the_content_heals() -> void:
	if not _ready_to_test():
		return
	for case in [[20, &"Ability.Massheal"], [30, &"Ability.Benediction"]]:
		await _check_reader(case[0], case[1])


func _check_reader(level: int, tag: StringName) -> void:
	var battle := _battle(["cleric", "warrior", "bard", "ranger"], level)
	var cleric := battle.unit_by_id(&"P1")
	var warrior := battle.unit_by_id(&"P2")
	var taken := GameplayEffect.new()
	taken.policy = GameplayEffect.DurationPolicy.INFINITE
	var modifier := CombatModifier.new()
	modifier.attribute_name = "heal_taken"
	modifier.operation = GameplayEffectModifier.Operation.ADD
	modifier.value_x100 = 5000  # +50%
	taken.modifiers.append(modifier)
	warrior.asc.apply_gameplay_effect(taken, warrior.asc, 1)
	var ability := cleric.ability_by_tag(tag)
	check(ability != null, "the level-%d Cleric knows %s" % [level, tag])
	if ability == null:
		return
	var expected := {}
	var before := {}
	for unit in AutoPolicy._party(battle):
		_hurt_to(unit, 10)
		before[unit.unit_id] = unit.stat(BattleUnit.HP)
		expected[unit.unit_id] = RestoreReader.hp_restore(ability, cleric, unit)
	check(int(expected[&"P2"]) > 0, "%s restores something" % tag)
	_set_stat(cleric, BattleUnit.MP, cleric.stat(BattleUnit.MAX_MP))
	check(await battle._activate(cleric, ability, null), "%s casts" % tag)
	for unit in AutoPolicy._party(battle):
		unit.asc.turn_start()
		unit.asc.turn_start()
		unit.asc.turn_start()
	for unit in AutoPolicy._party(battle):
		eq(unit.stat(BattleUnit.HP) - int(before[unit.unit_id]), int(expected[unit.unit_id]),
			"%s on %s restores what the reader says" % [tag, unit.unit_id])
