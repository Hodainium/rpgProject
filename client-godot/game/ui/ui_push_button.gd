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
## Card-ui playtest (user, 2026-11-18): the screen needs the server (the Shop, Open packs). Pressed while not online, a dialog
## says `offline_text` with Go online (GameMain.go_online, behind the connecting pop-up; the screen opens once online) and Back.
@export var needs_online: bool = false
## With needs_online: debug builds (GameMain.debug_local_mode) open the screen offline too (New run: local runs are for testing).
@export var debug_skips_online: bool = false
@export var offline_text: String = "You must be online to open this."
@export var go_online_text: String = "Go online"
@export var back_text: String = "Back"
@export var ok_text: String = "OK"


func _ready() -> void:
	pressed.connect(_open)


func _open() -> void:
	var context := UIScreen.context_of(self)
	if context == null or screen == null:
		return
	if needs_online and context.main != null and not context.main.is_online() \
			and not (debug_skips_online and context.main.debug_local_mode):
		if not await context.ui.confirm(offline_text, go_online_text, back_text):
			return
		var error: String = await context.main.go_online()
		if not is_instance_valid(self) or not context.main.is_online():
			if error != "" and error != GameMain.GO_ONLINE_STOPPED and is_instance_valid(self):
				context.ui.notify(error, ok_text)
			return
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
