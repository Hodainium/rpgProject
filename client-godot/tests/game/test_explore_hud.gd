## Spec ff7-ui 6 (stage 5): the exploration HUD. MapCells (system, fixtures): what each map cell shows. Then, under the
## demo UI policy on fixture content (presentation, direction only): the party strip, the menu and the map on the map;
## a menu screen hides them (UI.State.Run.Menu) and Back brings them back; the minimap never travels, the big map does
## (and a drag is never a click); the gear screen's EQUIP, SWAP (three logged actions, F11) and TAKE OFF; Use Ability
## and Status on the menu frame.
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
	return game.find_child(node_name, true, false)


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
