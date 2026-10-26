## Spec ui-framework 2.4: Back as a button (same as Esc): closes the screen on top, the one below comes back.
class_name UIBackButton
extends Button


func _ready() -> void:
	set_meta("sound", "back")
	pressed.connect(_back)


func _back() -> void:
	var context := UIScreen.context_of(self)
	if context != null:
		context.ui.back()
