## Spec ui-framework 2.4: a button that opens a screen on a layer, set up in the inspector (a menu inside a menu, no
## code). Entries may fill `payload` in set_item (the class card passes its character).
class_name UIPushButton
extends Button

@export var screen: PackedScene
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var layer: StringName = &"UI.Layer.Menu"
@export var payload: Dictionary = {}


func _ready() -> void:
	pressed.connect(_open)


func _open() -> void:
	var context := UIScreen.context_of(self)
	if context != null and screen != null:
		context.ui.push(layer, screen, payload)
