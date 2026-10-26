## Spec ui-framework 6: layer stacks, Back, rules and extension slots by UI state, lists, push/back buttons, the
## confirm dialog, run rebinding, the policy check, and that the UI never changes a run. Layouts, screens and
## policies are built in code from the probes next to this file (never from res://presentation/), so restyling the
## demo screens can't fail these tests. test_demo_ui_policy is the one presentation check: the demo policy is valid.
extends TestCase

const PROBE := preload("res://tests/game/ui_probe_screen.gd")
const ENTRY := preload("res://tests/game/ui_probe_entry.gd")
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic"]
const GAME: StringName = &"UI.Layer.Game"
const GAME_MENU: StringName = &"UI.Layer.GameMenu"
const MENU: StringName = &"UI.Layer.Menu"
const MODAL: StringName = &"UI.Layer.Modal"

var _nodes: Array[Node] = []


func after_each() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.free()
	_nodes.clear()
	Engine.time_scale = 1.0
	super()


# --- Building blocks ------------------------------------------------------------------------------------------------

static func _pack(root: Node) -> PackedScene:
	_own(root, root)
	var scene := PackedScene.new()
	scene.pack(root)
	root.free()
	return scene


static func _own(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_own(child, owner)


## Game (never popped by Back), GameMenu, Menu, Modal, and a footer slot.
static func _layout_scene() -> PackedScene:
	var layout := UILayout.new()
	layout.name = "Layout"
	for entry in [["Game", GAME, false], ["GameMenu", GAME_MENU, true], ["Menu", MENU, true], ["Modal", MODAL, true]]:
		var stack := UILayerStack.new()
		stack.name = entry[0]
		stack.layer = entry[1]
		stack.back_pops = entry[2]
		stack.blocks_below = entry[1] != GAME
		layout.add_child(stack)
	var footer := UIExtensionPoint.new()
	footer.name = "Footer"
	footer.slot = &"UI.Slot.Footer"
	layout.add_child(footer)
	return _pack(layout)


## A probe screen named `name`, with an extension point for `slot` when given and extra children when given.
static func _probe_scene(name: String, slot: StringName = &"", children: Array = []) -> PackedScene:
	var screen := Control.new()
	screen.set_script(PROBE)
	screen.name = name
	if slot != &"":
		var point := UIExtensionPoint.new()
		point.name = "Slot"
		point.slot = slot
		screen.add_child(point)
	for child in children:
		screen.add_child(child)
	return _pack(screen)


static func _query(tag: StringName) -> GameplayTagQuery:
	var query := GameplayTagQuery.new()
	query.require_all_tags.assign([tag])
	return query


static func _rule(scene: PackedScene, layer: StringName, when: StringName, clears: StringName = &"") -> UIScreenRule:
	var rule := UIScreenRule.new()
	rule.scene = scene
	rule.layer = layer
	rule.active_when = _query(when) if when != &"" else null
	rule.clears_layer = clears
	return rule


static func _extension(slot: StringName, scene: PackedScene, order: int, when: StringName) -> UIExtension:
	var extension := UIExtension.new()
	extension.slot = slot
	extension.scene = scene
	extension.order = order
	extension.active_when = _query(when) if when != &"" else null
	return extension


## A UIManager on its own (no GameMain: the state is always Menu).
func _manager(policy: UIPolicy) -> UIManager:
	var canvas := CanvasLayer.new()
	host.add_child(canvas)
	_nodes.append(canvas)
	var manager := UIManager.new()
	host.add_child(manager)
	_nodes.append(manager)
	eq(manager.setup(null, policy, canvas), "", "the policy builds")
	return manager


## A GameMain on the fixtures with `policy` as its UI.
func _game(policy: UIPolicy) -> GameMain:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.ui_policy = policy
	game.skip_animations = true
	host.add_child(game)
	_nodes.append(game)
	game.content_root = FIXTURES
	game.load_content()
	return game


static func _names(nodes: Array) -> Array:
	return nodes.filter(func(node) -> bool: return not node.is_queued_for_deletion()).map(
		func(node) -> String: return String(node.name))


static func _plain_policy() -> UIPolicy:
	var policy := UIPolicy.new()
	policy.layout = _layout_scene()
	return policy


# --- Stacks and Back --------------------------------------------------------------------------------------------------

func test_ui_stack() -> void:
	var manager := _manager(_plain_policy())
	var a_scene := _probe_scene("A")
	var b_scene := _probe_scene("B")
	var a := manager.push(MENU, a_scene, {"id": "a"})
	eq(a.calls, ["bind", "pushed:a", "activated"], "bind, then the payload, then activation")
	var b := manager.push(MENU, b_scene)
	eq(a.calls.back(), "deactivated", "the screen below is deactivated")
	check(not a.visible and b.visible and b.active, "only the top screen shows")
	check(manager.back(), "Back pops a screen a player opened")
	eq(manager.top(MENU), a, "the screen below comes back")
	eq(a.calls.back(), "activated", "and is activated again, the same instance")
	check(b.is_queued_for_deletion(), "the popped screen is freed")
	var c := manager.push(MENU, b_scene)
	c.consume_back = true
	check(manager.back(), "a screen may consume Back")
	eq(manager.top(MENU), c, "and stays")
	c.consume_back = false
	var d := manager.push(MODAL, _probe_scene("D"))
	check(manager.back(), "Back")
	check(d.is_queued_for_deletion() and manager.top(MENU) == c, "the Modal layer pops first")
	c.owned_by_rule = true
	check(not manager.back(), "a screen the policy's rules own is never popped by Back")
	manager.clear(MENU)
	eq(manager.top(MENU), null, "clear empties a layer")
	var hud := manager.push(GAME, _probe_scene("Hud"))
	check(not manager.back(), "the Game layer never pops")
	eq(manager.top(GAME), hud, "the HUD stays")
	var x := manager.push(MENU, a_scene)
	var y := manager.push(MENU, b_scene)
	eq(manager.push(MENU, a_scene), x, "the same scene is raised, not opened twice")
	eq(manager.top(MENU), x, "now on top")
	check(y.visible == false and not y.active, "the other one is covered")
	manager.remove(y)
	eq(manager.top(MENU), null, "removing a screen removes the ones above it too")
	eq(manager.layers(), [GAME, GAME_MENU, MENU, MODAL], "layers bottom to top")


# --- Rules and slots by UI state ------------------------------------------------------------------------------------

func test_ui_rules() -> void:
	var policy := _plain_policy()
	var hud := _probe_scene("Hud", &"UI.Slot.Hud.Left")
	policy.screens.assign([_rule(_probe_scene("Title"), MENU, UIState.MENU, GAME_MENU), _rule(hud, GAME, UIState.RUN),
		_rule(_probe_scene("End"), MENU, UIState.END, GAME_MENU)])
	policy.extensions.assign([_extension(&"UI.Slot.Hud.Left", _probe_scene("Party"), 10, UIState.RUN),
		_extension(&"UI.Slot.Hud.Left", _probe_scene("Field"), 0, UIState.MAP),
		_extension(&"UI.Slot.Footer", _probe_scene("Message"), 0, &"")])
	policy.back_screens.assign([_rule(_probe_scene("Pause"), GAME_MENU, UIState.MAP)])
	var game := _game(policy)
	var manager := game.ui
	manager.apply_now()
	eq(manager.top(MENU).name, &"Title", "Menu state: the title screen")
	eq(_names(manager.layout.get_node("Footer").get_children()), ["Message"], "an extension without a query is always on")
	eq(game.start_run(PARTY, "1"), "", "a fixture run starts")
	manager.apply_now()
	eq(manager.top(MENU), null, "the title screen is removed with its state")
	var hud_screen := manager.top(GAME)
	eq(hud_screen.name, &"Hud", "Run state: the HUD")
	eq(_names(hud_screen.get_node("Slot").get_children()), ["Field", "Party"], "panels in the HUD's slot, by order")
	check(manager.back(), "Back with nothing to close")
	eq(manager.top(GAME_MENU).name, &"Pause", "opens the policy's back screen")
	check(manager.back(), "Back again")
	eq(manager.top(GAME_MENU), null, "closes it")
	game.run.pending_battle = {"cell": game.run.state.current_cell}
	manager.apply_now()
	eq(_names(hud_screen.get_node("Slot").get_children()), ["Party"], "Battle state: the map-only panel is removed")
	game.run.pending_battle = {}
	manager.apply_now()
	manager.back()
	eq(manager.top(GAME_MENU).name, &"Pause", "the run menu is open")
	eq(game.run.dev_win(), "", "the run ends")
	manager.apply_now()
	eq(manager.top(MENU).name, &"End", "End state: the end screen")
	eq(manager.top(GAME_MENU), null, "which cleared the run menu")
	eq(manager.top(GAME), null, "and the HUD is gone")
	check(manager.context.has_state(UIState.WON), "End.Won")


## Rules apply once per frame on the latest state, however many run signals fire.
func test_ui_rules_coalesce() -> void:
	var policy := _plain_policy()
	policy.screens.assign([_rule(_probe_scene("Hud"), GAME, UIState.RUN)])
	var game := _game(policy)
	eq(game.start_run(PARTY, "1"), "", "a fixture run starts")
	for i in 5:
		game.run.party_changed.emit()
	await host.get_tree().process_frame
	var hud: Node = game.ui.top(GAME)
	eq(hud.calls.count("activated"), 1, "one activation for a burst of changes")


func test_ui_state_tags() -> void:
	eq(UIState.compute("menu", null), [UIState.MENU], "menu")
	eq(UIState.compute("end", null), [UIState.END, UIState.STOPPED], "a run that never started")
	var run := TestCase.start_run(host, "1", PARTY)
	_nodes.append(run)
	var tags := UIState.compute("run", run)
	check(tags.has(UIState.RUN) and tags.has(UIState.MAP), "on the map: Run and Run.Map")
	var sorted := tags.duplicate()
	sorted.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	eq(tags, sorted, "sorted")
	run.pending_battle = {"cell": run.state.current_cell}
	tags = UIState.compute("run", run)
	check(tags.has(UIState.BATTLE) and not tags.has(UIState.MAP), "a battle: Run.Battle, not Map")
	run.pending_battle = {}
	run.state.event = {"cell": -1, "event": &"fixture.event.rest", "page": 0, "rest_to": 1}
	tags = UIState.compute("run", run)
	check(tags.has(UIState.EVENT) and tags.has(UIState.REST), "the rest stop: Event and Event.Rest")
	run.state.event = {}
	run.state.boss_cleared = true
	check(UIState.compute("run", run).has(UIState.STAIRS) != run.is_last_floor(), "stairs open unless last floor")
	run.state.status = RunState.WON
	eq(UIState.compute("end", run), [UIState.END, UIState.WON], "won")
	run.state.status = RunState.LOST
	eq(UIState.compute("end", run), [UIState.END, UIState.LOST], "lost")


# --- Lists and buttons ----------------------------------------------------------------------------------------------

func test_ui_list() -> void:
	var manager := _manager(_plain_policy())
	var entry := Label.new()
	entry.set_script(ENTRY)
	var list := UIList.new()
	list.name = "List"
	list.entry_scene = _pack(entry)
	var screen := manager.push(MENU, _probe_scene("Lists", &"", [list]))
	var live: UIList = screen.get_node("List")
	var first := live.set_items(["a", "b", "c"])
	eq(first.map(func(node) -> String: return node.text), ["a", "b", "c"], "one entry per item, in order")
	eq(first[0].got_context, manager.context, "entries get the screen's context")
	var second := live.set_items(["x"])
	eq(second[0], first[0], "entries are reused")
	eq(second[0].text, "x", "and refilled")
	check(first[1].is_queued_for_deletion() and first[2].is_queued_for_deletion(), "extra entries are freed")


func test_ui_push_and_back_buttons() -> void:
	var manager := _manager(_plain_policy())
	var back := UIBackButton.new()
	back.name = "Back"
	var details := _probe_scene("Details", &"", [back])
	var open := UIPushButton.new()
	open.name = "Open"
	open.screen = details
	open.layer = MENU
	open.payload = {"id": "p"}
	var menu := manager.push(MENU, _probe_scene("Menu", &"", [open]))
	menu.get_node("Open").pressed.emit()
	var opened := manager.top(MENU)
	eq(opened.name, &"Details", "a UIPushButton opens its screen on its layer")
	check(opened.calls.has("pushed:p"), "with its payload")
	opened.get_node("Back").pressed.emit()
	eq(manager.top(MENU), menu, "a UIBackButton goes back")


func test_ui_confirm() -> void:
	var dialog := Control.new()
	dialog.set_script(UIConfirm)
	dialog.name = "Confirm"
	for name in ["Text", "Yes", "No"]:
		var node: Control = Label.new() if name == "Text" else Button.new()
		node.name = name
		node.unique_name_in_owner = true
		dialog.add_child(node)
	var policy := _plain_policy()
	policy.confirm_scene = _pack(dialog)
	var manager := _manager(policy)
	var answers: Array = []
	var ask := func(): answers.append(await manager.confirm("Sure?", "Do it", "No way"))
	ask.call()
	var shown := manager.top(MODAL)
	eq(shown.get_node("%Text").text, "Sure?", "the question")
	eq(shown.get_node("%Yes").text, "Do it", "the yes label")
	shown.get_node("%Yes").pressed.emit()
	await host.get_tree().process_frame
	eq(answers, [true], "yes")
	eq(manager.top(MODAL), null, "the dialog closes")
	ask.call()
	check(manager.back(), "Back on a dialog")
	await host.get_tree().process_frame
	eq(answers, [true, false], "answers no")


# --- Context, policy check, runs ------------------------------------------------------------------------------------

func test_ui_context_rebinds() -> void:
	var game := _game(_plain_policy())
	var context := game.ui.context
	var owner := Node.new()
	host.add_child(owner)
	_nodes.append(owner)
	var hits: Array = [0]
	eq(game.start_run(PARTY, "1"), "", "first run")
	context.on_run(owner, &"map_revealed", func(): hits[0] += 1)
	var first := game.run
	first.map_revealed.emit()
	eq(hits[0], 1, "connected to the current run")
	eq(game.start_run(PARTY, "2"), "", "second run")
	first.map_revealed.emit()
	eq(hits[0], 1, "the old run is disconnected")
	game.run.map_revealed.emit()
	eq(hits[0], 2, "the new run is connected")
	owner.free()
	game.run.map_revealed.emit()
	eq(hits[0], 2, "gone with its owner")


func test_ui_policy_check() -> void:
	eq(UIPolicyCheck.validate(_plain_policy()), [], "a bare layout is valid")
	var codes := func(policy: UIPolicy) -> Array: return UIPolicyCheck.validate(policy).map(
		func(issue: ValidationIssue) -> String: return issue.code)
	eq(codes.call(UIPolicy.new()), ["ui_layout_root"], "no layout")
	var policy := _plain_policy()
	policy.screens.assign([_rule(_probe_scene("A"), &"UI.Layer.Nowhere", UIState.MENU)])
	eq(codes.call(policy), ["ui_layer_unknown"], "a layer the layout lacks")
	policy = _plain_policy()
	policy.extensions.assign([_extension(&"UI.Slot.Nowhere", _probe_scene("P"), 0, &"")])
	eq(codes.call(policy), ["ui_slot_unknown"], "a slot nothing offers")
	policy = _plain_policy()
	policy.screens.assign([_rule(_probe_scene("Hud", &"UI.Slot.Hud.Left"), GAME, UIState.RUN)])
	policy.extensions.assign([_extension(&"UI.Slot.Hud.Left", _probe_scene("P"), 0, &"")])
	eq(codes.call(policy), [], "a slot a screen offers is known")
	policy = _plain_policy()
	policy.screens.assign([_rule(_pack(Control.new()), MENU, UIState.MENU)])
	policy.confirm_scene = _probe_scene("NotAConfirm")
	eq(codes.call(policy), ["ui_screen_not_uiscreen", "ui_screen_not_uiscreen"], "roots that aren't screens or dialogs")


## The UI never changes a run: the same run played with and without a UI has the same log and hash.
func test_ui_run_hash_unchanged() -> void:
	var policy := _plain_policy()
	policy.screens.assign([_rule(_probe_scene("Hud", &"UI.Slot.Hud.Left"), GAME, UIState.RUN)])
	policy.extensions.assign([_extension(&"UI.Slot.Hud.Left", _probe_scene("Party"), 0, UIState.RUN)])
	var game := _game(policy)
	eq(game.start_run(PARTY, "5"), "", "with a UI")
	var bare := TestCase.start_run(host, "5", PARTY)
	_nodes.append(bare)
	var cell := -1
	for index in bare.state.map.sorted_indices():
		if bare.can_enter(index) and bare.state.map.cells[index]["content"]["enemies"].is_empty():
			cell = index
			break
	if cell >= 0:
		game.run.enter_room(cell)
		bare.enter_room(cell)
	await host.get_tree().process_frame
	game.ui.apply_now()
	eq(game.run.run_log, bare.run_log, "same log")
	eq(game.run.state.run_hash(), bare.state.run_hash(), "same run hash")


## A broken policy never stops the game: no UI, an error label naming the problem, runs still start (console, tests).
func test_ui_policy_missing() -> void:
	var game := _game(UIPolicy.new())
	eq(game.ui, null, "no UI manager")
	var label := game.get_node_or_null("UI/UIError") as Label
	check(label != null and label.text.contains("no layout"), "an error label says why")
	eq(game.start_run(PARTY, "1"), "", "a run still starts")


## Presentation check (reads res://presentation/): the demo UI policy is valid.
func test_demo_ui_policy() -> void:
	if not ResourceLoader.exists(GameMain.UI_POLICY):
		print("    skipped: no %s" % GameMain.UI_POLICY)
		return
	var issues := UIPolicyCheck.validate(load(GameMain.UI_POLICY))
	eq(issues.map(func(issue) -> String: return str(issue)), [], "the demo UI policy has no errors")
