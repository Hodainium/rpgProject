## Spec ff7-ui 6 (stage 4, presentation, direction only): the battle HUD under the demo UI policy on fixture content.
## The panels in each state (battle: party window, command window, hint window, turn order, feed; map: the map, not
## the turn order), the command window's pages (Ability list, Back, target, submit, the hint prompt) and the ULT
## chooser (a press opens the unit's ults; a pick queues the ult). The console's own auto stays off.
extends TestCase

const PARTY: String = "fixture.character.ultist,fixture.character.knight"

var _games: Array[GameMain] = []
var _handles: Array[GameplayMessageHandle] = []


func after_each() -> void:
	for handle in _handles:
		handle.unregister()
	_handles.clear()
	for game in _games:
		if is_instance_valid(game):
			game.free()
	_games.clear()
	super()


func _game() -> Array:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	_games.append(game)
	game.content_root = FIXTURES
	game.load_content()
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)  # built-ins only: user://dev_commands/ is shared with parallel shards
	console.attach(game)
	console.auto_battle = false
	return [game, console]


func _battle(game: GameMain, console: DevConsole, encounter: String) -> bool:
	if not (await console.execute("new %s 7" % PARTY))["ok"]:
		return false
	if not (await console.execute("spawn %s" % encounter))["ok"]:
		return false
	await _until(func() -> bool: return game.recorder != null and game.recorder.waiting_for != &"")
	await host.get_tree().process_frame
	return game.recorder != null and game.recorder.waiting_for != &""


static func _entries(panel: Node) -> Array:
	return panel.get_node("%Entries").get_children().filter(func(entry) -> bool: return entry.visible)


static func _entry(panel: Node, text: String) -> Button:
	for entry in _entries(panel):
		if str(entry.get_meta("ui_text", "")) == text:
			return entry
	return null


func test_battle_hud_policy() -> void:
	var made := _game()
	var game: GameMain = made[0]
	check(await _battle(game, made[1], "fixture.encounter.ult_trial"), "a battle waits for the player")
	for panel in ["BattlePartyPanel", "CommandPanel", "TopWindow", "TurnOrderPanel", "BattleFeed", "RunToasts"]:
		check(game.find_child(panel, true, false) != null, "in battle: %s" % panel)
	check(game.find_child("MapPanel", true, false) == null, "in battle the turn order replaces the map")
	var cards := game.find_child("TurnOrderPanel", true, false).get_node("%Cards")
	check(cards.get_child_count() >= 7, "seven upcoming turns or more (ults first)")
	var rows := game.find_child("BattlePartyPanel", true, false).get_node("%Rows")
	eq(rows.get_child_count(), 2, "one row per party member")
	game.auto_battle = true
	await _until(func() -> bool: return game.run.pending_battle.is_empty())
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	check(game.find_child("MapPanel", true, false) != null, "after the battle the map is back")
	check(game.find_child("TurnOrderPanel", true, false) == null, "and the turn order is gone")


## Spec ui-fixes B3: a clicked room starts its battle before the deferred UI state adds the panels. A panel made after
## battle_started takes the running battle (RunController.current_battle) and draws it.
func test_panels_made_after_battle_started() -> void:
	var made := _game()
	var game: GameMain = made[0]
	check(await _battle(game, made[1], "fixture.encounter.ult_trial"), "a battle waits for the player")
	check(game.run.current_battle != null, "the run exposes the battle being fought")
	var late: Array[Node] = []
	for path in ["res://presentation/demo/ui/battle_party_panel.tscn", "res://presentation/demo/ui/turn_order_panel.tscn"]:
		var panel: UIScreen = load(path).instantiate()
		host.add_child(panel)
		late.append(panel)
		panel._ui_bind(game.ui.context)
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	eq(late[0].get_node("%Rows").get_child_count(), 2, "a late party window still has one row per member")
	check(late[1].get_node("%Cards").get_child_count() >= 7, "a late turn order still shows the turns")
	for panel in late:
		panel.free()
	game.auto_battle = true
	await _until(func() -> bool: return game.run.pending_battle.is_empty())
	check(game.run.current_battle == null, "and none once the battle is over")


func test_command_panel_pages() -> void:
	var made := _game()
	var game: GameMain = made[0]
	check(await _battle(game, made[1], "fixture.encounter.ult_trial"), "a battle waits for the player")
	var panel := game.find_child("CommandPanel", true, false)
	var hints: Array = []
	_handles.append(GameplayMessages.listen(GameplayMessageRouter.UI_HINT, func(_channel, message: VerbMessage):
		hints.append(message.data)))
	var ability := _entry(panel, "Ability")
	check(ability != null, "COMMANDS lists Ability")
	check(_entry(panel, "Attack") == null, "no Ability.Type.Basic ability: Attack is hidden")
	ability.pressed.emit()
	check(panel.get_node("%Title").text.begins_with("ABILITY"), "Ability opens the list in the same window")
	check(panel.get_node("%Back").visible, "with Back")
	check(panel.handles_back(), "Esc steps back a page")
	check(_entry(panel, "Ability") != null, "back on COMMANDS")
	_entry(panel, "Ability").pressed.emit()
	var picks := _entries(panel)
	check(not picks.is_empty(), "the unit's abilities are listed")
	var before: int = game.recorder.entries.size()
	picks[0].pressed.emit()
	if panel.get_node("%Title").text.begins_with("TARGET"):
		check(hints.any(func(data) -> bool: return data.has("prompt")), "the target page sends its prompt")
		_entries(panel)[0].pressed.emit()
	await _until(func() -> bool: return game.recorder.entries.size() > before)
	check(game.recorder.entries.size() > before, "the pick reached the recorder")


func test_ult_chooser() -> void:
	var made := _game()
	var game: GameMain = made[0]
	check(await _battle(game, made[1], "fixture.encounter.ult_trial"), "a battle waits for the player")
	var panel := game.find_child("CommandPanel", true, false)
	var battle: Battle = panel.battle
	var ultist := battle.unit_by_id(&"P1")
	var charge := GameplayEffect.new()
	var modifier := CombatModifier.new()
	modifier.attribute_name = BattleUnit.ENERGY
	modifier.value_x100 = 100000
	charge.modifiers.append(modifier)
	ultist.asc.apply_gameplay_effect(charge)
	check(ultist.ultimate_abilities().any(func(ult) -> bool: return ultist.asc.can_activate_ability(ult)),
		"the ultist's ult charge is full")
	GameplayMessages.broadcast(GameplayMessageRouter.UI_ULT_PRESSED, VerbMessage.make(&"Verb.Press", &"P1", &""))
	check(panel.get_node("%Title").text.begins_with("ULT"), "a unit with several ults: the chooser opens")
	var choices := _entries(panel).filter(func(entry) -> bool: return not entry.disabled)
	check(not choices.is_empty(), "with the ults it can cast")
	if choices.is_empty():
		return
	choices[0].pressed.emit()
	if panel.get_node("%Title").text.begins_with("TARGET"):
		_entries(panel)[0].pressed.emit()
	await _until(func() -> bool:
		return game.recorder.pending_interrupts() > 0 or game.recorder.entries.any(
			func(entry) -> bool: return entry.get("interrupt", false)))
	check(game.recorder.pending_interrupts() > 0 or game.recorder.entries.any(
		func(entry) -> bool: return entry.get("interrupt", false)), "the pick queued the ult (or it already fired)")


## Waits up to 3000 frames for `done`.
func _until(done: Callable) -> void:
	for frame in 3000:
		if done.call():
			return
		await host.get_tree().process_frame
