## Spec ff7-ui 2.12 (shared component): one row of any list window: a name on the left, a detail (a cost, "[item]",
## HP) on the right. Hover and focus call "hover" (the hint window follows), press calls "action". Item keys: "text",
## "detail", "action", "hover", "unhover" (Callables), optional "disabled", "variation" (ListEntry by default; CommandButton for
## the battle commands), "hidden", "sound" ("back" plays the Back sound).
extends Button

var _action: Callable
var _hover: Callable
var _unhover: Callable


func _ready() -> void:
	pressed.connect(func():
		if _action.is_valid():
			_action.call())
	mouse_entered.connect(_on_hover)
	focus_entered.connect(_on_hover)
	mouse_exited.connect(func():
		if _unhover.is_valid():
			_unhover.call())


func set_item(item: Dictionary, _ctx: UIContext) -> void:
	%Name.text = str(item.get("text", ""))
	%Detail.text = str(item.get("detail", ""))
	%Detail.visible = %Detail.text != ""
	_action = item.get("action", Callable())
	_hover = item.get("hover", Callable())
	_unhover = item.get("unhover", Callable())
	disabled = item.get("disabled", false)
	visible = not item.get("hidden", false)
	theme_type_variation = StringName(item.get("variation", &"ListEntry"))
	if disabled:
		%Name.theme_type_variation = &"Greyed"
	else:
		%Name.theme_type_variation = &"CommandText" if theme_type_variation == &"CommandButton" else &""
	set_meta("sound", item.get("sound", ""))
	set_meta("ui_text", %Name.text)  # the console's `ui press <text>` finds the entry by its label


func _on_hover() -> void:
	if _hover.is_valid() and not disabled:
		_hover.call()
