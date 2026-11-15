## Demo sound board: UI sounds and run/battle stingers. Each sound is a child AudioStreamPlayer named after its use
## (swap the stream in sound_board.tscn to change it). Other sounds live elsewhere, the GAS way:
##   ability sounds  → an audio track on the ability's animation (content/demo/animations/), on the cube's Audio node;
##   battle sounds   → Cue.Sfx.* GameplayCues (presentation/demo/cues/sfx/): impacts by damage type, statuses, death and the
##                     other battle moments, from presentation/demo/fx/sfx_rules.tres and the effects' cue tags (spec audio-pass).
## Every player plays a bank entry (presentation/audio/sfx/bank/) on the Ui bus (spec audio-pass 3.5).
## Screens play one with get_tree().call_group("sound_board", "play", "Item"), or broadcast a message it listens to
## (Message.Battle.Started → BattleStart, Message.Run.ItemTaken → Item, Message.Run.KeyFound → Key, Message.Run.LevelsGained →
## LevelUp (one per action), Message.Run.CoinsGained → Coin, Message.Run.RoomUnlocked → Key for the room entered next,
## Message.Run.FloorEntered → Floor, Message.Ui.Refused → Refused). A button with metadata
## sound = "back" plays Back instead of Confirm; the No of a confirm dialog plays PopupNo. A confirm dialog opening plays
## PopupOpen, the run menu (the GameMenu layer) opening and closing MenuOpen / MenuClose, an event's next page Advance. Gaining
## ult charge plays nothing (user, 2026-11-15).
extends Node

var _main: GameMain


func setup(main: GameMain) -> void:
	_main = main
	add_to_group("sound_board")
	_hook_all(get_tree().root)
	get_tree().node_added.connect(_on_node_added)
	main.run_changed.connect(_bind)
	# Spec gameplay-messages: stingers from the message bus (this node owns the listeners).
	GameplayMessages.listen(GameplayMessageRouter.BATTLE_STARTED, func(_c, _m): play("BattleStart"))
	GameplayMessages.listen(GameplayMessageRouter.RUN_ITEM_TAKEN, func(_c, _m): play("Item"))
	GameplayMessages.listen(GameplayMessageRouter.RUN_CHEST_OPENED, func(_c, _m): play("Item"))  # spec floor-chests: Open sounds
	GameplayMessages.listen(GameplayMessageRouter.UI_REFUSED, func(_c, _m): play("Refused"))
	# Spec audio-pass 3.5: run sounds.
	GameplayMessages.listen(GameplayMessageRouter.RUN_KEY_FOUND, func(_c, _m): play("Key"))
	GameplayMessages.listen(GameplayMessageRouter.RUN_LEVELS_GAINED, func(_c, _m): play("LevelUp"))  # once per action
	GameplayMessages.listen(GameplayMessageRouter.RUN_COINS_GAINED, func(_c, _m): play("Coin"))
	GameplayMessages.listen(GameplayMessageRouter.RUN_ROOM_UNLOCKED, func(_c, _m): _unlocked = true)
	GameplayMessages.listen(GameplayMessageRouter.RUN_FLOOR_ENTERED, func(_c, _m): play("Floor"))
	_connect_ui.call_deferred()  # GameMain builds its UI after the views (this node is set up first)


## The last sounds asked for, newest last (for the tests and the console; capped).
var history: PackedStringArray = []


func play(sound_name: String) -> void:
	history.append(sound_name)
	if history.size() > 32:
		history.remove_at(0)
	var player := get_node_or_null(sound_name) as AudioStreamPlayer
	if player != null and player.stream != null:
		player.play()


## Set by Message.Run.RoomUnlocked, which comes just before that room's room_entered: the entry then plays Key, not Move.
var _unlocked: bool = false
var _menu_open: bool = false
var _ui_connected: bool = false


func _connect_ui() -> void:
	if _ui_connected or _main == null or _main.ui == null:
		return
	_ui_connected = true
	_main.ui.confirm_opened.connect(play.bind("PopupOpen"))
	_main.ui.stack_changed.connect(_on_stack_changed)


func _bind(run: RunController) -> void:
	_unlocked = false  # an unlock heard before this run (another run on the bus) is not this run's
	# A Continue or a resume re-sends these for things that already happened (RunController.announcing): no sound then.
	run.room_entered.connect(func(_cell):
		_play_move.call_deferred(run, _unlocked, run.announcing)
		_unlocked = false)
	run.event_page_shown.connect(func(_event, page): if page > 0 and not run.announcing: play("Advance"))


## The room sound waits until enter_room is done: a room that starts a battle plays BattleStart instead; a locked room opened
## with a key plays Key.
func _play_move(run: RunController, unlocked: bool, announced: bool) -> void:
	if not is_instance_valid(run) or announced:
		return
	if unlocked:
		play("Key")
	elif run.pending_battle.is_empty():
		play("Move")


## The run menu (the GameMenu layer) opening and closing.
func _on_stack_changed(layer: StringName) -> void:
	if layer != UIManager.GAME_MENU or _main == null or _main.ui == null:
		return
	var open := _main.ui.top(UIManager.GAME_MENU) != null
	if open != _menu_open:
		_menu_open = open
		play("MenuOpen" if open else "MenuClose")


func _hook_all(node: Node) -> void:
	_on_node_added(node)
	for child in node.get_children():
		_hook_all(child)


func _on_node_added(node: Node) -> void:
	if node is BaseButton and not node.has_meta("_sound_hooked"):
		node.set_meta("_sound_hooked", true)
		node.mouse_entered.connect(_on_hover.bind(node))
		node.pressed.connect(_on_pressed.bind(node))


func _on_hover(button: BaseButton) -> void:
	if not button.disabled:
		play("Hover")


func _on_pressed(button: BaseButton) -> void:
	var dialog := _confirm_of(button)
	if dialog != null and dialog.get_node_or_null("%No") == button:
		play("PopupNo")
		return
	play("Back" if button.get_meta("sound", "") == "back" else "Confirm")


func _confirm_of(node: Node) -> UIConfirm:
	var at := node.get_parent()
	while at != null:
		if at is UIConfirm:
			return at
		at = at.get_parent()
	return null
