## The Dev autoload (spec dev-tools 3.2): hosts the console over every scene, toggled with the `dev_console` action
## (backtick, by physical key). Inert headless and in release builds: no UI, no input, so the headless verifier never
## runs dev code. The script runner and tests drive a DevConsole directly.
extends CanvasLayer

const ACTION: StringName = &"dev_console"
## The `clear` command's reply: the overlay empties its scrollback.
const CLEAR_REPLY: String = "<clear>"

var console: DevConsole
var _panel: PanelContainer
var _output: RichTextLabel
var _line: LineEdit
var _history_at: int = -1
var _completions: Array[String] = []
var _completion_at: int = -1
var _busy: bool = false


func _ready() -> void:
	layer = 128
	console = DevConsole.new(get_tree())
	console.cheats_allowed = cheats_allowed()
	if is_inert():
		set_process_input(false)
		return
	console.load_commands()
	console.load_history()
	_ensure_action()
	_build()
	console.message_logged.connect(func(line: String): _print("[color=gray]%s[/color]" % line.replace("[", "[lb]")))
	for warning in console.warnings:
		_print("[color=orange]warning: %s[/color]" % warning)


## Cheats work in local mode in debug builds (slice 2: and not while connected to a server).
func cheats_allowed() -> bool:
	return OS.is_debug_build()


## No console headless (the verifier, tests, the script runner) or in a release build.
static func is_inert() -> bool:
	return DisplayServer.get_name() == "headless" or not OS.is_debug_build()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(ACTION) and not event.is_echo():
		_panel.visible = not _panel.visible
		if _panel.visible:
			_line.grab_focus()
		get_viewport().set_input_as_handled()


func _ensure_action() -> void:
	if InputMap.has_action(ACTION):
		return
	InputMap.add_action(ACTION)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_QUOTELEFT
	InputMap.action_add_event(ACTION, key)


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_panel.custom_minimum_size = Vector2(0, 360)
	var box := VBoxContainer.new()
	_output = RichTextLabel.new()
	_output.bbcode_enabled = true
	_output.scroll_following = true
	_output.selection_enabled = true
	_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_output.add_theme_font_override("normal_font", SystemFont.new())
	box.add_child(_output)
	_line = LineEdit.new()
	_line.placeholder_text = "help · Tab completes · Up/Down history · ` closes"
	_line.text_submitted.connect(_on_submit)
	_line.gui_input.connect(_on_input_key)
	box.add_child(_line)
	_panel.add_child(box)
	add_child(_panel)


func _on_submit(line: String) -> void:
	if _busy or line.strip_edges() == "":
		return
	_line.text = ""
	_history_at = -1
	_completions.clear()
	_print("[color=gray]> %s[/color]" % line.replace("[", "[lb]"))
	_busy = true
	var result: Dictionary = await console.execute(line)
	_busy = false
	if result["text"] == CLEAR_REPLY:
		_output.clear()
		return
	var text: String = str(result["text"]).replace("[", "[lb]")
	_print(text if result["ok"] else "[color=salmon]%s[/color]" % text)
	print("> ", line, "\n", result["text"])


func _on_input_key(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return
	match event.keycode:
		KEY_TAB:
			_complete()
			_line.accept_event()
		KEY_UP, KEY_DOWN:
			if console.history.is_empty():
				return
			var step := -1 if event.keycode == KEY_UP else 1
			_history_at = clampi((console.history.size() if _history_at < 0 else _history_at) + step, 0, console.history.size() - 1)
			_line.text = console.history[_history_at]
			_line.caret_column = _line.text.length()
			_line.accept_event()
		_:
			_completions.clear()


func _complete() -> void:
	if _completions.is_empty():
		_completions = console.complete(_line.text)
		_completion_at = -1
		if _completions.size() > 1:
			_print("[color=gray]%s[/color]" % "   ".join(_completions))
	if _completions.is_empty():
		return
	_completion_at = (_completion_at + 1) % _completions.size()
	_line.text = _completions[_completion_at]
	_line.caret_column = _line.text.length()


func _print(text: String) -> void:
	_output.append_text(text + "\n")
