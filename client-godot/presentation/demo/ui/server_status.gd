## Spec playtest-fixes B10 (a debug aid for now): the server link in the bottom left corner (UI.Slot.Overlay, always):
## "Connected: <player> (<player id>)" in bright green while the server answers, else a yellow line. Hidden in local
## mode.
extends UIScreen

@export var connected_format: String = "Connected: %s (%s)"
@export var waiting_format: String = "Connecting: %s…"
@export var offline_format: String = "Offline: %s (no answer from the server)"
@export var connected_color: Color = Color(0.25, 1.0, 0.35)
@export var offline_color: Color = Color(1.0, 0.8, 0.25)

var _server: ServerLink


func bind(context: UIContext) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if context.main == null:
		%Text.hide()
		return
	context.main.server_changed.connect(_watch)
	_watch(context.main.server)


func _watch(link: ServerLink) -> void:
	if _server != null and is_instance_valid(_server) and _server.connection_changed.is_connected(refresh):
		_server.connection_changed.disconnect(refresh)
	_server = link
	if _server != null:
		_server.connection_changed.connect(refresh)
	refresh()


func refresh() -> void:
	if _server == null or not is_instance_valid(_server):
		%Text.hide()
		return
	%Text.show()
	if _server.connected():
		%Text.text = connected_format % [_server.player, _server.player_id]
		%Text.add_theme_color_override(&"font_color", connected_color)
	else:
		%Text.text = (offline_format if _server.player_id != "" else waiting_format) % _server.player
		%Text.add_theme_color_override(&"font_color", offline_color)
