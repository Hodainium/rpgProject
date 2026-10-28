## Spec ui-fixes: the menu frame's layout under the demo UI policy on fixture content (presentation, direction only).
## B1: the description window is never covered by the content below it (three lines, and a long text that wraps).
## B2: the Use Item and Use Ability list takes at most half of the space above the party window.
extends TestCase

const PARTY: String = "fixture.character.knight,fixture.character.medic"
const USE_SCREEN: String = "res://presentation/demo/ui/use_screen.tscn"

var _games: Array[GameMain] = []


func after_each() -> void:
	for game in _games:
		if is_instance_valid(game):
			game.free()
	_games.clear()
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


func _description_clear(screen: Control, what: String) -> void:
	var window: Control = screen.get_node("%Description")
	var content: Control = screen.get_node("%Content")
	var bottom := window.get_global_rect().end.y
	check(bottom + screen.content_gap <= content.get_global_rect().position.y,
		"%s: the description ends (y %d) a gap above the content (y %d)" % [what, bottom,
		content.get_global_rect().position.y])


func test_description_never_covered() -> void:
	var game := await _game()
	var use = game.ui.push(&"UI.Layer.GameMenu", load(USE_SCREEN), {"mode": "item"})
	use.describe({"name": "Potion", "text": "Short."})
	await _frames(2)
	var top_before: float = use.get_node("%Content").offset_top
	use.describe({"name": "Potion", "kind": "[Field and Battles]", "text": "The party heals 250 HP.",
		"extra": "Held by: Knight"})
	await _frames(2)
	_description_clear(use, "three lines")
	eq(use.get_node("%Content").offset_top, top_before, "three lines fit the slot: the content does not move")
	use.describe({"name": "Potion", "kind": "[Field and Battles]", "text": "A long text that wraps. ".repeat(12),
		"extra": "Held by: Knight"})
	await _frames(2)
	_description_clear(use, "a text that wraps")
	check(use.get_node("%Content").offset_top > top_before, "the content moved down for the taller window")
	use.describe({"name": "Potion", "text": "Short."})
	await _frames(2)
	eq(use.get_node("%Content").offset_top, top_before, "and back up when it is short again")


func test_list_takes_half() -> void:
	var game := await _game()
	for mode in ["item", "ability"]:
		var use = game.ui.push(&"UI.Layer.GameMenu", load(USE_SCREEN), {"mode": mode})
		if mode == "ability":
			use._on_member(game.run.state.party[0]["slot"])
		await _frames(2)
		var stack: VBoxContainer = use.get_node("%Stack")
		var list: Control = stack.get_node("ListWindow")
		var party: Control = stack.get_node("PartyWindow")
		var room := stack.size.y - party.size.y
		check(list.size.y <= room / 2.0, "%s: the list is %d of %d px above the party window, at most half"
			% [mode, list.size.y, room])
		check(list.size.y > 0.0, "%s: and still shows" % mode)
		eq(party.position.y + party.size.y, stack.size.y, "%s: the party window stays at the bottom" % mode)
		game.ui.back()
		await _frames(2)
