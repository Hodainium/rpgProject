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
			button.pressed.connect(func(): decided.emit(pair[2]), CONNECT_ONE_SHOT)


func handles_back() -> bool:
	decided.emit(false)
	return true
