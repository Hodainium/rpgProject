## Spec ff7-ui 2.11 / F17: the big map's legend (HELP), on the Modal layer, which dims everything behind it. Only the
## room-type icons; CLOSE, Esc or a click outside the window closes it.
extends UIScreen

@export var tiles_text: String = "Your room is the gold tile. Visited rooms are navy; unexplored rooms are darker."


func bind(_context: UIContext) -> void:
	gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
				and not %Window.get_global_rect().has_point(event.position):
			ctx.ui.back())
	%Tiles.text = tiles_text
	for kind in DemoMapIcons.LEGEND:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var tile := PanelContainer.new()
		tile.theme_type_variation = &"LegendTile"
		tile.custom_minimum_size = Vector2(40, 40)
		var icon := TextureRect.new()
		icon.texture = DemoMapIcons.icon(kind)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(26, 26)
		tile.add_child(icon)
		row.add_child(tile)
		var label := Label.new()
		label.text = DemoMapIcons.LONG_NAMES.get(kind, kind)
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(label)
		%Rows.add_child(row)
