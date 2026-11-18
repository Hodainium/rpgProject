## Spec ui-framework 2.4: the yes/no dialog behind ctx.ui.confirm(text) (Lyra: the messaging subsystem's confirmation).
## Your dialog scene uses this script and names its nodes %Text, %Yes and %No (any may be missing); Back answers No.
class_name UIConfirm
extends UIScreen

signal decided(yes: bool)


func on_pushed(payload: Dictionary) -> void:
	var text := get_node_or_null("%Text") as Label
	if text != null:
		text.text = str(payload.get("text", ""))
	for pair in [["%Yes", "yes", true], ["%No", "no", false]]:
		var button := get_node_or_null(pair[0]) as Button
		if button != null:
			button.text = str(payload.get(pair[1], button.text))
			button.visible = button.text != ""  # notify(): a notice with one button
			button.pressed.connect(func(): decided.emit(pair[2]), CONNECT_ONE_SHOT)
	if is_notice():
		# Review fix: the focus moves to OK, never stays underneath (Enter would press the Shop's Buy again).
		UIScreen._focus_later.call_deferred(get_node("%Yes"))  # skipped when a newer notice replaced it meanwhile


## A notice: one button (No hidden), from UIManager.notify.
func is_notice() -> bool:
	var no := get_node_or_null("%No") as Button
	var yes := get_node_or_null("%Yes") as Button
	return no != null and not no.visible and yes != null and yes.visible


## Review fix: a notice (No hidden, nothing focused) still closes on Enter / ui_accept.
func _unhandled_input(event: InputEvent) -> void:
	if active and is_notice() and event.is_action_pressed(&"ui_accept"):
		get_viewport().set_input_as_handled()
		decided.emit(true)


func handles_back() -> bool:
	decided.emit(false)
	return true
