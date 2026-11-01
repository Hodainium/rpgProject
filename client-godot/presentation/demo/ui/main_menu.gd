## Main menu (Menu layer while UI.State.Menu; spec main-menu): Continue (with a Local / Synced tag and the run it
## continues), New run (the class pick, pushed on top; Back returns), Settings and Quit, and the mode line.
## Continue asks the server (server mode) or reads the local save; nothing resumes without a click.
extends UIScreen

@export var checking_text: String = "Checking the server…"
@export var reason_texts: Dictionary = {
	"none": "No run to continue",
	"unreachable": "Can't reach the server",
	"verifying": "The run is being verified",
	"unreadable": "The saved run couldn't be read",
}
@export var older_suffix: String = " (older version)"
@export var local_tag: String = "Local"
@export var synced_tag: String = "Synced"
@export var local_confirm: String = "This is a local save, played offline and not synced with the server. Continue it?"
@export var synced_confirm: String = "This run is synced with the server as %s. Continue it?"
## The server can't be reached but the server-mode save can be played (like Steam Cloud offline).
@export var offline_tag: String = "Not synced"
@export var offline_confirm: String = "This save hasn't been synced with the server. You can play it offline, but the server will deny it if its copy of the run is newer. Continue it?"
@export var local_tag_color: Color = Color(0.85, 0.7, 0.3)
@export var synced_tag_color: Color = Color(0.25, 1.0, 0.35)
@export var offline_color: Color = Color(1.0, 0.8, 0.25)

var _server: ServerLink
var _info: Dictionary = {}
var _generation: int = 0


func bind(context: UIContext) -> void:
	%Continue.pressed.connect(_continue)
	%Quit.pressed.connect(func(): context.main.get_tree().quit())
	%DeleteSave.pressed.connect(func():
		context.main.delete_local_save()
		refresh())
	context.main.server_changed.connect(_watch)
	context.main.mode_changed.connect(_mode_changed)
	_watch(context.main.server)


func _watch(link: ServerLink) -> void:
	if _server != null and is_instance_valid(_server) and _server.connection_changed.is_connected(_connection_changed):
		_server.connection_changed.disconnect(_connection_changed)
	_server = link
	if _server != null:
		_server.connection_changed.connect(_connection_changed)
	if active:
		refresh()


func _mode_changed(_mode: String) -> void:
	if active:
		refresh()


func _connection_changed() -> void:
	if active:
		refresh()


func on_activated() -> void:
	%Error.text = ""
	refresh()


func refresh() -> void:
	if ctx == null:
		return
	_generation += 1
	var generation := _generation
	%ModeLine.text = ctx.main.mode_line()
	if _server != null and is_instance_valid(_server):
		%ModeLine.add_theme_color_override(&"font_color", synced_tag_color if _server.connected() else offline_color)
	else:
		%ModeLine.remove_theme_color_override(&"font_color")
	%DeleteSave.hide()
	if ctx.main.server != null:
		_show({"enabled": false, "reason": "", "tag": "", "subtitle": checking_text, "older": false})
	var info: Dictionary = await ctx.main.can_continue()
	if generation != _generation or not is_instance_valid(self):
		return  # a newer refresh is on its way
	_show(info)
	if info["reason"] == "unreadable":
		%Error.text = reason_texts["unreadable"]


func _show(info: Dictionary) -> void:
	_info = info
	%Continue.disabled = not info["enabled"]
	%Tag.visible = info["enabled"]
	%Tag.text = (synced_tag if info["tag"] == "Synced" else offline_tag if info["tag"] == "Offline" else local_tag).to_upper()
	%Tag.add_theme_color_override(&"font_color", synced_tag_color if info["tag"] == "Synced" else \
		offline_color if info["tag"] == "Offline" else local_tag_color)
	if info["enabled"]:
		%ContinueInfo.text = info["subtitle"] + (older_suffix if info["older"] else "")
	else:
		%ContinueInfo.text = info["subtitle"] if info["subtitle"] != "" else str(reason_texts.get(info["reason"], ""))


func _continue() -> void:
	if not _info.get("enabled", false):
		return
	var tag: String = _info["tag"]
	var local: bool = tag == "Local"
	var text: String = local_confirm if local else offline_confirm if tag == "Offline" \
		else synced_confirm % (ctx.main.server.player if ctx.main.server != null else "")
	if not await ctx.ui.confirm(text):
		return
	var error: String
	if local:
		error = ctx.main.continue_local_run()
	elif tag == "Offline":
		error = ctx.main.continue_server_offline()
	else:
		error = await ctx.main.resume_server_run()
	if not is_instance_valid(self):
		return
	%Error.text = error
	%DeleteSave.visible = error != "" and local
