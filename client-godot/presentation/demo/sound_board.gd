## Demo sound board: UI sounds and run/battle stingers. Each sound is a child AudioStreamPlayer named after its use
## (swap the stream in sound_board.tscn to change it). Other sounds live elsewhere, the GAS way:
##   ability sounds  → an audio track on the ability's animation (content/demo/animations/), on the cube's Audio node;
##   hit sounds      → GameplayCue Cue.Sfx.Hit (godot_gas/cue_registry.tres), listed on the damage effect.
## Screens play one with get_tree().call_group("sound_board", "play", "Item"), or broadcast a message it listens to
## (Message.Battle.UnitDied → Death, Message.Run.ItemTaken → Item, Message.Ui.Refused → Refused). A button with
## metadata sound = "back" plays Back instead of Confirm.
extends Node

var _main: GameMain


func setup(main: GameMain) -> void:
	_main = main
	add_to_group("sound_board")
	_hook_all(get_tree().root)
	get_tree().node_added.connect(_on_node_added)
	main.run_changed.connect(_bind)
	# Spec gameplay-messages: stingers from the message bus (this node owns the listeners).
	GameplayMessages.listen(GameplayMessageRouter.BATTLE_UNIT_DIED, func(_c, _m): play("Death"))
	GameplayMessages.listen(GameplayMessageRouter.RUN_ITEM_TAKEN, func(_c, _m): play("Item"))
	GameplayMessages.listen(GameplayMessageRouter.UI_REFUSED, func(_c, _m): play("Refused"))


func play(sound_name: String) -> void:
	var player := get_node_or_null(sound_name) as AudioStreamPlayer
	if player != null and player.stream != null:
		player.play()


func _bind(run: RunController) -> void:
	run.room_entered.connect(func(_cell): _play_move.call_deferred(run))
	run.battle_started.connect(_on_battle_started)


## The room sound waits until enter_room is done: a room that starts a battle plays BattleStart instead.
func _play_move(run: RunController) -> void:
	if is_instance_valid(run) and run.pending_battle.is_empty():
		play("Move")


func _on_battle_started(_battle: Battle) -> void:
	play("BattleStart")


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
	play("Back" if button.get_meta("sound", "") == "back" else "Confirm")
