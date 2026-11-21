## Spec ui-feedback: feedback on the thing involved, no white message line. UIFlash (system) on its own; then, under the
## demo UI policy on fixture content (presentation, direction only), each refusal of 2.4 "New feedback": it carries the
## right `target` and its extras, and the screen that owns that widget flashes it. The dialogs of rows 22-24, the dev log
## of rows 26-27 and the refused sound.
extends TestCase

const FakeBridge = preload("res://tests/game/test_server_mode.gd").FakeBridge
const PARTY: String = "fixture.character.knight,fixture.character.medic"
const TREASURE: StringName = &"Fixture.Room.Type.Treasure"

var _games: Array[GameMain] = []
var _nodes: Array[Node] = []
var _handles: Array[GameplayMessageHandle] = []


func after_each() -> void:
	for handle in _handles:
		handle.unregister()
	_handles.clear()
	for node in _nodes + _games:
		if is_instance_valid(node):
			node.free()
	_games.clear()
	_nodes.clear()
	super()


func _frames(count: int) -> void:
	for i in count:
		await host.get_tree().process_frame


func _shell() -> GameMain:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	_games.append(game)
	return game


func _console(game: GameMain) -> DevConsole:
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)  # built-ins only: user://dev_commands/ is shared with parallel shards
	console.attach(game)
	console.auto_battle = false
	return console


## The demo UI on the plain fixture run.
func _game(party: String = PARTY) -> GameMain:
	var game := _shell()
	game.content_root = FIXTURES
	game.load_content()
	await _console(game).execute("new %s 7" % party)
	await _frames(3)
	return game


## The demo UI on the keyed fixture run (tests/game/keys_world.gd).
func _keyed_game() -> GameMain:
	var game := _shell()
	game.content = KeysWorld.content()
	eq(game.start_run(["fixture.character.knight", "fixture.character.medic"], "7", KeysWorld.RUN_ID), "",
		"the keyed run starts")
	await _frames(3)
	return game


func _find(game: GameMain, node_name: String) -> Node:
	var found := game.find_child(node_name, true, false)
	return found if found != null and (not found is CanvasItem or found.is_visible_in_tree()) else null


func _refused() -> Array:
	var heard: Array = []
	_handles.append(GameplayMessages.listen(GameplayMessageRouter.UI_REFUSED, func(_channel, message: VerbMessage):
		heard.append(message.data), GameplayMessageRouter.Match.EXACT, VerbMessage))
	return heard


func _rows(list: Node) -> Array:
	return UIFlash.entries(list).filter(func(row) -> bool: return row.visible)


## The notices (one-button dialogs) open on the Modal layer, top first.
func _notices(game: GameMain) -> Array:
	var stack: UILayerStack = game.ui._stacks.get(&"UI.Layer.Modal")
	var found: Array = []
	if stack != null:
		for screen in stack.screens():
			if screen is UIConfirm and screen.is_notice():
				found.append(screen.get_node("%Text").text)
	return found


# --- UIFlash (system) -----------------------------------------------------------------------------------------------

func test_flash_ends_where_it_started() -> void:
	var control := Control.new()
	host.add_child(control)
	_nodes.append(control)
	control.position = Vector2(40, 10)
	control.modulate = Color(1, 1, 1, 0.8)
	var tween := UIFlash.refuse(control)
	check(tween != null and UIFlash.flashing(control), "a control in the tree flashes")
	tween.custom_step(0.06)
	check(control.position != Vector2(40, 10), "it shakes")
	check(control.modulate.g < 1.0, "and turns red")
	check(is_equal_approx(control.modulate.a, 0.8), "keeping its own alpha")
	tween.custom_step(1.0)
	eq([control.position, control.modulate], [Vector2(40, 10), Color(1, 1, 1, 0.8)], "back to its position and colour")
	check(not UIFlash.flashing(control), "and done")
	var pulse := UIFlash.pulse(control)
	pulse.custom_step(0.06)
	eq(control.position, Vector2(40, 10), "a pulse never moves the control")
	pulse.custom_step(1.0)
	check(UIFlash.refuse(null) == null, "nothing for no control")


func test_flash_restarts_and_survives_a_freed_control() -> void:
	var control := Control.new()
	host.add_child(control)
	_nodes.append(control)
	control.position = Vector2(5, 5)
	var first := UIFlash.refuse(control)
	first.custom_step(0.1)
	var second := UIFlash.refuse(control)
	check(not first.is_valid() or not first.is_running(), "a second refusal ends the first")
	second.custom_step(0.06)
	second.custom_step(1.0)
	eq([control.position, control.modulate], [Vector2(5, 5), Color.WHITE], "it ends at the original position and colour")
	var doomed := Control.new()
	host.add_child(doomed)
	UIFlash.refuse(doomed).custom_step(0.05)
	doomed.free()  # mid-flash: the tween goes with it, no error
	await _frames(2)


func test_listen_only_while_visible() -> void:
	var owner := Control.new()
	var part := Control.new()
	owner.add_child(part)
	host.add_child(owner)
	_nodes.append(owner)
	UIFlash.listen(owner, func(data: Dictionary) -> Array: return [part] if data.get("target") == "mine" else [])
	GameplayMessages.broadcast(GameplayMessageRouter.UI_REFUSED, VerbMessage.make(&"Verb.Refuse", &"", &"", 0, [],
		{"target": "other"}))
	check(not UIFlash.flashing(part), "a refusal about something else flashes nothing")
	owner.visible = false
	GameplayMessages.broadcast(GameplayMessageRouter.UI_REFUSED, VerbMessage.make(&"Verb.Refuse", &"", &"", 0, [],
		{"target": "mine"}))
	check(not UIFlash.flashing(part), "a hidden owner flashes nothing (its screen is not open)")
	owner.visible = true
	GameplayMessages.broadcast(GameplayMessageRouter.UI_REFUSED, VerbMessage.make(&"Verb.Refuse", &"", &"", 0, [],
		{"target": "mine"}))
	check(UIFlash.flashing(part), "a visible owner flashes its own part")


func test_theme_has_the_flash() -> void:
	var theme: Theme = load("res://presentation/demo/ui/ui_theme.tres")
	check(theme.has_constant(&"flash_ms", UIFlash.THEME_TYPE) and theme.has_constant(&"shake_px", UIFlash.THEME_TYPE)
		and theme.has_color(&"refuse", UIFlash.THEME_TYPE), "the UIFlash theme type (flash_ms, shake_px, refuse)")


# --- No message line --------------------------------------------------------------------------------------------------

func test_no_message_line() -> void:
	var policy: UIPolicy = load(GameMain.UI_POLICY)
	check(policy.extensions.all(func(extension) -> bool: return extension.slot != &"UI.Slot.Footer"),
		"nothing in the footer slot")
	check(not ResourceLoader.exists("res://presentation/demo/ui/message_line.tscn"), "the message line is gone")
	var before := GameplayMessages.listener_count(GameplayMessageRouter.NOTIFICATION)
	var game := await _game()
	eq(GameplayMessages.listener_count(GameplayMessageRouter.NOTIFICATION), before, "nothing on screen listens to the line")
	game.show_message("a line nobody should see")
	game.refuse("a refusal nobody should read")
	await _frames(1)
	var labels := game.ui.layout.find_children("*", "Label", true, false)
	check(labels.all(func(label: Label) -> bool: return not label.text.contains("nobody should")), "nothing writes it on screen")


## Rows 26-27 and the debug log: show_message and refuse reach the dev console's log (tests run a debug build).
func test_lines_go_to_the_dev_log() -> void:
	var dev := host.get_node_or_null("/root/Dev")
	check(dev != null and dev.console != null, "the Dev autoload has a console")
	if dev == null:
		return
	var game := _shell()
	game.show_message("Content problems in res://nowhere/: x")
	game.refuse("not enough coins", &"", UIRefusal.make(UIRefusal.GOLD, {"placement": 3}))
	var log: Array[String] = dev.console.player_log
	eq(log.slice(log.size() - 2), ["Content problems in res://nowhere/: x", "refused: not enough coins [gold]"],
		"both lines are in the dev log")
	eq(game.last_refusal["data"], {"target": "gold", "placement": 3}, "the last refusal is kept for `ui refused`")


func test_refused_sound_still_plays() -> void:
	var game := await _game()
	var board := host.get_tree().get_first_node_in_group("sound_board")
	check(board != null, "the sound board is up")
	if board == null:
		return
	var played: Array = []
	var probe := func(_channel, _message): played.append("heard")
	_handles.append(GameplayMessages.listen(GameplayMessageRouter.UI_REFUSED, probe, GameplayMessageRouter.Match.EXACT))
	game.refuse("no", &"", {})
	eq(played.size(), 1, "a refusal with no target is still broadcast")
	check(GameplayMessages.listener_count(GameplayMessageRouter.UI_REFUSED) >= 2, "and the sound board listens to it")


# --- The map (rows 1, 2, 10) ------------------------------------------------------------------------------------------

func test_room_out_of_reach_flashes_its_tile() -> void:
	var game := await _game()
	var heard := _refused()
	var big = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/big_map.tscn"))
	await _frames(2)
	var far := -1
	for cell in MapCells.of(game.run):
		if not cell["enterable"] and not cell["here"] and game.run.state.map.cells.has(cell["index"]):
			far = cell["index"]
			break
	check(far >= 0, "a room out of reach")
	big._travel(far)
	eq(heard[-1].get("target"), "room", "row 1: the room is named")
	eq(heard[-1].get("cell"), far, "with its cell")
	check(UIFlash.flashing(UIFlash.entry(big.get_node("%Grid"), far)), "and its tile flashes on the big map")
	check(_find(game, "BigMap") != null, "the map stays open")


func test_locked_room_flashes_lock_and_keys() -> void:
	var game := await _keyed_game()
	var run := game.run
	var vault := KeysWorld.special(run, TREASURE)
	run.state.map.cells[run.state.map.neighbours(vault)[0]]["visited"] = true
	var heard := _refused()
	var big = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/big_map.tscn"))
	await _frames(2)
	big._travel(vault)
	eq([heard[-1].get("target"), heard[-1].get("cell"), heard[-1].get("text")], ["lock", vault, "Locked: you need a key"],
		"row 2: the lock")
	check(UIFlash.flashing(UIFlash.entry(big.get_node("%Grid"), vault)), "the locked tile flashes, the map stays open")
	eq(run.state.current_cell != vault, true, "and the party stays")


func test_waiting_gift_shakes_the_give_to_panel() -> void:
	var game := await _game()
	var run := game.run
	var gift := GiveItem.new()
	gift.item = run.content.items[&"fixture.item.whetstone"]
	gift.recipient = GiveItem.Recipient.CHOOSE
	gift.apply(run)
	await _frames(3)
	var panel := _find(game, "GiftPanel")
	check(panel != null, "the Give to panel shows")
	if panel == null:
		return
	var heard := _refused()
	var big = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/big_map.tscn"))
	await _frames(2)
	var target := -1
	for cell in MapCells.of(run):
		if cell["enterable"] and not cell["here"]:
			target = cell["index"]
			break
	big._travel(target)
	eq(heard[-1].get("target"), "gift", "row 10: the waiting gift is named")
	check(UIFlash.flashing(panel.get_node("Panel")), "the Give to window shakes")
	run.state.party[0]["alive"] = false
	panel._give(run.state.party[0]["slot"])
	eq([heard[-1].get("target"), heard[-1].get("slot")], ["member", run.state.party[0]["slot"]], "row 9: a dead member")
	check(UIFlash.flashing(UIFlash.entry(panel.get_node("%Members"), 0)), "that member's button flashes")


# --- Pickups and the counters (rows 2, 6, 7, 8, 9) ---------------------------------------------------------------------

func _shop_row(game: GameMain, pickup: Dictionary) -> Node:
	var run := game.run
	var cell: int = run.state.current_cell
	run.state.map.cells[cell]["pickups"].append(pickup)
	run.pickups_shown.emit(cell)
	await _frames(3)
	var panel := _find(game, "PickupPanel")
	if panel == null:
		return null
	for row in _rows(panel.get_node("%Rows")):
		if row._placement == pickup["placement"]:
			return row
	return null


func test_not_enough_gold_flashes_gold_and_price() -> void:
	var game := await _keyed_game()
	var heard := _refused()
	var row := await _shop_row(game, {"placement": 9, "item": FloorGenerator.KEYS_KIND, "price": 5, "taken": false,
		"kind": FloorGenerator.KEYS_KIND, "keys": 1})
	check(row != null, "a key for sale")
	if row == null:
		return
	row.get_node("%Take").pressed.emit()
	eq([heard[-1].get("target"), heard[-1].get("placement")], ["gold", 9], "row 6: gold, with the pickup")
	check(UIFlash.flashing(_find(game, "ExploreMenu").get_node("%Gold")), "the Gold counter pulses")
	check(UIFlash.flashing(row.get_node("%Name")), "and the row's price")


func test_too_many_keys_flashes_keys() -> void:
	var game := await _keyed_game()
	game.run.state.keys = RunStructure.MAX_KEYS
	var heard := _refused()
	var row := await _shop_row(game, {"placement": 9, "item": FloorGenerator.KEYS_KIND, "price": 0, "taken": false,
		"kind": FloorGenerator.KEYS_KIND, "keys": 1})
	row.get_node("%Take").pressed.emit()
	eq(heard[-1].get("target"), "keys", "row 7: keys")
	check(UIFlash.flashing(_find(game, "ExploreMenu").get_node("%Keys")), "the Keys counter pulses")


func test_locked_chest_flashes_open_and_keys() -> void:
	var game := await _keyed_game()
	var run := game.run
	run.give_chest(run.content.chests[&"fixture.chest.strongbox"])
	await _frames(3)
	var panel := _find(game, "PickupPanel")
	var row: Node = _rows(panel.get_node("%Rows"))[0]
	var heard := _refused()
	row._take()  # the button is greyed with no key; the flash is the safety net
	eq([heard[-1].get("target"), heard[-1].get("chest")], ["lock", run.state.chest_serial - 1], "row 2: the chest's lock")
	check(UIFlash.flashing(row.get_node("%Take")), "its Open button flashes")
	check(UIFlash.flashing(_find(game, "ExploreMenu").get_node("%Keys")), "and the Keys counter pulses")


func test_full_or_dead_member_flashes_the_member() -> void:
	var game := await _game()
	var run := game.run
	var usable: ItemDefinition = null
	for item in run.content.items.values():
		if item.is_usable():
			usable = item
			break
	check(usable != null, "a usable fixture item")
	if usable == null:
		return
	var member: Dictionary = run.state.party[0]
	var slot: int = member["slot"]
	var filler: Array = []
	for i in run.use_capacity(slot):
		filler.append({"item": usable.id})
	member["use_slots"] = filler
	var heard := _refused()
	var row := await _shop_row(game, {"placement": 12, "item": usable.id, "price": 0, "taken": false})
	check(row != null, "the item's row")
	if row == null:
		return
	row.get_node("%GiveTo").select(0)
	row.get_node("%Take").pressed.emit()
	eq([heard[-1].get("target"), heard[-1].get("slot")], ["member_items", slot], "row 8: that member's item slots")
	var strip := _find(game, "PartyStrip")
	check(strip != null and UIFlash.flashing(UIFlash.entry(strip.get_node("%Rows"), 0)), "their row on the party strip flashes")
	check(UIFlash.flashing(row.get_node("%GiveTo")), "and the row's member picker")
	member["alive"] = false
	row.get_node("%GiveTo").select(0)
	row.get_node("%Take").pressed.emit()
	eq(heard[-1].get("target"), "member", "row 9: a dead member: %s" % [heard.map(func(d): return d.get("text"))])


func test_pickup_panel_only_in_a_cleared_room() -> void:
	var game := await _game()
	var run := game.run
	var cell: int = run.state.current_cell
	run.state.map.cells[cell]["cleared"] = false
	run.state.map.cells[cell]["pickups"].append({"placement": 30, "item": &"fixture.item.whetstone", "price": 0,
		"taken": false})
	run.pickups_shown.emit(cell)
	await _frames(3)
	check(not UIState.compute("run", run).has(UIState.PICKUP), "rows 3, 4: an uncleared room has no pickup state")
	check(_find(game, "PickupPanel") == null, "so its rows are not shown at all")
	run.state.map.cells[cell]["cleared"] = true


# --- Gear and moves (rows 11, 12) ---------------------------------------------------------------------------------------

func _gear(game: GameMain, columns: Array) -> Node:
	var gear_set := GearSet.new()
	gear_set.title = "TEST"
	gear_set.columns.assign(columns)
	var screen = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/gear_screen.tscn"), {"set": gear_set})
	await _frames(2)
	return screen


func test_gear_slot_flashes() -> void:
	var game := await _game()
	var head := GearColumn.new()
	head.title = "HEAD"
	head.slot = &"Fixture.Equipment.Slot.Head"
	var items := GearColumn.new()  # a tag column beside a use-slot column (equipment.tres mixes them)
	items.title = "ITEM SLOT"
	items.use_slot = 1
	var screen := await _gear(game, [head, items])
	var heard := _refused()
	var first: int = game.run.state.party[0]["slot"]
	screen._select({"member": first, "column": head})
	screen._on_take_off()  # nothing on the head: refused
	eq([heard[-1].get("target"), heard[-1].get("slot"), heard[-1].get("equipment_slot")],
		["gear_slot", first, &"Fixture.Equipment.Slot.Head"], "row 11: that equipment slot")
	var mine: Array = screen._buttons.filter(func(entry) -> bool: return entry["member"] == first)
	check(UIFlash.flashing(mine[0]["button"]), "its button flashes")
	check(not UIFlash.flashing(mine[1]["button"]), "the item slot beside it does not")


func test_move_flashes_the_receivers_item_slots() -> void:
	var game := await _game()
	var items := GearColumn.new()
	items.title = "ITEM SLOT"
	items.use_slot = 1
	var screen := await _gear(game, [items])
	var second: int = game.run.state.party[1]["slot"]
	var first: int = game.run.state.party[0]["slot"]
	var data := UIRefusal.for_move(game.run, first, second, false)
	eq([data.get("target"), data.get("slots")], ["member_items", [second]], "row 12: a move names the receiver")
	eq(UIRefusal.for_move(game.run, first, second, true).get("slots"), [second, first], "a trade names both")
	game.refuse("would hold more items than item slots", &"", data)
	var button: Button = screen._buttons.filter(func(entry) -> bool: return entry["member"] == second)[0]["button"]
	check(UIFlash.flashing(button), "the receiver's item slot flashes")


# --- Use Ability (row 13) ----------------------------------------------------------------------------------------------

func test_field_use_flashes_sp_or_the_row() -> void:
	var game := await _game()
	var use = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/use_screen.tscn"), {"mode": "ability"})
	await _frames(2)
	var slot: int = game.run.state.party[0]["slot"]
	use._on_member(slot)
	await _frames(1)
	var short := UIRefusal.for_field_use(game.run, "IllegalAbility", slot, &"Fixture.Ability.Any", 100000, 0)
	eq([short.get("target"), short.get("slot")], ["sp", slot], "SP short: the SP bar")
	game.refuse("cannot activate now", &"", short)
	var row := UIFlash.entry(use.get_node("%Rows"), 0)
	check(UIFlash.flashing(row.get_node("%Mp")), "the member's SP bar pulses")
	var key: String = use._pool_keys[0]
	var ability := StringName(key.get_slice("/", 1))
	var other := UIRefusal.for_field_use(game.run, "IllegalAbility", slot, ability, 0, 0)
	eq(other.get("target"), "command", "enough SP: the ability's row, not the SP bar")
	game.refuse("cannot activate now", &"", other)
	check(UIFlash.flashing(UIFlash.entry(use.get_node("%Pool"), 0)), "the ability's row shakes")
	var bad := UIRefusal.for_field_use(game.run, "InvalidTarget", slot, ability, 0, game.run.state.party[1]["slot"])
	eq([bad.get("target"), bad.get("slot")], ["member", game.run.state.party[1]["slot"]], "a bad target: that member")


# --- Battle (rows 15, 16) ----------------------------------------------------------------------------------------------

func _battle() -> GameMain:
	var game := _shell()
	game.content_root = FIXTURES
	game.load_content()
	var console := _console(game)
	await console.execute("new fixture.character.chanter,fixture.character.knight 7")
	await console.execute("spawn fixture.encounter.ult_trial")
	for i in 300:
		if game.recorder != null and game.recorder.waiting_for != &"":
			break
		await _frames(1)
	await _frames(2)
	return game


func test_battle_refusals() -> void:
	var game := await _battle()
	check(game.recorder != null and game.recorder.waiting_for != &"", "a battle waits for the player")
	if game.recorder == null or game.recorder.waiting_for == &"":
		return
	var panel := _find(game, "CommandPanel")
	var party := _find(game, "BattlePartyPanel")
	var unit: BattleUnit = game.run.current_battle.unit_by_id(game.recorder.waiting_for)
	var costed: Array = unit.action_abilities().filter(func(ability) -> bool:
		return CostReader.sp_cost(ability, unit.asc) > 0 and not unit.item_abilities.has(ability.ability_tag))
	check(not costed.is_empty(), "the caster has a skill that costs SP")
	if costed.is_empty():
		return
	var skill: BattleAbility = costed[0]
	var heard := _refused()
	# Enough SP (or a control status): the skill's row only, never the SP bar.
	panel._tries[unit.unit_id] = {"ability": skill.ability_tag, "target": &""}
	panel._on_action_rejected(unit.unit_id, "IllegalAbility", "cannot activate now")
	var rich := unit.stat(BattleUnit.MP) >= CostReader.sp_cost(skill, unit.asc)
	eq(heard[-1].get("target"), "command" if rich else "sp", "row 15: by the caster's SP")
	# SP short: the caster's SP bar and the skill's row (the Ability row on the commands page).
	var mp := unit.asc.get_attribute(String(BattleUnit.MP))
	mp.base_value = 0.0
	mp.current_value = 0.0
	panel._on_action_rejected(unit.unit_id, "IllegalAbility", "cannot activate now")
	eq([heard[-1].get("target"), heard[-1].get("unit"), heard[-1].get("ability")], ["sp", unit.unit_id, skill.ability_tag],
		"SP short names the SP bar")
	var index := game.run.current_battle.units().filter(func(u: BattleUnit) -> bool: return u.is_party()).find(unit)
	check(UIFlash.flashing(UIFlash.entry(party.get_node("%Rows"), index).get_node("%Mp")), "the caster's SP bar pulses")
	check(UIFlash.flashing(UIFlash.entry(panel.get_node("%Entries"), panel._entry_keys.find("ability"))),
		"and the Ability row shakes")
	# A target the skill can't take, with the TARGET page open: that target's row.
	var targeted: Array = unit.action_abilities().filter(func(ability) -> bool: return ability.needs_target())
	if targeted.is_empty():
		return
	var target_id: StringName = game.run.current_battle.target_candidates(unit, targeted[0])[0].unit_id
	# The real order: the turn action is refused while nothing waits (the window is idle), then the battle asks again.
	panel._tries[unit.unit_id] = {"ability": targeted[0].ability_tag, "target": target_id}
	var waiting: StringName = game.recorder.waiting_for
	game.recorder.waiting_for = &""
	panel._set_page(panel.Page.IDLE)
	panel._on_action_rejected(unit.unit_id, "InvalidTarget", "not a valid target")
	game.recorder.waiting_for = waiting
	eq([heard[-1].get("target"), heard[-1].get("unit")], ["target", target_id], "row 16: the target")
	panel._on_action_requested(unit.unit_id, 0)
	eq(panel._page, panel.Page.TARGET, "the battle asks again: back on the skill's TARGET page")
	check(UIFlash.flashing(UIFlash.entry(panel.get_node("%Entries"), panel._entry_keys.find(target_id))),
		"and the refused target's row shakes")
	eq(UIRefusal.for_battle("ActorMismatch", unit, skill, &"").get("target"), "member", "not this unit's move: its row")


# --- Dialogs (rows 22, 23, 24) -----------------------------------------------------------------------------------------

func test_refused_server_start_is_a_dialog() -> void:
	var game := _shell()
	game.content_root = FIXTURES
	game.load_content()
	var bridge := FakeBridge.new()
	bridge.answers["StartRun"] = [[false, {"status": 409, "errorCode": 1001, "title": "Ruleset not accepted"}]]
	var link := ServerLink.new(bridge)
	link.player = "tester"
	link.saves_dir = "user://test_ui_feedback/saves_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	game.use_server(link)
	game.start_run(["fixture.character.knight"], "")
	for i in 60:
		if not _notices(game).is_empty():
			break
		await _frames(1)
	var notices := _notices(game)
	check(not notices.is_empty() and notices[0] == ServerLink.describe({"status": 409, "errorCode": 1001,
		"title": "Ruleset not accepted"}), "row 22: the error in plain words: %s" % [notices])
	bridge.answers["StartRun"] = [[false, {"status": 400, "errorCode": 1409, "title": "Character not unlocked"}]]
	for notice in game.ui._stacks[&"UI.Layer.Modal"].screens():
		notice.decided.emit(true)
	await _frames(2)
	game.start_run(["fixture.character.knight"], "")
	for i in 20:
		await _frames(1)
	eq(_notices(game), [], "a 1409 is the class pick's own line, no dialog")
	game.use_server(null)
	await _frames(1)


func test_leaving_a_verifying_win_is_a_dialog() -> void:
	var game := await _game()
	var link := ServerLink.new(FakeBridge.new())
	link.player = "tester"
	link.saves_dir = "user://test_ui_feedback/saves_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	game.use_server(link)
	game.run.state.status = RunState.WON
	game.back_to_menu()
	await _frames(1)
	eq(game.mode, "run", "the player stays in the run")
	eq(_notices(game), ["Your win is being verified. You can leave once it is."], "row 23: the dialog says why")
	game.run.state.status = RunState.ACTIVE
	game.use_server(null)
	await _frames(1)


func test_a_run_stopped_outside_the_run_still_says_so() -> void:
	var game := await _game()
	var run := game.run
	game.set_mode("menu")  # Save and quit while the server queue still drains
	run.stop_on_server_error("batch refused")
	await _frames(2)
	check(_notices(game).size() == 1 and _notices(game)[0].contains("batch refused"), "the dialog says it: %s" % [_notices(game)])


func test_runner_error_is_a_dialog_over_the_end_screen() -> void:
	var game := await _game()
	game.run.stop_on_server_error("the step runner fell over")
	await _frames(2)
	eq(game.mode, "end", "the run-end screen")
	check(_notices(game).size() == 1 and _notices(game)[0].contains("the step runner fell over"),
		"row 24: the error in a dialog over it: %s" % [_notices(game)])


# --- Console ----------------------------------------------------------------------------------------------------------

func test_console_ui_refused_and_flash() -> void:
	var game := await _game()
	var console := _console(game)
	eq((await console.execute("ui refused"))["text"], "no refusal yet", "nothing refused yet")
	game.refuse("not enough coins", &"", UIRefusal.make(UIRefusal.GOLD, {"placement": 4}))
	var text: String = (await console.execute("ui refused last"))["text"]
	eq(text, "not enough coins · target gold placement=4", "the last refusal's text and target")
	var flashed := await console.execute("ui flash Gold")
	check(flashed["ok"] and UIFlash.flashing(_find(game, "ExploreMenu").get_node("%Gold")), "ui flash plays it: " + flashed["text"])
	check(not (await console.execute("ui flash NoSuchNode"))["ok"], "an unknown control fails")


## Found at build time: the server link's rare notices (a 1108 rollback, a 1103 rebuild) are one-button dialogs.
func test_server_notice_is_a_dialog() -> void:
	var game := await _game()
	var link := ServerLink.new(FakeBridge.new())
	link.player = "tester"
	link.saves_dir = "user://test_ui_feedback/saves_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	game.use_server(link)
	link.notice.emit(link.rollback_text)
	await _frames(2)
	eq(_notices(game), [link.rollback_text], "the rollback says so in a dialog")
	game.use_server(null)
	await _frames(1)
