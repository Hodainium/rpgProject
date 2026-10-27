## Spec ff7-ui 6, stage 1 (system code): the window style, the toast system, the battle feed's messages, ability
## hints, member stats and the map's room-type rule. Fixtures and code-built resources only, never presentation/.
extends TestCase

var _nodes: Array[Node] = []
var _runs: Array[RunController] = []


func after_each() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.free()
	_nodes.clear()
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


func _rule(channel: StringName, title: String, extra: Dictionary = {}) -> UIToastRule:
	var rule := UIToastRule.new()
	rule.channel = channel
	rule.title = title
	for key in extra:
		if extra[key] is Array:
			rule.get(key).assign(extra[key])  # typed arrays: set() with an untyped one is ignored
		else:
			rule.set(key, extra[key])
	return rule


func _host(rules: Array, stack: int = UIToastSet.Stack.QUEUE, max_visible: int = 1, max_queued: int = 5,
		clear_on: Array = []) -> UIToastHost:
	var toast_set := UIToastSet.new()
	toast_set.clear_on.assign(clear_on)
	toast_set.rules.assign(rules)
	toast_set.stack = stack
	toast_set.max_visible = max_visible
	toast_set.max_queued = max_queued
	var toast_host := UIToastHost.new()
	toast_host.toast_set = toast_set
	host.add_child(toast_host)
	_nodes.append(toast_host)
	toast_host.start()
	return toast_host


static func _titles(toast_host: UIToastHost) -> Array:
	return toast_host.toasts().map(func(toast) -> String: return toast["title"])


func _verb(channel: StringName, verb: StringName, data: Dictionary = {}, amount: int = 0, tags: Array = []) -> void:
	GameplayMessages.broadcast(channel, VerbMessage.make(verb, &"P1", &"E1", amount, tags, data))


# --- Window style ---------------------------------------------------------------------------------------------------

func test_ui_window_style() -> void:
	var style := UIWindowStyle.new()
	eq(style.get_margin(SIDE_LEFT), 14.0, "content margin = border 2 + ring 2 + padding 10")
	style.padding = 4
	eq(style.get_margin(SIDE_TOP), 8.0, "and follows the padding")
	var rect := Rect2(0, 0, 100, 200)
	eq(style.gradient_color(rect, Vector2(50, 0)), style.top, "top colour at the top")
	eq(style.gradient_color(rect, Vector2(50, 110)), style.middle, "middle colour at middle_at")
	eq(style.gradient_color(rect, Vector2(50, 200)), style.bottom, "bottom colour at the bottom")
	style.horizontal = true
	eq(style.gradient_color(rect, Vector2(100, 0)), style.bottom, "horizontal: the bottom colour on the right")
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.size = Vector2(120, 60)
	host.add_child(panel)
	_nodes.append(panel)
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	check(true, "drawn in a frame without an error")


# --- Toasts ---------------------------------------------------------------------------------------------------------

func test_toast_format() -> void:
	var rule := _rule(&"Message.Test.Toast", "{instigator} did {amount} damage to {target}",
		{"kicker": "{abilityName}", "subtitle": "{missing}x"})
	var message := VerbMessage.make(&"Verb.Damage", &"P1", &"E2", 21250, [],
		{"instigatorName": "Warrior", "targetName": "Golem", "abilityName": "Ice Blast"})
	var toast := rule.format(message)
	eq(toast["title"], "Warrior did 212 damage to Golem", "names from the data, the amount ÷ 100")
	eq(toast["kicker"], "Ice Blast", "any data key is a field")
	eq(toast["subtitle"], "x", "an unknown field is empty")
	eq(UIToastRule.fill("Floor {count}", UIToastRule.fields_of(VerbMessage.make(&"Verb.Enter", &"", &"c", 3))),
		"Floor 3", "{count} is the raw magnitude")
	eq(UIToastRule.fill("{text}", UIToastRule.fields_of(NotificationMessage.make("hello"))), "hello",
		"a notification's line")
	eq(Array(UIToastRule.field_names("{a} and {b}")), ["a", "b"], "the fields a format names")


func test_toast_rules_match() -> void:
	var crit := _rule(&"Message.Test.Hit", "Critical hit!", {"require_tags": [&"Hit.Critical"]})
	var hit := _rule(&"Message.Test.Hit", "{instigator} hit", {"ignore_tags": [&"Ability.Type.Ultimate"]})
	var partial := _rule(&"Message.Test", "any {verb}", {"match_mode": GameplayMessageRouter.Match.PARTIAL,
		"verbs": [&"Verb.Break"]})
	var th := _host([crit, hit, partial], UIToastSet.Stack.STACK, 10)
	_verb(&"Message.Test.Hit", &"Verb.Damage", {"instigatorName": "Warrior"}, 100, [&"Hit.Critical"])
	eq(_titles(th), ["Critical hit!", "Warrior hit"], "both rules on the channel, in order; the tag filter passes")
	_verb(&"Message.Test.Hit", &"Verb.Damage", {"instigatorName": "Cleric"}, 100, [&"Ability.Type.Ultimate"])
	eq(_titles(th).size(), 2, "an ignored tag and a missing required tag: nothing new")
	_verb(&"Message.Test.Other", &"Verb.Break")
	_verb(&"Message.Test.Other", &"Verb.Damage")
	eq(_titles(th).back(), "any Break", "a partial rule hears a child channel, filtered by verb")
	eq(_titles(th).size(), 3, "the other verb is skipped")


func test_toast_stack_cap() -> void:
	var th := _host([_rule(&"Message.Test.Feed", "line {count}", {"seconds": 3.0})], UIToastSet.Stack.STACK, 4)
	for i in 10:
		_verb(&"Message.Test.Feed", &"Verb.Damage", {}, i)
	eq(_titles(th), ["line 6", "line 7", "line 8", "line 9"], "at most four lines, the oldest leave first")
	th.advance(3.5)
	eq(th.toasts().size(), 0, "each fades after its seconds")


func test_toast_queue_cap() -> void:
	var low := _rule(&"Message.Test.Low", "low {count}", {"seconds": 2.0})
	var high := _rule(&"Message.Test.High", "high", {"seconds": 2.0, "priority": 5})
	var th := _host([low, high], UIToastSet.Stack.QUEUE, 1, 3)
	_verb(&"Message.Test.Low", &"Verb.Take", {}, 0)
	eq(_titles(th), ["low 0"], "the first shows at once")
	_verb(&"Message.Test.High", &"Verb.Take")
	for i in range(1, 5):
		_verb(&"Message.Test.Low", &"Verb.Take", {}, i)
	eq(th.queued(), 3, "the queue keeps at most three")
	th.advance(2.1)
	eq(_titles(th), ["high"], "the high-priority toast survived the cap and comes next")
	th.advance(2.1)
	eq(_titles(th), ["low 3"], "then the newest low ones, the oldest were dropped")


func test_toast_hold() -> void:
	var floor_rule := _rule(&"Message.Test.Floor", "Floor {count}", {"hold_action": &"test_hold", "seconds": 1.0})
	var other := _rule(&"Message.Test.Item", "item", {"seconds": 1.0})
	var th := _host([floor_rule, other])
	var holds: Array = []
	th.hold_changed.connect(func(held: bool): holds.append(held))
	th.hold(&"test_hold", true)
	eq(th.toasts().size(), 0, "nothing to hold before the first floor message")
	_verb(&"Message.Test.Floor", &"Verb.Enter", {}, 3)
	th.advance(1.5)
	eq(th.toasts().size(), 1, "while held, the floor toast stays past its seconds")
	check(th.toasts()[0]["pinned"], "pinned")
	_verb(&"Message.Test.Item", &"Verb.Take")
	eq(th.queued(), 1, "a new toast waits while the hold is up")
	th.hold(&"test_hold", false)
	eq(_titles(th), ["item"], "released: the pinned toast goes and the waiting one shows")
	eq(holds, [true, false], "hold_changed tells the scene")


func test_toast_clear_on() -> void:
	var th := _host([_rule(&"Message.Test.Feed", "line", {"seconds": 9.0})], UIToastSet.Stack.STACK, 4, 5,
		[&"Message.Test.Reset"])
	_verb(&"Message.Test.Feed", &"Verb.Damage")
	_verb(&"Message.Test.Feed", &"Verb.Damage")
	eq(th.toasts().size(), 2, "two lines")
	_verb(&"Message.Test.Reset", &"Verb.Start")
	eq(th.toasts().size(), 0, "a clear_on channel empties the th")


# --- Battle feed messages -------------------------------------------------------------------------------------------

func test_battle_feed_lines() -> void:
	var snap: Dictionary = preload("res://tests/combat/test_item_pass_combat.gd").break_snapshot()
	var used := _rule(GameplayMessageRouter.BATTLE_ABILITY_USED, "{instigator} used {abilityName}",
		{"ignore_tags": [&"Ability.Type.Ultimate"], "seconds": 3.0})
	var crit := _rule(GameplayMessageRouter.BATTLE_DAMAGE, "Critical hit!", {"require_tags": [&"Hit.Critical"]})
	var damage := _rule(GameplayMessageRouter.BATTLE_DAMAGE, "{instigator} did {amount} damage to {target}")
	var broken := _rule(GameplayMessageRouter.BATTLE_BROKEN, "{target} is broken!")
	var feed := _host([used, crit, damage, broken], UIToastSet.Stack.STACK, 4)
	var shown: Array = []
	feed.toast_shown.connect(func(toast: Dictionary): shown.append(toast["title"]))
	var battle := new_battle(snap)
	BattleMessages.new().attach(battle, &"fixture.encounter.brittle_pair", GameplayMessages)
	await battle.run(ScriptedController.new())
	check(shown.size() > 0 and String(shown[0]).contains(" used "), "the first line is who used what")
	var first_damage := shown.find(shown.filter(func(line) -> bool: return String(line).contains(" damage to "))[0])
	check(first_damage > 0, "damage lines come after the ability that caused them")
	check(shown.any(func(line) -> bool: return String(line).ends_with(" is broken!")), "breaks have their line")
	check(feed.toasts().size() <= 4, "never more than four lines on screen")
	check(not shown.any(func(line) -> bool: return String(line).contains("{")), "every field was filled")


# --- Ability hints --------------------------------------------------------------------------------------------------

func _ability(targeting: int, attribute: String, cost_x100: int) -> BattleAbility:
	var ability := BattleAbility.new()
	ability.targeting = targeting
	ability.ability_name = "Probe"
	if attribute != "":
		var modifier := CombatModifier.new()
		modifier.attribute_name = attribute
		modifier.value_x100 = cost_x100
		var effect := GameplayEffect.new()
		effect.modifiers.append(modifier)
		ability.cost_effect = effect
	_nodes.append(ability)
	return ability


func test_ability_hint() -> void:
	var mp := AbilityHint.of(null, _ability(BattleAbility.Targeting.SINGLE_ENEMY, "mp", -1200))
	eq(mp["cost"], "12 MP", "an MP cost")
	eq(mp["target"], "ONE ENEMY", "who it targets")
	eq(mp["usage"], AbilityHint.USAGE_BATTLE, "an enemy target: battles only (until the usage tags)")
	eq(mp["description"], "", "no description: empty, never an error")
	var ult := AbilityHint.of(null, _ability(BattleAbility.Targeting.ALL_ENEMIES, "energy", -10000))
	eq(ult["cost"], "ULT 100%", "an ult cost")
	var heal := _ability(BattleAbility.Targeting.SINGLE_ALLY, "", 0)
	heal.description = "Restores HP to one ally."
	var hint := AbilityHint.of(null, heal)
	eq([hint["cost"], hint["target"], hint["usage"], hint["description"]],
		["", "ONE ALLY", AbilityHint.USAGE_BOTH, "Restores HP to one ally."], "no cost, an ally, field and battles")
	eq(AbilityHint.of(null, _ability(BattleAbility.Targeting.SINGLE_ENEMY, "mp", -1050))["cost"], "10.5 MP",
		"two decimals when there are some")


# --- Run reads ------------------------------------------------------------------------------------------------------

func test_member_stats() -> void:
	var run := start_run(host, "5")
	_runs.append(run)
	var log_size := run.run_log.size()
	var stats := run.member_stats(1)
	check(stats["current"].get("atk", 0) > 0, "current ATK read through GAS")
	eq(stats["level"], 1, "the member's level")
	var base_atk: int = stats["base"]["atk"]
	eq(run.dev_give(load(FIXTURES + "items/whetstone.tres"), 1), "", "give a whetstone (ATK)")
	var after := run.member_stats(1)
	eq(after["base"]["atk"], base_atk, "the base ignores items")
	check(after["current"]["atk"] != after["base"]["atk"], "the current value includes the whetstone")
	eq(run.member_stats(99), {}, "no such member: empty")
	eq(run.run_log.size(), log_size + 1, "reading stats logs nothing (only the give)")


func test_room_type_known() -> void:
	var run := start_run(host, "6")
	_runs.append(run)
	var map: FloorMap = run.state.map
	check(run.room_type_known(map.start), "the start room (visited)")
	var event_cell := -1
	var other_cell := -1
	for index in map.cells:
		var data: Dictionary = map.cells[index]
		if data["visited"]:
			continue
		if str(data["content"].get("kind", "")) == "event":
			event_cell = index
		elif other_cell < 0:
			other_cell = index
	check(other_cell >= 0 and run.room_type_known(other_cell), "an unvisited room that isn't an event: known")
	if event_cell >= 0:
		check(not run.room_type_known(event_cell), "an unvisited event room: unknown")
		run.state.revealed = true
		check(run.room_type_known(event_cell), "known once the map is revealed")
	check(not run.room_type_known(-5), "not a room: false")


# --- Validator rules (spec ff7-ui 3.4) ------------------------------------------------------------------------------

static func _codes(issues: Array) -> Array:
	return issues.map(func(issue: ValidationIssue) -> String: return issue.code)


func _scene_with(tags: Array) -> PackedScene:
	var ability := BattleAbility.new()
	ability.ability_tag = &"Ability.Probe"
	ability.asset_tags.assign(tags)
	var scene := PackedScene.new()
	scene.pack(ability)
	ability.free()
	return scene


func test_validator_basic_ability() -> void:
	var unit := CharacterDefinition.new()
	unit.id = &"probe.character"
	var validator := ContentValidator.new(fixtures())
	unit.abilities.assign([_scene_with([])])
	validator._check_basic(unit)
	eq(_codes(validator.issues), ["basic_ability_missing"], "no Basic ability: a warning (Attack is hidden)")
	validator.issues.clear()
	unit.abilities.assign([_scene_with([&"Ability.Type.Basic"]), _scene_with([&"Ability.Type.Basic"])])
	validator._check_basic(unit)
	eq(_codes(validator.issues), ["basic_ability_multiple"], "two Basic abilities: an error")
	eq(validator.issues[0].severity, ValidationIssue.ERROR, "an error")
	validator.issues.clear()
	unit.abilities.assign([_scene_with([&"Ability.Type.Basic"]), _scene_with([])])
	validator._check_basic(unit)
	eq(validator.issues.size(), 0, "exactly one: fine")


func test_validator_toast_rules() -> void:
	var toast_set := UIToastSet.new()
	toast_set.rules.assign([_rule(GameplayMessageRouter.BATTLE_DAMAGE, "{instigator} did {amount} to {target}"),
		_rule(&"Message.Battle", "{abilityName}", {"match_mode": GameplayMessageRouter.Match.PARTIAL}),
		_rule(&"Message.Nowhere", "x"),
		_rule(GameplayMessageRouter.BATTLE_BROKEN, "{nonsense} broke")])
	eq(_codes(UIPolicyCheck.check_toasts(toast_set, "probe")), ["toast_channel_unknown", "toast_format_field_unknown"],
		"an unknown channel and an unknown field; known ones and a partial parent channel pass")


func test_description_pass() -> void:
	var ability := _ability(BattleAbility.Targeting.SINGLE_ENEMY, "", 0)
	ability.asset_tags.assign([&"Ability.Role.Damage", &"Ability.Role.Debuff"])
	eq(DescriptionPass.text_of(ability), "Deals damage to one enemy. Weakens one enemy.", "a draft from roles and targeting")
	var path := "user://description_pass_probe.tscn"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("[gd_scene format=3]\n\n[node name=\"Probe\" type=\"Node\"]\nability_tag = &\"Ability.Probe\"\n")
	file.close()
	check(DescriptionPass.write_description(path, "Hits \"hard\"."), "written")
	check(FileAccess.get_file_as_string(path).contains("description = \"Hits \\\"hard\\\".\""), "as one quoted line")
	check(DescriptionPass.write_description(path, "Again."), "rewritten")
	var text := FileAccess.get_file_as_string(path)
	eq(text.count("description = "), 1, "replaced, never doubled")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
