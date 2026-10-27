## Spec auto-battle 6: the battle panel's Auto button (presentation/demo/ui/battle_panel) drives GameMain.auto_battle:
## pressing it takes the waiting decision at once and clears the choices, Auto plays the battle, the button shows Auto
## still on in the next battle of the run, and turning it off hands the next decision back with its choices shown.
## Fixture content under the demo UI policy; the console's own auto stays off.
extends TestCase

const PARTY: String = "fixture.character.knight,fixture.character.medic"

var _games: Array[GameMain] = []


func after_each() -> void:
	for game in _games:
		if is_instance_valid(game):
			game.free()
	_games.clear()
	super()


func test_panel_auto_button() -> void:
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
	eq((await console.execute("new %s 7" % PARTY))["ok"], true, "a run starts")
	check(not game.auto_battle, "a headless run starts with Auto off")
	eq((await console.execute("spawn fixture.encounter.pack"))["ok"], true, "a battle starts")
	await _until(func() -> bool: return game.recorder != null and game.recorder.waiting_for != &"")
	var auto := game.find_child("Auto", true, false) as BaseButton
	var actions := (auto.owner.get_node_or_null("%Actions") if auto != null else null) as Container  # the field panel has an Actions list too
	check(auto != null and actions != null, "the battle panel is up")
	if auto == null or actions == null:
		return
	check(not auto.button_pressed, "the button shows Auto off")
	check(actions.get_child_count() > 0, "the waiting member's choices are shown")
	var recorder := game.recorder

	auto.button_pressed = true  # the player presses Auto
	check(game.auto_battle and recorder.autopilot != null, "the button turns on GameMain's Auto")
	eq(actions.get_child_count(), 0, "Auto takes the waiting decision: its choices are cleared")
	await _until(func() -> bool: return game.run.pending_battle.is_empty())
	check(game.run.pending_battle.is_empty(), "Auto finished the battle")
	check(recorder.auto_picks > 0 and recorder.auto_picks == recorder.entries.size(),
		"every pick was Auto's: %d of %d" % [recorder.auto_picks, recorder.entries.size()])

	eq((await console.execute("spawn fixture.encounter.pack"))["ok"], true, "a second battle starts")
	await _until(func() -> bool: return game.recorder != recorder and game.recorder.auto_picks > 0)
	auto = game.find_child("Auto", true, false) as BaseButton
	actions = (auto.owner.get_node_or_null("%Actions") if auto != null else null) as Container
	check(auto != null and auto.button_pressed, "the button shows Auto still on in the next battle")
	if auto == null:
		return
	auto.button_pressed = false  # the player takes over
	check(not game.auto_battle and game.recorder.autopilot == null, "the button turns Auto off")
	await _until(func() -> bool: return game.recorder.waiting_for != &"" or game.run.pending_battle.is_empty())
	if not game.run.pending_battle.is_empty():
		check(actions.get_child_count() > 0, "the next decision waits for the player with its choices shown")


## Waits up to 3000 frames for `done`.
func _until(done: Callable) -> void:
	for frame in 3000:
		if done.call():
			return
		await host.get_tree().process_frame
