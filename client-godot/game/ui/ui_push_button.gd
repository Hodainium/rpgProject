## Spec ui-framework 2.4: a button that opens a screen on a layer, set up in the inspector (a menu inside a menu, no
## code). Entries may fill `payload` in set_item (the class card passes its character).
class_name UIPushButton
extends Button

@export var screen: PackedScene
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var layer: StringName = &"UI.Layer.Menu"
@export var payload: Dictionary = {}
## Playtest-fixes B25: open on the layer of the screen this button sits in, whatever that is (a sub-menu of a screen that
## opens on more than one layer: Settings from the main menu and from the run menu). Falls back to `layer` outside a stack.
@export var same_layer: bool = false


func _ready() -> void:
	pressed.connect(_open)


func _open() -> void:
	var context := UIScreen.context_of(self)
	if context != null and screen != null:
		context.ui.push(target_layer(), screen, payload)


## The layer the screen opens on: with `same_layer`, the stack of the screen this button sits in, when that stack pops on Back
## (a button in a HUD panel, on the Game layer that never pops, keeps `layer`, so its screen can always be closed).
func target_layer() -> StringName:
	if same_layer:
		var node: Node = get_parent()
		while node != null and not node is UIScreen:
			node = node.get_parent()
		var stack := node.get_parent() as UILayerStack if node != null else null
		if stack != null and stack.layer != &"" and stack.back_pops:
			return stack.layer
	return layer
