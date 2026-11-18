## Spec card-ui 6: the card gallery. A window scene showing every card of the content in the active look (CardStyle.face; Look B
## "Grimoire" since the user's pick of 2026-11-18), two rows of six a page. Page 1 is the showcase: one card of each rarity and a
## corrupted card, then Mythic characters and a piece of armor; the next pages walk every card in catalog order. Prev / Next (or
## the arrow keys) page; Esc quits.
##   godot --path client-godot --screen 1 res://game/dev/card_gallery.tscn [-- --page <n>] [--cards <id,id>] [--look <name>]
##     [--shots <dir>]   (saves one PNG per page, then quits; headless it only builds every page, no picture)
extends Control

const PER_ROW: int = 6
const ROWS: int = 2
const SHOWCASE: Array[String] = ["demo.item.battle_horn", "demo.item.analyzer_lens", "demo.item.frost_lantern",
	"demo.item.executioners_seal", "demo.character.warrior", "demo.item.corrupted_sigil",
	"demo.character.cleric", "demo.character.arcanist", "demo.character.bard", "demo.character.pyromancer",
	"demo.character.shatterweaver", "demo.equipment.headsmans_blade"]
const FONT: String = "res://presentation/demo/ui/fonts/ChakraPetch-SemiBold.ttf"
const FONT_BOLD: String = "res://presentation/demo/ui/fonts/ChakraPetch-Bold.ttf"

var style: CardStyle
var look: StringName
## The pages: {"title", "cards": Array of CardFace}.
var screens: Array = []
var page: int = 0
var _title: Label
var _page_label: Label
var _rows_box: VBoxContainer


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var content := ContentIndex.new(_arg(args, "--content-root", "res://content/"))
	style = CardStyle.current()
	look = StringName(_arg(args, "--look", String(style.face)))
	var faces := CardFaces.build(content, style)
	var by_id := {}
	for face in faces:
		by_id[face.id] = face
	var pick := func(ids: Array) -> Array:
		return ids.map(func(id: String) -> CardFace: return by_id.get(id)).filter(func(face) -> bool: return face != null)
	var only := Array(_arg(args, "--cards", "").split(",", false))
	if not only.is_empty():
		_add_pages("Cards", pick.call(only))
	else:
		screens.append({"title": "Showcase", "cards": pick.call(Array(SHOWCASE))})
		_add_pages("All cards", faces)
	page = clampi(int(_arg(args, "--page", "1")) - 1, 0, maxi(screens.size() - 1, 0))
	_build()
	_show_page()
	var shots := _arg(args, "--shots", "")
	if shots != "":
		await _save_pages(shots)
		get_tree().quit(0)


func _add_pages(title: String, faces: Array) -> void:
	for start in range(0, faces.size(), PER_ROW * ROWS):
		screens.append({"title": title, "cards": faces.slice(start, start + PER_ROW * ROWS)})


func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color("12131c")
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 40)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 18)
	margin.add_child(column)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override(&"separation", 16)
	column.add_child(bar)
	_title = _label("", 34, Color("ffe28a"), true)
	bar.add_child(_title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_page_label = _label("", 22, Color("a4a3ae"), false)
	bar.add_child(_page_label)
	for text in ["Prev", "Next"]:
		var button := Button.new()
		button.text = text
		button.add_theme_font_size_override(&"font_size", 22)
		button.custom_minimum_size = Vector2(110, 0)
		button.pressed.connect(_turn.bind(-1 if text == "Prev" else 1))
		bar.add_child(button)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override(&"separation", 24)
	column.add_child(_rows_box)
	resized.connect(_show_page)


func _label(text: String, font_size: int, colour: Color, bold: bool) -> Label:
	var label := Label.new()
	CardFaceView.dress(label, text, load(FONT_BOLD if bold else FONT), font_size, colour)
	return label


func _turn(step: int) -> void:
	if screens.is_empty():
		return  # --cards named no known card: nothing to page through
	page = posmod(page + step, screens.size())
	_show_page()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_right"):
		_turn(1)
	elif event.is_action_pressed(&"ui_left"):
		_turn(-1)
	elif event.is_action_pressed(&"ui_cancel"):
		get_tree().quit(0)


func _show_page() -> void:
	if _rows_box == null or screens.is_empty():
		return
	var screen: Dictionary = screens[page]
	var faces: Array = screen["cards"]
	_title.text = "Cards · %s" % screen["title"]
	_page_label.text = "Page %d / %d" % [page + 1, screens.size()]
	for child in _rows_box.get_children():
		child.queue_free()
	var available := Vector2(size.x - 80, (size.y - 130 - 24 * (ROWS - 1)) / ROWS)
	var zoom := minf((available.x - 40 * (PER_ROW - 1)) / (CardFaceView.SIZE.x * PER_ROW), available.y / (CardFaceView.SIZE.y + 30))
	zoom = maxf(zoom, 0.2)
	var scene := style.face_scene(look)
	for row_index in ROWS:
		var row := HBoxContainer.new()
		row.size_flags_vertical = Control.SIZE_EXPAND_FILL
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override(&"separation", 40)
		_rows_box.add_child(row)
		for face in faces.slice(row_index * PER_ROW, (row_index + 1) * PER_ROW):
			var slot := Control.new()
			slot.custom_minimum_size = CardFaceView.SIZE * zoom
			slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(slot)
			if scene == null:
				continue
			var view: CardFaceView = scene.instantiate()
			view.scale = Vector2(zoom, zoom)
			slot.add_child(view)
			view.show_face(face, style)


func _save_pages(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for index in screens.size():
		page = index
		_show_page()
		for frame in 6:
			await get_tree().process_frame
		if DisplayServer.get_name() == "headless":
			continue
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		image.save_png(dir.path_join("cards_page_%02d.png" % (index + 1)))
	print("card_gallery: %d page(s)" % screens.size())


func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
