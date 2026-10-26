## HUD overlay (UI.Slot.Hud.Overlay while UI.State.Run): "Floor 9 · The Silent Cathedral" for `seconds` on each new
## floor (Message.Run.FloorEntered), real time (the battle speed never shortens it). Leaving the map (an event, a
## battle) hides it.
extends UIScreen

@export var card_format: String = "Floor %d  ·  %s"
@export var seconds: float = 2.0

## [run, floor] the card was last shown for, so re-activation doesn't show it twice.
var _shown_for: Array = []
var _serial: int = 0


func bind(context: UIContext) -> void:
	GameplayMessages.listen(GameplayMessageRouter.RUN_FLOOR_ENTERED, func(_channel, _message): _show())
	context.state_changed.connect(func(_tags):
		if not ctx.has_state(UIState.MAP):
			%Text.visible = false)


func on_activated() -> void:
	_show()


func _show() -> void:
	var run := ctx.run
	if run == null or run.state == null or [run, run.state.floor_index] == _shown_for:
		return
	_shown_for = [run, run.state.floor_index]
	var chapter := run.chapter()
	%Text.text = card_format % [run.state.floor_index + 1, chapter.display_name if chapter != null else ""]
	%Text.visible = true
	_serial += 1
	var serial := _serial
	await get_tree().create_timer(seconds, true, false, true).timeout
	if serial == _serial and is_instance_valid(self):
		%Text.visible = false
