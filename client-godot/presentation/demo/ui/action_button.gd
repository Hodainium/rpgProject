## UIList entry: one button from a plain item, so every list of choices (map cells, routes, event choices, field
## actions, abilities, targets, ults) uses this one scene. Item keys: "text", "action" (Callable, called on press),
## optional "disabled", "tooltip", "variation" (a theme type variation), "hidden" (keeps its place, can't be seen or
## pressed: a map spacer), "sound" ("back" plays the Back sound).
extends Button

var _action: Callable


func _ready() -> void:
	pressed.connect(func():
		if _action.is_valid():
			_action.call())


func set_item(item: Dictionary, _ctx: UIContext) -> void:
	text = str(item.get("text", ""))
	_action = item.get("action", Callable())
	disabled = item.get("disabled", false) or item.get("hidden", false)
	tooltip_text = str(item.get("tooltip", ""))
	theme_type_variation = StringName(item.get("variation", ""))
	self_modulate.a = 0.0 if item.get("hidden", false) else 1.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE if item.get("hidden", false) else Control.MOUSE_FILTER_STOP
	set_meta("sound", item.get("sound", ""))
