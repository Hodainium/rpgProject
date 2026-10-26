## HUD panel (UI.Slot.Hud.Right while UI.State.Run.Stairs): Next floor, or at a choice of routes
## (UI.State.Run.Stairs.Choice) one button per chapter.
extends UIScreen

@export var route_format: String = "%s stairs: %s"
## Shown for a chapter without a route tag.
@export var no_route_name: String = "Take the"


func bind(_context: UIContext) -> void:
	%NextFloor.pressed.connect(func(): ctx.run.next_floor())


func refresh() -> void:
	var run := ctx.run
	if run == null or run.state == null:
		return
	var choices := run.next_floor_choices()
	%NextFloor.visible = choices.is_empty()
	%Routes.set_items(choices.map(func(chapter: ChapterDefinition) -> Dictionary:
		var route := String(chapter.route_tag).get_slice(".", 1) if chapter.route_tag != &"" else no_route_name
		return {"text": route_format % [route, chapter.display_name], "action": func(): run.next_floor(chapter.id)}))
