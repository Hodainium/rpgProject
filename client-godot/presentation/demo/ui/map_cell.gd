## Spec ff7-ui 2.11 (shared component): one room of the minimap, the Tab view and the big map. Item keys: "tile"
## ("here", "visited", "unexplored", "empty"), "icon" (a Texture2D or null), "name" (shown under the icon when
## "show_name"), "size" (px), "action" and "hover" (Callables), "disabled".
extends Button


func _ready() -> void:
	pressed.connect(func():
		var action: Callable = get_meta("action", Callable())
		if action.is_valid():
			action.call())
	mouse_entered.connect(_hover)
	focus_entered.connect(_hover)


func set_item(item: Dictionary, _ctx: UIContext) -> void:
	var side := float(item.get("size", 22))
	custom_minimum_size = Vector2(side, side)
	var tile: String = item.get("tile", "empty")
	theme_type_variation = {"here": &"MapTileHere", "visited": &"MapTile", "unexplored": &"MapTileUnexplored"}.get(
		tile, &"MapTileEmpty")
	%Icon.texture = item.get("icon", null)
	%Icon.visible = %Icon.texture != null
	%Icon.custom_minimum_size = Vector2(side, side) * (0.42 if item.get("show_name", false) else 0.62)
	%Name.text = str(item.get("name", "")) if item.get("show_name", false) else ""
	%Name.visible = %Name.text != ""
	disabled = item.get("disabled", tile == "empty")
	mouse_filter = Control.MOUSE_FILTER_IGNORE if tile == "empty" else Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE if disabled else Control.FOCUS_ALL
	set_meta("action", item.get("action", Callable()))
	set_meta("hover", item.get("hover", Callable()))
	# The console's `ui press room` reaches the first room; a named room also answers to its name (ITEM, BOSS…).
	set_meta("ui_text", str(item.get("name", "")) if str(item.get("name", "")) != "" else ("room" if tile != "empty" else ""))


func _hover() -> void:
	var hover: Callable = get_meta("hover", Callable())
	if hover.is_valid():
		hover.call()
