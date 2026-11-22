## Spec ff7-ui 6 (stage 5): the exploration HUD. MapCells (system, fixtures): what each map cell shows. Then, under the
## demo UI policy on fixture content (presentation, direction only): the party strip, the menu and the map on the map;
## a menu screen hides them (UI.State.Run.Menu) and Back brings them back; the minimap never travels, the big map does
## (and a drag is never a click); the gear screen's EQUIP, SWAP (one logged swap_gear) and TAKE OFF and the item move;
## Use Ability and Status on the menu frame. Keys and chests (spec keys-and-gear) on the keyed run: the Keys line, the
## Use Item chest list, the pickup panel's key row and the key and chest toasts.
extends TestCase

const PARTY: String = "fixture.character.knight,fixture.character.medic"

var _games: Array[GameMain] = []
var _runs: Array[RunController] = []


func after_each() -> void:
	for game in _games:
		if is_instance_valid(game):
			game.free()
	_games.clear()
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


func _game() -> GameMain:
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
	await console.execute("new %s 7" % PARTY)
	await _frames(3)
	return game


func _frames(count: int) -> void:
	for i in count:
		await host.get_tree().process_frame


func _find(game: GameMain, node_name: String) -> Node:
	var found := game.find_child(node_name, true, false)
	return found if found != null and (not found is CanvasItem or found.is_visible_in_tree()) else null  # hidden = kept for later


# --- MapCells (system) ----------------------------------------------------------------------------------------------

func test_map_views() -> void:
	var run := start_run(host, "6")
	_runs.append(run)
	var cells := MapCells.of(run)
	var map: FloorMap = run.state.map
	eq(cells.size(), map.size.x * map.size.y, "one entry per grid cell")
	var here: Array = cells.filter(func(cell) -> bool: return cell["here"])
	eq(here.size(), 1, "exactly one room is yours")
	eq(here[0]["index"], run.state.current_cell, "the current room")
	for cell in cells:
		if not cell["shown"]:
			continue
		var index: int = cell["index"]
		var touching: bool = map.cells[index]["visited"] or map.neighbours(index).any(
			func(n: int) -> bool: return map.cells[n]["visited"])
		check(touching, "a shown room is visited or touches a visited one (%d)" % index)
		if str(map.cells[index]["content"].get("kind", "")) == "event" and not map.cells[index]["visited"]:
			eq(cell["kind"], "", "an unvisited event room shows no type")
	run.state.revealed = true
	check(MapCells.of(run).all(func(cell) -> bool:
		return cell["shown"] or not map.cells.has(cell["index"])), "revealed: every room is shown")


# --- Presentation (direction only) ----------------------------------------------------------------------------------

func test_explore_hud_policy() -> void:
	var game := await _game()
	for panel in ["PartyStrip", "ExploreMenu", "MapPanel", "RunToasts"]:
		check(_find(game, panel) != null, "on the map: %s" % panel)
	check(_find(game, "BattlePartyPanel") == null and _find(game, "TurnOrderPanel") == null, "no battle panels")
	game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/status_screen.tscn"))
	await _frames(2)
	check(game.ui.context.has_state(UIState.MENU_OPEN), "a menu screen sets UI.State.Run.Menu")
	check(_find(game, "MapPanel") == null and _find(game, "PartyStrip") == null and _find(game, "ExploreMenu") == null,
		"the map, the party strip and the menu hide behind it")
	check(_find(game, "StatusScreen") != null, "the Status screen is up")
	game.ui.back()
	await _frames(2)
	check(not game.ui.context.has_state(UIState.MENU_OPEN), "Back closes it")
	check(_find(game, "MapPanel") != null and _find(game, "PartyStrip") != null, "and the HUD comes back")


func test_minimap_opens_big_map_and_big_map_travels() -> void:
	var game := await _game()
	var run := game.run
	var start := run.state.current_cell
	var cells := _find(game, "MapPanel").get_node("%Cells")
	var room: Button = cells.get_children().filter(func(cell) -> bool: return not cell.disabled)[0]
	room.pressed.emit()
	await _frames(2)
	eq(run.state.current_cell, start, "the minimap never moves the party")
	var big := _find(game, "BigMap")
	check(big != null, "a click on the minimap opens the big map")
	if big == null:
		return
	var target := -1
	for cell in MapCells.of(run):
		if cell["enterable"] and not cell["here"]:
			target = cell["index"]
			break
	check(target >= 0, "a room the party can reach")
	big._dragged = true
	big._travel(target)
	eq(run.state.current_cell, start, "the end of a drag is never a click")
	big._dragged = false
	big._travel(target)
	await _frames(2)
	eq(run.state.current_cell, target, "a click on a reachable room travels there (enter_room)")
	check(_find(game, "BigMap") == null, "and the big map closes")


func test_gear_swap_composed() -> void:
	var game := await _game()
	var run := game.run
	var head: StringName = &"Fixture.Equipment.Slot.Head"
	run.give_equipment(run.content.equipment[&"fixture.equipment.helm"])
	var gear_set := GearSet.new()
	gear_set.title = "ARMOR"
	var column := GearColumn.new()
	column.title = "HEAD"
	column.slot = head
	gear_set.columns.assign([column])
	var screen = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/gear_screen.tscn"),
		{"set": gear_set})
	await _frames(2)
	var first: int = run.state.party[0]["slot"]
	var second: int = run.state.party[1]["slot"]
	var start_log := run.run_log.size()
	screen._select({"member": first, "column": column})
	screen._open_menu({"id": &"fixture.equipment.helm", "holder": 0, "index": 0, "use": false})
	eq(screen.get_node("%Equip").text, "EQUIP", "a bag piece: EQUIP")
	screen._on_equip()
	eq(run.state.member(first)["equipment"].get(head, &""), &"fixture.equipment.helm", "the first member wears it")
	screen._select({"member": second, "column": column})
	screen._open_menu({"id": &"fixture.equipment.helm", "holder": first, "index": 0, "use": false})
	eq(screen.get_node("%Equip").text, "SWAP", "worn by someone else: SWAP")
	screen._on_equip()
	eq(run.state.member(second)["equipment"].get(head, &""), &"fixture.equipment.helm", "the second member wears it now")
	check(not run.state.member(first)["equipment"].has(head), "the first member's old (empty) slot comes back empty")
	var types: Array = run.run_log.slice(start_log).map(func(entry) -> String: return entry["type"])
	eq(types, ["equip", "swap_gear"], "EQUIP, then SWAP as one logged swap (spec keys-and-gear 2.4)")
	screen._open_menu({"id": &"fixture.equipment.helm", "holder": second, "index": 0, "use": false})
	check(screen.get_node("%TakeOff").visible, "worn here: TAKE OFF")
	screen._on_take_off()
	eq(run.state.armor.count(&"fixture.equipment.helm"), 1, "taken off: back in the bag")
	# Spec keys-and-gear 2.5: another member's use item moves into a free Item Slot as one logged move.
	var items := GearColumn.new()
	items.title = "ITEM SLOT"
	items.use_slot = 1
	gear_set.columns.assign([items])
	screen.refresh()
	var feather: StringName = run.state.party[0]["use_slots"][0]["item"]
	screen._select({"member": second, "column": items})
	screen._open_menu({"id": feather, "holder": first, "index": 1, "use": true})
	eq([screen.get_node("%Equip").text, screen.get_node("%Equip").disabled], ["MOVE HERE", false], "MOVE HERE")
	screen._on_equip()
	eq([run.state.holder_of(feather), run.run_log[-1]["type"]], [second, "move_item"], "moved, one logged action")


# --- Keys and chests on screen (spec keys-and-gear 2.3, 3.3, D9, D12, D13) -------------------------------------------

## A GameMain on the keyed fixture run (built in memory, tests/game/keys_world.gd).
func _keyed_game() -> GameMain:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	_games.append(game)
	game.content = KeysWorld.content()
	eq(game.start_run(["fixture.character.knight", "fixture.character.medic"], "7", KeysWorld.RUN_ID), "",
		"the keyed run starts")
	await _frames(3)
	return game


func test_keys_line() -> void:
	var plain := await _game()
	check(not _find(plain, "ExploreMenu").get_node("%Keys").visible, "no Keys line on a run without keys")
	var game := await _keyed_game()
	var menu := _find(game, "ExploreMenu")
	check(menu.get_node("%Keys").visible, "a run with keys shows the Keys line")
	eq(menu.get_node("%Keys").text, "Keys: 0", "Keys: 0 included (D13)")
	game.run.add_keys(2)
	game.run.give_golden_key()
	await _frames(2)
	eq(menu.get_node("%Keys").text, "Keys: 2 + golden key", "it follows the run")


## Spec floor-chests 2.6: the room's closed chests are rows of the pickup panel (Open, Open · 1 key); an open chest's armor
## follows as an ordinary row naming only the piece (no "from the Crate": user, 2026-11-21); the Use Item screen lists no chest any more.
func test_pickup_panel_opens_chests() -> void:
	var game := await _keyed_game()
	var run := game.run
	run.give_chest(run.content.chests[&"fixture.chest.crate"])
	run.give_chest(run.content.chests[&"fixture.chest.strongbox"])
	await _frames(3)
	var panel := _find(game, "PickupPanel")
	check(panel != null, "a closed chest shows the pickup panel")
	if panel == null:
		return
	var rows: Array = panel.get_node("%Rows").get_children().filter(func(row) -> bool: return row.visible)
	eq(rows.map(func(row) -> Array: return [row.get_node("%Name").text, row.get_node("%Take").text,
		row.get_node("%Take").disabled]), [["Crate", "Open", false], ["Strongbox", "Open · 1 key", true]],
		"a free chest, then one that needs a key, greyed with no key")
	rows[0].get_node("%Take").pressed.emit()
	await _frames(3)
	eq([run.run_log[-1]["type"], run.state.armor.size()], ["open_chest", 0], "Open is one logged open_chest; the gear is not taken yet")
	rows = panel.get_node("%Rows").get_children().filter(func(row) -> bool: return row.visible)
	var put_out := run.chest_pickups(run.state.current_cell, 0)
	var piece_name: String = run.content.equipment[put_out[0]["item"]].display_name if not put_out.is_empty() else "?"
	var gear = rows.filter(func(row) -> bool: return row.get_node("%Name").text.contains(piece_name))
	eq(gear.size(), 1, "its armor is a row (got %s)" % [rows.map(func(row): return row.get_node("%Name").text)])
	check(not rows.any(func(row) -> bool: return row.get_node("%Name").text.contains("from the")), "no row says \"from the X\"")
	if not gear.is_empty():
		gear[0].get_node("%Take").pressed.emit()
		await _frames(2)
		eq(run.state.armor.size(), 1, "taken into the bag")
	var use = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/use_screen.tscn"), {"mode": "item"})
	await _frames(2)
	check(use.get_node("%Pool").get_children().all(func(entry) -> bool: return entry.get_node("%Name").text != "Strongbox"),
		"the Use Item screen lists no chest")


func test_pickup_panel_sells_keys() -> void:
	var game := await _keyed_game()
	var run := game.run
	var cell: int = run.state.current_cell
	run.state.map.cells[cell]["pickups"].append({"placement": 9, "item": FloorGenerator.KEYS_KIND, "price": 2,
		"taken": false, "kind": FloorGenerator.KEYS_KIND, "keys": 1})
	run.add_coins(3)
	run.pickups_shown.emit(cell)
	await _frames(3)
	var panel := _find(game, "PickupPanel")
	check(panel != null, "the pickup panel shows")
	var rows: Array = panel.get_node("%Rows").get_children().filter(func(row) -> bool: return row.visible)
	var key_row = rows.filter(func(row) -> bool: return row.get_node("%Name").text.begins_with("Key"))
	eq(key_row.size(), 1, "the key slot is a row (got %s)" % [rows.map(func(row): return row.get_node("%Name").text)])
	if key_row.is_empty():
		return
	check(not key_row[0].get_node("%GiveTo").visible, "keys need no 'give to' picker")
	eq(key_row[0].get_node("%Take").text, "Buy", "a key costs coins")
	key_row[0].get_node("%Take").pressed.emit()
	await _frames(2)
	eq([run.state.keys, run.state.coins], [1, 1], "bought: one key for two coins")


## The demo run toasts (presentation/demo/ui/run_toasts.tres) have a rule on each keys-and-gear channel.
func test_run_toasts_cover_keys_and_chests() -> void:
	var toasts: UIToastSet = load("res://presentation/demo/ui/run_toasts.tres")
	var channels: Array = toasts.rules.map(func(rule: UIToastRule) -> StringName: return rule.channel)
	for channel in [GameplayMessageRouter.RUN_KEY_FOUND, GameplayMessageRouter.RUN_CHEST_FOUND,
			GameplayMessageRouter.RUN_CHEST_OPENED]:
		check(channels.has(channel), "a toast rule on %s" % channel)
	# And one shows: a cleared battle room on the keyed run drops a key and a chest (100% there).
	var game := await _keyed_game()
	var normal := KeysWorld.normal(game.run)
	var host_panel: UIToastHost = _find(game, "RunToasts")
	host_panel.advance(5.0)  # the floor toast from the run start expires
	game.run._clear_room(normal, true)
	await _frames(2)
	var titles: Array = host_panel.toasts().map(func(toast: Dictionary) -> String: return str(toast.get("title", "")))
	eq(titles, ["You found a key!", "You found a Crate!"], "the key and chest toasts show together, oldest first")


## Spec ui-fixes B4: the run toasts stack four, oldest on top, one line each. Four is a soft cap: a fifth shows too, and
## the oldest then expires early (overflow_seconds) and fades three times faster; the toasts below glide up into its
## place (never below it, never snapping).
func test_run_toasts_stack_four() -> void:
	var game := await _game()
	var host_panel: UIToastHost = _find(game, "RunToasts")
	host_panel.advance(5.0)  # the floor toast from the run start expires
	var box: Control = host_panel.get_node("%Toasts")
	var waited := Time.get_ticks_msec()
	while box.get_child_count() > 0 and Time.get_ticks_msec() - waited < 2000:  # its fade is real time
		await _frames(1)
	for level in [2, 3, 4, 5]:
		host_panel.receive(GameplayMessageRouter.RUN_LEVEL_UP, VerbMessage.make(&"Verb.Gain", &"", &"Knight", level))
	await _frames(3)
	var nodes: Array = box.get_children().filter(func(node) -> bool: return not node.is_queued_for_deletion())
	eq(nodes.size(), 4, "four toasts at once")
	var line_height: float = nodes[0].size.y
	check(line_height < 50.0, "one thin line each (%d px)" % line_height)
	for index in range(1, nodes.size()):
		check(nodes[index].position.y >= nodes[index - 1].position.y + line_height,
			"toast %d sits below toast %d" % [index, index - 1])
	var oldest: Control = nodes[0]
	waited = Time.get_ticks_msec()
	while nodes.any(func(node) -> bool: return node.modulate.a < 1.0) and Time.get_ticks_msec() - waited < 2000:
		await _frames(1)  # their slide-in (real time) ends
	var started := Time.get_ticks_msec()
	host_panel.receive(GameplayMessageRouter.RUN_LEVEL_UP, VerbMessage.make(&"Verb.Gain", &"", &"Knight", 6))
	eq(host_panel.toasts().size(), 5, "a fifth shows too (a soft cap)")
	var early: float = host_panel.toast_set.overflow_seconds * 1000.0
	var fading_at := -1
	while is_instance_valid(oldest) and Time.get_ticks_msec() - started < 2000:
		if fading_at < 0 and oldest.modulate.a < 1.0:
			fading_at = Time.get_ticks_msec() - started
		await _frames(1)
	var gone_ms := Time.get_ticks_msec() - started
	check(fading_at >= early - 20, "the oldest stays until overflow_seconds (fades at %d ms)" % fading_at)
	check(not is_instance_valid(oldest) and gone_ms - fading_at < 200,
		"then fades fast (%d ms; a normal fade is 300)" % (gone_ms - fading_at))
	eq(host_panel.toasts().size(), 4, "back to four")
	var second: Control = nodes[1]
	var top := second.position.y
	await _frames(1)
	check(second.position.y < top and second.position.y > 0.0,
		"the next toast glides up (y %.1f, was %.1f), it does not snap" % [second.position.y, top])
	waited = Time.get_ticks_msec()
	while second.position.y > 0.0 and Time.get_ticks_msec() - waited < 2000:
		await _frames(1)
	eq(second.position.y, 0.0, "and reaches the top")


## Spec ui-fixes B6: holding Tab slides the whole floor banner down into place: the window comes down, and its text
## stays put inside it.
func test_floor_toast_slides_as_one() -> void:
	var game := await _game()
	var host_panel: UIToastHost = _find(game, "RunToasts")
	host_panel.advance(5.0)  # the floor toast from the run start expires
	var box: Control = host_panel.get_node("%Toasts")
	var waited := Time.get_ticks_msec()
	while box.get_child_count() > 0 and Time.get_ticks_msec() - waited < 2000:  # its fade is real time
		await _frames(1)
	host_panel.hold(&"show_floor_info", true)
	await _frames(2)
	eq(box.get_child_count(), 1, "Tab shows the floor toast")
	if box.get_child_count() != 1:
		return
	var banner: Control = box.get_child(0)
	var text_y: float = banner.get_node("%Lines").position.y
	check(banner.position.y < 0.0, "the banner starts above its place (y %.1f)" % banner.position.y)
	waited = Time.get_ticks_msec()
	while banner.position.y < 0.0 and Time.get_ticks_msec() - waited < 2000:
		await _frames(1)
	eq(banner.position.y, 0.0, "and comes down into it")
	eq(banner.get_node("%Lines").position.y, text_y, "its text moved with it, not inside it")
	host_panel.hold(&"show_floor_info", false)


## Spec event-items: the Give to panel (a Modal screen while UI.State.Run.Gift) for an event's CHOOSE item: it names the item,
## lists the party, a press gives it (logged give_to) and the panel goes away. (A chest's item lands beside it since spec
## floor-chests, so the gift comes from an event here.)
func test_gift_panel() -> void:
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
	eq(panel.get_node("%Name").text, gift.item.display_name, "it names the item")
	var buttons: Array = panel.get_node("%Members").get_children()
	eq(buttons.size(), run.state.party.size(), "one button per party member")
	buttons[1].pressed.emit()
	await _frames(3)
	eq(run.run_log[-1]["type"], "give_to", "a press is a logged give_to")
	eq(run.state.holder_of(gift.item.id), run.state.party[1]["slot"], "to the member pressed")
	check(_find(game, "GiftPanel") == null, "and the panel goes away")


## Spec event-pass 2.7, 2.9: the event panel fills in member tokens, hides a WHEN_MET choice whose class is missing, shows
## a class choice with its badge and look, and a press still runs the choice by its own index.
func test_event_panel_class_choices_and_tokens() -> void:
	var game := await _game()
	var run := game.run
	var medic := HasCharacter.new()
	medic.character = run.content.units[&"fixture.character.medic"]
	var cantor := HasCharacter.new()
	cantor.character = run.content.units[&"fixture.character.cantor"]
	var choices: Array[EventChoice] = []
	for entry in [["Leave", [], [&"Choice.Leave"], EventChoice.Show.ALWAYS],
			["Sing", [cantor], [&"Choice.Class", &"Choice.Gain.Xp"], EventChoice.Show.WHEN_MET],
			["Bless the dice", [medic], [&"Choice.Class", &"Choice.Gain.Heal"], EventChoice.Show.WHEN_MET]]:
		var choice := EventChoice.new()
		choice.label = entry[0]
		choice.conditions.assign(entry[1])
		choice.tags.assign(entry[2])
		choice.show = entry[3]
		choices.append(choice)
	var page := EventPage.new()
	page.text = "{member:1} looks at the dice."
	page.choices = choices
	var event := EventDefinition.new()
	event.id = &"fixture.event.panel_probe"
	event.display_name = "Dice"
	event.pages.assign([page])
	run.content.events[event.id] = event  # this game's own content index, freed with it
	eq(run.dev_open_event(event), "", "the event opens")
	await _frames(3)
	var panel := _find(game, "EventPanel")
	check(panel != null, "the event panel shows")
	if panel == null:
		return
	var knight: String = run.content.units[&"fixture.character.knight"].display_name
	eq(panel.get_node("%Text").text, knight + " looks at the dice.", "the member token is filled in")
	var buttons: Array = panel.get_node("%Choices").get_children().filter(func(node: Node) -> bool: return node is Button)
	eq(buttons.size(), 2, "the class choice for a missing class is hidden")
	eq(buttons[1].text, "[%s] Bless the dice" % medic.character.display_name, "the class choice has its badge")
	eq(buttons[1].theme_type_variation, &"EventChoiceClass", "and its look")
	buttons[1].pressed.emit()
	await _frames(3)
	eq(run.run_log[-1]["choice"], 2, "a press runs the choice by its own index")
	run.content.events.erase(event.id)


## Event endings (user, 2026-11-22): a choice leads to its ending page, which tells the story and lists what changed;
## a choice with no ending page (content the validator warns about) falls back to the result dialog.
func test_event_ending_page_and_fallback_dialog() -> void:
	var game := await _game()
	var run := game.run
	var keys := GainKeys.new()
	keys.amount = 2
	var go := GoToPage.new()
	go.page = 1
	var drink := EventChoice.new()
	drink.label = "Drink with him"
	drink.outcomes.assign([go])
	var bare := GainCoins.new()
	bare.amount = 3
	var grab := EventChoice.new()
	grab.label = "Grab a coin"
	grab.outcomes.assign([bare])
	var start := EventPage.new()
	start.text = "A watchman snores."
	start.choices.assign([drink, grab])
	var cont := EventChoice.new()
	cont.label = "Continue"
	var ending := EventPage.new()
	ending.text = "The Bard drinks him under the table, and the party lifts his keys."
	ending.choices.assign([cont])
	var on_enter: Array[RunOutcome] = [keys]
	ending.on_enter = on_enter
	var event := EventDefinition.new()
	event.id = &"fixture.event.result_probe"
	event.display_name = "Watchman"
	event.pages.assign([start, ending])
	run.content.events[event.id] = event
	run.event_results = true  # off headless by default (review fix)
	eq(run.dev_open_event(event), "", "the event opens")
	await _frames(2)
	eq(run.choose(0), "", "drink")
	await _frames(3)
	var panel := _find(game, "EventPanel")
	check(panel != null, "the event panel shows the ending")
	if panel != null:
		var text: String = panel.get_node("%Text").text
		check(text.contains("lifts his keys") and text.contains("+2 keys"), "the story and what changed: %s" % text)
	eq(run.choose(0), "", "Continue")
	await _frames(3)
	check(_visible_dialogs(game).is_empty(), "an ending page needs no dialog")
	eq(run.dev_open_event(event), "", "again, for the fallback")
	await _frames(2)
	eq(run.choose(1), "", "grab a coin (no ending page)")
	await _frames(3)
	var dialog := _visible_dialogs(game)
	check(not dialog.is_empty(), "the fallback result dialog shows")
	if not dialog.is_empty():
		check(_texts(dialog[0]).contains("+3 coins"), "with what changed: %s" % _texts(dialog[0]))
	run.content.events.erase(event.id)


func _visible_dialogs(game: GameMain) -> Array:
	return game.find_children("*", "UIConfirm", true, false).filter(func(node: Node) -> bool: return node.is_visible_in_tree())


func _texts(node: Node) -> String:
	var parts := PackedStringArray()
	for child in node.find_children("*", "", true, false):
		if child is Label or child is RichTextLabel:
			parts.append(child.text)
	return " | ".join(parts)


## User, 2026-11-22: the stairs panel (Next floor) is exactly as wide as the minimap above it, never the widest panel.
func test_stairs_panel_matches_the_map_width() -> void:
	var game := await _game()
	var run := game.run
	if run.is_last_floor():
		return
	eq(run.dev_boss_done(), "", "the boss counts as beaten")
	await _frames(4)
	var stairs := _find(game, "StairsPanel") as Control
	var map := _find(game, "MapPanel") as Control
	check(stairs != null and map != null, "the stairs panel and the map show")
	if stairs == null or map == null:
		return
	eq(stairs.size.x, map.size.x, "Next floor is as wide as the map")


## Spec ui-fixes B7: an event page shown while the party strip is up (entering an event room from the map) redraws the
## strip with no error (event_page_shown has two arguments; any engine error fails this test).
func test_party_strip_takes_event_pages() -> void:
	var game := await _game()
	check(_find(game, "PartyStrip") != null, "the party strip is up on the map")
	game.run.event_page_shown.emit(&"fixture.event.any", 0)
	await _frames(2)


func test_use_and_status_screens() -> void:
	var game := await _game()
	var use = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/use_screen.tscn"), {"mode": "ability"})
	await _frames(2)
	check(use.get_node("%Pool").get_child_count() == 0, "Use Ability starts by asking for a party member")
	use._on_member(game.run.state.party[0]["slot"])
	await _frames(1)
	check(use.get_node("%Pool").get_child_count() > 0, "then lists that member's abilities")
	check(use.handles_back(), "Back steps back to the member")
	game.ui.back()
	await _frames(2)
	var status = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/status_screen.tscn"))
	await _frames(2)
	for tab in ["info", "held", "stats"]:
		status._set_tab(tab)
		await _frames(1)
		check(status.get_node("%Body").get_child_count() > 0, "the %s tab shows something" % tab)


## Playtest-fixes B28: Tab toggles the grown map (one press on, the next off; holding it flips once) and never walks the
## focused button on the run screens; a text field keeps its Tab.
func test_tab_toggles_the_map_and_keeps_focus() -> void:
	var game := await _game()
	var panel := _find(game, "MapPanel")
	var title: Label = panel.get_node("%Title")
	var small := title.text
	var button: Button = _find(game, "ExploreMenu").find_children("*", "Button", true, false)[0]
	button.grab_focus()
	await _frames(1)
	var tab := InputEventAction.new()
	tab.action = &"show_floor_info"
	tab.pressed = true
	Input.parse_input_event(tab)
	await _frames(2)
	check(title.text != small, "one press grows the map (%s)" % title.text)
	eq(game.get_viewport().gui_get_focus_owner(), button, "the focus stays on its button")
	var echo := InputEventKey.new()
	echo.physical_keycode = KEY_TAB
	echo.pressed = true
	echo.echo = true
	Input.parse_input_event(echo)
	await _frames(2)
	check(title.text != small, "a held key's repeat does not flip it back")
	eq(game.get_viewport().gui_get_focus_owner(), button, "nor walks the focus")
	var release := InputEventAction.new()
	release.action = &"show_floor_info"
	Input.parse_input_event(release)
	Input.parse_input_event(tab)
	await _frames(2)
	eq(title.text, small, "the next press shrinks it")
	Input.parse_input_event(release)
	await _frames(1)


## Playtest-fixes B31: a long pickup name (a Void altar's "costs a <curse>: <description>") wraps to several lines; the member
## picker and the Take button keep their own height instead of stretching with the row.
func test_pickup_row_picker_keeps_its_height() -> void:
	var row: Control = load("res://presentation/demo/ui/pickup_row.tscn").instantiate()
	row.custom_minimum_size = Vector2(540, 0)
	host.add_child(row)
	var picker: OptionButton = row.get_node("%GiveTo")
	picker.add_item("Warrior", 1)
	var take: Button = row.get_node("%Take")
	(row.get_node("%Name") as Label).text = "[Epic] Corrupted Drum  5 coins  costs a Void Scar: -10% max HP for the rest of the run, " \
		+ "and every ult costs 10 more SP."
	await _frames(3)
	check(row.get_node("Row").size.y > picker.get_combined_minimum_size().y * 2, "the name wraps (row %.0f)" % row.get_node("Row").size.y)
	eq(picker.size.y, picker.get_combined_minimum_size().y, "the picker keeps its height")
	eq(take.size.y, take.get_combined_minimum_size().y, "so does the button")
	row.queue_free()
