## HUD panel (UI.Slot.Hud.Right while UI.State.Run.Stairs): Next floor, or at a choice of routes
## (UI.State.Run.Stairs.Choice) one button per chapter.
extends UIScreen

@export var route_format: String = "%s stairs: %s"
## Shown for a chapter without a route tag.
@export var no_route_name: String = "Take the"


## The panel takes this sibling's width in the HUD slot (the minimap), so Next floor is exactly as wide as the map
## (user, 2026-11-22). Empty or not found: its own width.
@export var match_width_of: StringName = &"MapPanel"


func bind(_context: UIContext) -> void:
	%NextFloor.pressed.connect(func(): ctx.run.next_floor())


## The map may join the slot after this panel, so the width is hooked up on refresh, once per map.
func _hook_width() -> void:
	var map := _width_source()
	if map != null and not map.resized.is_connected(_match_width):
		map.resized.connect(_match_width)
	_match_width()


func _width_source() -> Control:
	var parent := get_parent()
	return parent.get_node_or_null(NodePath(String(match_width_of))) as Control if parent != null and match_width_of != &"" else null


func _match_width() -> void:
	var map := _width_source()
	if map != null and map.get_combined_minimum_size().x > 0.0:
		custom_minimum_size.x = map.get_combined_minimum_size().x  # the map's own width, never what the slot stretched it to


func refresh() -> void:
	var run := ctx.run
	if run == null or run.state == null:
		return
	_hook_width()
	var choices := run.next_floor_choices()
	%NextFloor.visible = choices.is_empty()
	%Routes.set_items(choices.map(func(chapter: ChapterDefinition) -> Dictionary:
		var route := String(chapter.route_tag).get_slice(".", 1) if chapter.route_tag != &"" else no_route_name
		return {"text": route_format % [route, chapter.display_name], "action": func(): run.next_floor(chapter.id)}))
