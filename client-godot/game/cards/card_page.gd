## Spec card-ui 3.3: a page of cards (the Collection's 4 x 2, Hearthstone's collection viewer) on a 3D stage under 2D chrome. A grid
## of focusable 2D slots owns input and focus (mouse, keyboard and gamepad) and the chips ("Craft · 400", "In your run") and the NEW
## badge; each slot's CardView3D stands on the stage (FxStage, rendered at the screen's real pixels) where the slot is, through
## Camera3D.project_position. Showing another page frees the old views and their face viewports (faces render live, no cache).
## Presentation only.
class_name CardPage
extends Control

## A card was clicked, or Enter / Space pressed on it.
signal card_pressed(id: String)
## The pointer rested on a card for `seen_after` seconds (the NEW badge goes).
signal card_seen(id: String)
## The pointer or the focus came to a card (the description window previews it).
signal card_hovered(id: String)

@export var columns: int = 4
@export var rows: int = 2
@export var gap: Vector2 = Vector2(18, 26)
## Room under a card for its chip.
@export var chip_room: float = 18.0
@export var seen_after: float = 0.5
## How far the 3D stage reaches past the page on every side, as a share of the page's larger side: a hovered card lifts, grows
## and tilts past its slot, and a stage the page's exact size would cut it off in a box (playtest 2026-11-18).
@export var stage_bleed: float = 0.12
@export var chip_craft_text: String = "Craft · %d"
@export var chip_locked_text: String = "In your run"
@export var new_text: String = "NEW"
## The NEW badge's text colour.
@export var new_color: Color = Color("ffc23d")
## False: no chips and no NEW badge (the card detail shows its state in its facts window).
@export var show_badges: bool = true
## The "Craft · cost" chip under a missing card (off since the playtest of 2026-11-18: the detail shows the cost).
@export var show_craft_chip: bool = false
## False: the cards take no focus and no clicks, they only tilt under the pointer (the card detail: its buttons have the focus).
@export var selectable: bool = true

var stage: FxStage
var _paused: bool = false
## The face render scale the last placement used (a new view starts at it, so it renders once at the right size).
var _render_scale: float = 1.0
## card id → CardView3D (the cards on this page).
var views: Dictionary = {}
## card id → the card's own Control: focus, clicks, hover, its chip and NEW badge. Exactly the card's size and place, so a click
## in the gap between cards opens nothing (playtest 2026-11-18).
var slots: Dictionary = {}
## card id → its grid cell (layout only, ignores the mouse).
var _cells: Dictionary = {}
var _grid: GridContainer
var _entries: Array[Dictionary] = []
var _place_queued: bool = false
var _scene: PackedScene
var _style: CardStyle
var _depth: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage = FxStage.new()
	stage.name = "Stage"
	add_child(stage)
	_grid = GridContainer.new()
	_grid.name = "Slots"
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_grid)


func _ready() -> void:
	stage.match_screen_pixels()
	_grid.columns = columns
	_grid.add_theme_constant_override(&"h_separation", int(gap.x))
	_grid.add_theme_constant_override(&"v_separation", int(gap.y))
	_grid.sort_children.connect(_queue_place)
	resized.connect(_fit_stage)
	resized.connect(_queue_place)
	_fit_stage()
	stage.viewport.size_changed.connect(_queue_place)


## Shows `entries` (CollectionModel entries, at most columns x rows) drawn by `scene` in `style`. A card still on the page keeps its
## view (its face is not rendered again: review fix, a search keystroke used to rebuild all eight); the others leave with their
## viewports. The slots (2D: chips, badges, focus) are rebuilt; the focus stays on its card when it is still here.
func show_entries(entries: Array[Dictionary], style: CardStyle, scene: PackedScene) -> void:
	var restyled := style != _style or scene != _scene
	_entries = entries
	_scene = scene
	_style = style
	var wanted := {}
	for index in mini(entries.size(), columns * rows):
		wanted[entries[index]["id"]] = entries[index]
	var focused := ""
	for id in slots:
		if slots[id].has_focus():
			focused = id
	for id in views.keys():
		if restyled or not wanted.has(id) or views[id].face != wanted[id]["face"]:
			views[id].queue_free()
			views.erase(id)
	for cell in _cells.values():
		_grid.remove_child(cell)
		cell.queue_free()
	_cells.clear()
	slots.clear()
	for id in wanted:
		var entry: Dictionary = wanted[id]
		var cell := _make_cell(entry)
		_grid.add_child(cell)
		_cells[id] = cell
		var slot: Control = cell.get_node("Card")
		slots[id] = slot
		var view: CardView3D = views.get(id)
		if view == null:
			view = CardView3D.new()
			view.name = "Card_" + str(id).replace(".", "_")
			stage.world_root.add_child(view)
			views[id] = view
			view.show_face(entry["face"], style, scene, 1.0, _render_scale)
		view.set_ghost(entry["state"] == CollectionModel.STATE_MISSING)
		if id == focused:
			slot.grab_focus.call_deferred()
	# Playtest 2026-11-18: a short page (a search with one match) keeps the full grid: empty cells hold the other places, so the
	# cards stay the size and place they have on a full page.
	for index in range(wanted.size(), columns * rows):
		var filler := Control.new()
		filler.name = "Empty%d" % index
		filler.mouse_filter = Control.MOUSE_FILTER_IGNORE
		filler.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		filler.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_grid.add_child(filler)
		_cells[&"_empty_%d" % index] = filler
	set_paused(_paused)
	_queue_place()


## Review fix: while a screen covers the page (the card detail), its stage and live faces stop rendering; the last picture stays.
func set_paused(on: bool) -> void:
	_paused = on
	stage.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED if on else SubViewport.UPDATE_WHEN_VISIBLE
	for view in views.values():
		if on:
			view.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		else:
			view.redraw()


## The entries on this page.
func entries() -> Array[Dictionary]:
	return _entries


## The first card's Control (for the focus after a page change), or null.
func first_slot() -> Control:
	var cell := _grid.get_child(0) as Control if _grid.get_child_count() > 0 else null
	return cell.get_node_or_null("Card") as Control if cell != null else null


## Hides the NEW badge of `id`.
func clear_new(id: String) -> void:
	var slot: Control = slots.get(id)
	if slot != null and slot.has_node("New"):
		slot.get_node("New").visible = false


## A grid cell (layout only) holding the card's own Control, "Card", which _place sizes to the card.
func _make_cell(entry: Dictionary) -> Control:
	var cell := Control.new()
	cell.name = "Slot_" + str(entry["id"]).replace(".", "_")
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cell.resized.connect(_queue_place)
	var slot := Control.new()
	slot.name = "Card"
	slot.focus_mode = Control.FOCUS_ALL if selectable else Control.FOCUS_NONE
	slot.mouse_filter = Control.MOUSE_FILTER_STOP   # also when not selectable: the tilt follows the pointer
	slot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if selectable else Control.CURSOR_ARROW
	cell.add_child(slot)
	slot.set_meta(&"card_id", entry["id"])
	var chip := ""
	if not show_badges:
		pass
	elif show_craft_chip and entry["state"] == CollectionModel.STATE_MISSING and int(entry.get("craft", 0)) > 0:
		chip = chip_craft_text % int(entry["craft"])
	elif entry.get("locked", false):
		chip = chip_locked_text
	if chip != "":
		var label := Label.new()
		label.name = "Chip"
		label.text = chip
		label.theme_type_variation = &"StatusChip"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(label)
	if show_badges and entry.get("new", false):
		var badge := Label.new()
		badge.name = "New"
		badge.text = new_text
		badge.theme_type_variation = &"StatusChip"
		badge.add_theme_color_override(&"font_color", new_color)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(badge)
	var id := str(entry["id"])
	slot.gui_input.connect(_on_slot_input.bind(slot, id))
	slot.mouse_entered.connect(_on_slot_entered.bind(slot, id))
	slot.mouse_exited.connect(_on_slot_exited.bind(id))
	slot.focus_entered.connect(_on_slot_focus.bind(slot, id, true))
	slot.focus_exited.connect(_on_slot_focus.bind(slot, id, false))
	slot.draw.connect(_draw_slot.bind(slot))
	return cell


## The card's rect inside its grid cell (5:7, centred, above the chip room).
func card_rect(cell: Control) -> Rect2:
	var room := cell.size - Vector2(0, chip_room)
	var ratio := CardFaceView.SIZE.x / CardFaceView.SIZE.y
	var height := minf(room.y, room.x / ratio)
	var width := height * ratio
	return Rect2(Vector2((cell.size.x - width) * 0.5, (room.y - height) * 0.5), Vector2(width, height))


func _draw_slot(slot: Control) -> void:
	if slot.has_focus():
		var focus := get_theme_stylebox(&"focus", &"Button")
		if focus != null:
			slot.draw_style_box(focus, Rect2(Vector2.ZERO, slot.size).grow(4))


## The stage covers the page plus `stage_bleed` on every side (it ignores the mouse; the slots stay the page's).
func _fit_stage() -> void:
	var bleed := maxf(size.x, size.y) * stage_bleed
	stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	stage.offset_left = -bleed
	stage.offset_top = -bleed
	stage.offset_right = bleed
	stage.offset_bottom = bleed


func _queue_place() -> void:
	if not _place_queued:
		_place_queued = true
		_place.call_deferred()


## Puts each view where its slot is, sized to it, and its face rendered at the card's real size on screen.
func _place() -> void:
	_place_queued = false
	if not is_inside_tree() or stage.camera == null or not stage.camera.is_inside_tree():
		return
	var camera := stage.camera
	var viewport_height := float(stage.viewport.size.y)
	if viewport_height <= 0.0:
		return
	_depth = camera.position.z
	var world_per_pixel := 2.0 * _depth * tan(deg_to_rad(camera.fov) * 0.5) / viewport_height
	var ratio := stage.pixel_ratio()
	for id in slots:
		var slot: Control = slots[id]
		var cell: Control = _cells[id]
		var view: CardView3D = views.get(id)
		if view == null:
			continue
		var rect := card_rect(cell)
		slot.position = rect.position
		slot.size = rect.size
		for child in slot.get_children():
			if child.name == "Chip":
				child.size = Vector2(minf(rect.size.x, child.get_minimum_size().x + 12), child.get_minimum_size().y)
				child.position = Vector2(rect.size.x * 0.5 - child.size.x * 0.5, rect.size.y - child.size.y * 0.5)
			elif child.name == "New":
				child.size = child.get_minimum_size()
				child.position = Vector2(rect.size.x - child.size.x + 6, -8)
		var center := cell.global_position + rect.get_center() * cell.get_global_transform().get_scale() - stage.global_position
		var at := stage.to_viewport(center / stage.get_global_transform().get_scale())
		view.position = camera.project_position(at, _depth)
		var pixels := rect.size.y * ratio   # the card's height in screen pixels
		var viewport_pixels := rect.size.y * viewport_height / maxf(stage.size.y, 1.0)   # ... and in the stage's viewport
		view.set_height(viewport_pixels * world_per_pixel)
		_render_scale = CardView3D.clamp_scale(pixels / CardFaceView.SIZE.y)   # review fix: compared clamped, or it redraws forever
		if absf(view.render_scale - _render_scale) > 0.05:
			view.set_render_scale(_render_scale)


func _on_slot_input(event: InputEvent, slot: Control, id: String) -> void:
	if event is InputEventMouseMotion:
		_point(slot, id, event.position)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		slot.accept_event()   # never through to what lies under (the detail's dim closes it)
		if selectable:
			card_pressed.emit(id)
	elif selectable and event.is_action_pressed(&"ui_accept"):
		slot.accept_event()
		card_pressed.emit(id)


func _point(slot: Control, id: String, at: Vector2) -> void:
	var view: CardView3D = views.get(id)
	if view == null:
		return
	var half := slot.size * 0.5
	if half.x <= 0.0 or half.y <= 0.0:
		return
	view.set_pointer((at - half) / half, Rect2(Vector2.ZERO, slot.size).has_point(at))


func _on_slot_entered(slot: Control, id: String) -> void:
	card_hovered.emit(id)
	_point(slot, id, slot.get_local_mouse_position())
	if not is_inside_tree():
		return
	await get_tree().create_timer(seen_after).timeout
	if is_instance_valid(slot) and slot.is_inside_tree() and slot.get_global_rect().has_point(slot.get_global_mouse_position()):
		card_seen.emit(id)


func _on_slot_exited(id: String) -> void:
	var view: CardView3D = views.get(id)
	if view != null:
		view.set_pointer(Vector2.ZERO, false)


func _on_slot_focus(slot: Control, id: String, focused: bool) -> void:
	slot.queue_redraw()
	var view: CardView3D = views.get(id)
	if view != null:
		view.set_raised(focused)
	if focused:
		card_hovered.emit(id)
