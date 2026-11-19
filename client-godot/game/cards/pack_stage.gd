## Spec card-ui 2.4 (Hearthstone's pack opening, our effects): the stage the pack opens on. A pack flies into the socket and pulses
## while the server answers (beat 1), bursts in its own colour (2), five cards fly out face down to Hearthstone's places (3), each
## glows its rarity (4: nothing for Common; only while hovered or selected), flips on a click, Enter, Space (the next) or Reveal all (5),
## and shows its rarity word and NEW or its dust under it (6). Every number, effect and sound is the style's PackChoreography.
## The cards are CardView3Ds on an FxStage; a focusable 2D slot per card owns input and focus and carries the labels, and each
## view follows its slot through the stage camera (as CardPage does). Effects off (or headless) play the beats with no effect; the
## labels always show. Presentation only: the cards are the account's whatever this stage shows.
class_name PackStage
extends Control

## A face-down card was clicked (or Enter pressed on it).
signal card_pressed(index: int)
## A card finished turning face up.
signal card_flipped(index: int)
## The fifth card is face up.
signal all_revealed

## The labels' theme type variations. (Playtest 2026-11-18: no rim or ring on a card's back; a face-down card hints its rarity
## only by its glow while hovered or selected.)
@export var rarity_label_variation: StringName = &"Title"
@export var detail_label_variation: StringName = &"Muted"
## Seconds of one pulse of a pack waiting in the socket for the server.
@export var wait_pulse_seconds: float = 0.8

var stage: FxStage
var style: CardStyle
var reveal: PackReveal
## index → CardView3D / slot Control.
var views: Array[CardView3D] = []
var slots: Array[Control] = []
## The pack in the socket (null when none). With the 3D pack it is the invisible stand-in the beats animate, and `pack_3d`
## follows it (as the card views follow their slots).
var pack: CardPackView
var pack_3d: CardPack3D
var _sway_time: float = 0.0
## True while a beat animates (Done and Reveal all wait for it).
var busy: bool = false
## The choreography to play instead of the style's (the reveal demo tries effects with it).
var plan_override: PackChoreography

var _tells: Dictionary = {}   # index → FxHandle
var _wait_tween: Tween
var _fly_tween: Tween
var _depth: float = 7.0
var _anchor: Node3D   # the socket in the 3D world (the burst's anchor)
## The stage's voices: setting a player's stream stops what it plays, so every sound takes an idle voice (one more is made when
## none is idle, up to MAX_VOICES). They live under /root/PackStageVoices, not under the stage, so a sound still ringing when the
## screen closes fades out (`sound_fade_seconds`) instead of being cut off with the stage.
const VOICE_HOST := "PackStageVoices"
const MAX_VOICES := 8
var _voices: Array[AudioStreamPlayer] = []
var _voice: int = 0
## Flips still turning, and whether all_revealed was sent for this pack.
var _turning: int = 0
var _announced: bool = false
var _resize_pending: bool = false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage = FxStage.new()
	stage.name = "Stage"
	add_child(stage)
	_anchor = Node3D.new()
	_anchor.name = "Socket"
	stage.world_root.add_child(_anchor)
	_give_the_foil_a_sky()


func _ready() -> void:
	stage.match_screen_pixels()
	(style if style != null else CardStyle.current()).warm_art()   # the faces' art loads off the main thread now
	resized.connect(_on_resized)
	if style == null:
		style = CardStyle.current()
	set_process(false)


## The 3D pack's metal reflects a sky (the stage shows its clear colour behind; the cards are unshaded, so only the pack sees it)
## and a light in front of the socket.
func _give_the_foil_a_sky() -> void:
	var env := stage.environment.environment
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.35, 0.4, 0.6)
	sky_material.sky_horizon_color = Color(0.9, 0.85, 0.8)
	sky_material.ground_bottom_color = Color(0.08, 0.06, 0.12)
	sky_material.ground_horizon_color = Color(0.5, 0.45, 0.5)
	sky.sky_material = sky_material
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var light := OmniLight3D.new()
	light.name = "PackLight"
	light.position = Vector3(0.8, 0.9, 3.0)
	light.omni_range = 9.0
	light.light_energy = 2.5
	stage.world_root.add_child(light)


func choreography() -> PackChoreography:
	if plan_override != null:
		return plan_override
	return (style if style != null else CardStyle.current()).pack_choreography()


# --- Beat 1: the socket ----------------------------------------------------------------------------------------------------

## The pack of `look` (labelled `label`) flies from `from_rect` (global, the column's pack) into the socket, settles with a shake
## and pulses there until burst() or cancel_pack(). Await it for the end of the flight.
func socket_pack(look: CardPackLook, label: String, from_rect: Rect2 = Rect2()) -> void:
	clear()
	var plan := choreography()
	pack = CardPackView.new()
	pack.custom_minimum_size = Vector2.ONE   # review fix: not the Shop's 150 x 228 default, which a small stage would be clamped to
	pack.name = "Pack"
	pack.look = look
	pack.label = label
	pack.glare_period = 0.0
	if style != null:
		pack.name_font = style.name_font
	pack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(pack)
	if plan.pack_3d:
		pack.self_modulate = Color(1, 1, 1, 0)   # the stand-in: the 3D pack is what shows
		pack_3d = CardPack3D.new()
		pack_3d.name = "Pack3D"
		stage.world_root.add_child(pack_3d)
		pack_3d.show_pack(look, label, style.name_font if style != null else null)
		_sway_time = 0.0
		set_process(true)
	var target := _pack_rect()
	pack.size = target.size
	pack.pivot_offset = Vector2.ZERO   # the flight scales from the top left, so the start lines up with the column's pack
	var start := target
	if from_rect.has_area():
		var local_from := get_global_transform().affine_inverse() * from_rect.position
		start = Rect2(local_from, from_rect.size)
	pack.position = start.position
	pack.scale = Vector2.ONE * (start.size.y / maxf(target.size.y, 1.0))
	_play_sound(plan.socket_sound)
	var mine := pack
	busy = true
	if plan.socket_seconds > 0.0 and is_inside_tree():
		var tween := create_tween().set_parallel(true)
		_fly_tween = tween
		tween.tween_property(pack, "position", target.position, plan.socket_seconds).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(pack, "scale", Vector2.ONE, plan.socket_seconds).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.chain().tween_property(pack, "rotation", deg_to_rad(-3.0), 0.05)
		tween.chain().tween_property(pack, "rotation", deg_to_rad(3.0), 0.06)
		tween.chain().tween_property(pack, "rotation", 0.0, 0.05)
		await tween.finished
	else:
		pack.position = target.position
		pack.scale = Vector2.ONE
	if not is_instance_valid(self):
		return
	busy = false
	if _resize_pending:
		_on_resized()
	if pack == mine and is_instance_valid(mine):   # not burst or cancelled meanwhile
		mine.pivot_offset = mine.size * 0.5   # the shake and the pulse turn round the middle (scale is 1 here: nothing moves)
		_wait_tween = create_tween().set_loops()
		_wait_tween.tween_property(pack, "scale", Vector2.ONE * 1.04, wait_pulse_seconds * 0.5).set_trans(Tween.TRANS_SINE)
		_wait_tween.tween_property(pack, "scale", Vector2.ONE, wait_pulse_seconds * 0.5).set_trans(Tween.TRANS_SINE)


## The open failed: the pack leaves the socket.
func cancel_pack() -> void:
	if pack != null and is_instance_valid(pack):
		var leaving := pack
		pack = null
		_stop_wait()
		if is_inside_tree():
			var tween := create_tween()
			tween.tween_property(leaving, "modulate:a", 0.0, 0.25)
			tween.tween_callback(leaving.queue_free)
			tween.tween_callback(_free_pack_3d)
		else:
			leaving.queue_free()


# --- Beats 2 to 4: burst, fan, tells ---------------------------------------------------------------------------------------

## The pack bursts in its colour and the reveal's cards fan out face down, glowing their rarity. `faces` are the slots' faces in
## order (a CardFace each). Await it: it returns once the cards are in their places.
func burst(open: PackReveal, faces: Array, look: CardPackLook) -> void:
	while busy and is_inside_tree():
		await get_tree().process_frame   # the pack is still flying into the socket (a fast answer)
	_stop_wait()
	reveal = open
	_turning = 0
	_announced = false
	var plan := choreography()
	busy = true
	var socket := _pack_rect().get_center()
	if pack != null and is_instance_valid(pack) and plan.burst_seconds > 0.0 and is_inside_tree():
		var shake := create_tween()
		var steps := 6
		for step in steps:
			var angle := deg_to_rad((5.0 + step) * (1.0 if step % 2 == 0 else -1.0))
			shake.tween_property(pack, "rotation", angle, plan.burst_seconds * 0.6 / steps)
			shake.parallel().tween_property(pack, "scale", Vector2.ONE * (1.04 + 0.025 * step), plan.burst_seconds * 0.6 / steps)
		await shake.finished
	_place_anchor(socket)
	_fx(plan.burst_fx, FxAnchor.on_stage(stage, _anchor), {"color": look.burst_color if look != null else Color.WHITE})
	_play_sound(plan.burst_sound)
	if pack != null and is_instance_valid(pack):
		pack.queue_free()
		pack = null
	_free_pack_3d()
	if plan.burst_seconds > 0.0 and is_inside_tree():
		await get_tree().create_timer(plan.burst_seconds * 0.4).timeout
	var fanning := plan.fan_seconds > 0.0 and is_inside_tree()
	_build_cards(faces, socket if fanning else Vector2.INF)
	set_process(true)
	var placed := _places()
	if fanning:
		var fan := create_tween().set_parallel(true)
		for index in slots.size():
			var slot := slots[index]
			var delay := plan.fan_stagger * index
			fan.tween_property(slot, "position", placed[index].position, plan.fan_seconds).set_delay(delay) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			fan.tween_property(slot, "scale", Vector2.ONE, plan.fan_seconds).set_delay(delay)
		await fan.finished
	else:
		for index in slots.size():
			slots[index].position = placed[index].position
	if not is_instance_valid(self):
		return
	_place_views()
	set_process(false)   # review fix: the cards stand still now; a resize places them again
	if _resize_pending:
		_on_resized()
	busy = false
	for index in slots.size():
		_update_tell(index)   # playtest fix: a card glows its rarity only while hovered or selected by keyboard / controller
	if not slots.is_empty() and is_inside_tree():
		slots[0].grab_focus(true)   # hidden until the keyboard or controller moves it (then it glows)


## `start`: where the cards begin, small (the socket, for the fan); INF = at their places. Playtest fix: the cards never show at
## their places for a frame before the fan starts.
func _build_cards(faces: Array, start: Vector2 = Vector2.INF) -> void:
	var scene := style.face_scene() if style != null else null
	var placed := _places()
	for index in reveal.size():
		var slot := Control.new()
		slot.name = "Slot%d" % index
		slot.focus_mode = Control.FOCUS_ALL
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		slot.size = placed[index].size
		slot.pivot_offset = slot.size * 0.5
		slot.position = placed[index].position
		if start != Vector2.INF:
			slot.position = start - slot.size * 0.5
			slot.scale = Vector2.ONE * 0.3
		add_child(slot)
		slot.gui_input.connect(_on_slot_input.bind(index))
		slot.mouse_entered.connect(_update_tell.bind(index))
		slot.mouse_exited.connect(_update_tell.bind(index))
		slot.focus_entered.connect(_update_tell.bind(index))
		slot.focus_exited.connect(_update_tell.bind(index))
		var labels := VBoxContainer.new()
		labels.name = "Labels"
		labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
		labels.alignment = BoxContainer.ALIGNMENT_BEGIN
		labels.visible = false
		slot.add_child(labels)
		var rarity := Label.new()
		rarity.name = "Rarity"
		rarity.theme_type_variation = rarity_label_variation
		rarity.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		labels.add_child(rarity)
		var detail := Label.new()
		detail.name = "Detail"
		detail.theme_type_variation = detail_label_variation
		detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		labels.add_child(detail)
		slots.append(slot)
		var view := CardView3D.new()
		view.name = "Card%d" % index
		stage.world_root.add_child(view)
		var face: CardFace = faces[index] if index < faces.size() and faces[index] is CardFace else CardFace.new()
		view.show_face(face, style, scene, 1.0, _render_scale(slot.size.y))
		view.show_back(style, true)
		views.append(view)
	_order_focus()
	_place_views()


## Playtest fix: arrows, the d-pad and Tab walk the cards in one order every time (0 → 4 and back, wrapping), never by where
## they happen to sit on the screen.
func _order_focus() -> void:
	var count := slots.size()
	for index in count:
		var slot := slots[index]
		var next := slot.get_path_to(slots[(index + 1) % count])
		var previous := slot.get_path_to(slots[(index - 1 + count) % count])
		slot.focus_neighbor_right = next
		slot.focus_neighbor_bottom = next
		slot.focus_next = next
		slot.focus_neighbor_left = previous
		slot.focus_neighbor_top = previous
		slot.focus_previous = previous


# --- Beat 5 and 6: flips and labels ----------------------------------------------------------------------------------------

## Flips card `index` with its rarity's flash (at `flash_share` of its strength: Reveal all's are shorter) and shows its labels.
## Await it for the end of the turn; false when there was nothing to flip.
func flip(index: int, flash_share: float = 1.0) -> bool:
	if reveal == null or not reveal.reveal(index):
		return false
	var plan := choreography()
	var slot := reveal.slots[index]
	var tier := int(slot["tier"])
	var color := _rarity_color(str(slot["rarity"]))
	_stop_tell(index)
	var tween := views[index].flip(plan.flip_seconds, plan.flip_lift)
	_play_sound(plan.flip_sound(tier))
	_flash(index, tier, color, flash_share, plan)
	_show_labels(index)
	slots[index].queue_redraw()
	var open := reveal
	_turning += 1
	if tween != null and is_inside_tree():
		await tween.finished
	if not is_instance_valid(self) or reveal != open:
		return true
	_turning -= 1
	card_flipped.emit(index)
	if reveal.done() and _turning == 0 and not _announced:   # once, after the last card has turned
		_announced = true
		all_revealed.emit()
	return true


## Flips every face-down card, `reveal_all_gap` apart, flashes at `reveal_all_flash`. Await it for the last turn.
func flip_all() -> void:
	if reveal == null:
		return
	var plan := choreography()
	var open := reveal
	var left := reveal.hidden()
	for step in left.size():
		flip(left[step], plan.reveal_all_flash)   # a card the player clicked meanwhile is skipped by flip()
		if step < left.size() - 1 and plan.reveal_all_gap > 0.0 and is_inside_tree():
			await get_tree().create_timer(plan.reveal_all_gap).timeout
		if not is_instance_valid(self) or reveal != open:
			return
	while is_instance_valid(self) and reveal == open and _turning > 0 and is_inside_tree():
		await get_tree().process_frame   # review fix: every card has turned, also one clicked during Reveal all


func _flash(index: int, tier: int, color: Color, share: float, plan: PackChoreography) -> void:
	var anchor := FxAnchor.control(slots[index])
	_fx(plan.flash_fx, anchor, {"color": color, "intensity": float(plan.tier_value(plan.flash_intensity, tier)) * share})
	var big := plan.big_reveal_fx(tier)
	if big != &"":
		_fx(big, _reveal_anchor(big, index), {"color": color, "intensity": share})
	if tier >= plan.shake_from_tier:
		var strength := float(plan.tier_value(plan.shake_strength, tier)) * share
		if strength > 0.0:
			_fx(plan.shake_fx, FxAnchor.screen(), {"strength": strength})
	if tier >= plan.screen_flash_tier:
		_fx(plan.screen_flash_fx, FxAnchor.screen(), {"color": color, "intensity": share})


## A UI-space effect hugs the card's slot; any other plays on the stage at the card.
func _reveal_anchor(effect: StringName, index: int) -> FxAnchor:
	var service := get_node_or_null("/root/FxManager")
	var definition: FxDefinition = service.definition(effect) if service != null else null
	if definition != null and definition.space == FxDefinition.Space.UI:
		return FxAnchor.control(slots[index])
	return FxAnchor.on_stage(stage, views[index])


func _show_labels(index: int) -> void:
	var labels: VBoxContainer = slots[index].get_node("Labels")
	var rarity: Label = labels.get_node("Rarity")
	rarity.text = reveal.rarity_line(index)
	rarity.add_theme_color_override(&"font_color", _rarity_color(str(reveal.slots[index]["rarity"])))
	(labels.get_node("Detail") as Label).text = reveal.detail_line(index)
	labels.visible = true
	_place_labels(index)


## The labels under card `index` (the console and the tests).
func labels_of(index: int) -> PackedStringArray:
	if index < 0 or index >= slots.size():
		return PackedStringArray()
	var labels: VBoxContainer = slots[index].get_node("Labels")
	if not labels.visible:
		return PackedStringArray()
	return PackedStringArray([(labels.get_node("Rarity") as Label).text, (labels.get_node("Detail") as Label).text])


# --- Beat 4: the tell ------------------------------------------------------------------------------------------------------

## Card `index`'s rarity glow while it is face down and hovered or selected with the keyboard or controller (a focus a click or the
## stage gave is hidden and does not count); off otherwise, and during a beat.
func _update_tell(index: int) -> void:
	if index >= slots.size() or reveal == null or index >= reveal.size():
		return
	var slot := slots[index]
	var hovered := slot.is_visible_in_tree() and slot.get_global_rect().has_point(slot.get_global_mouse_position())
	var wanted: bool = not busy and not reveal.slots[index]["revealed"] and (hovered or slot.has_focus(true))
	if wanted and not _tells.has(index):
		_start_tell(index)
	elif not wanted and _tells.has(index):
		_stop_tell(index)


func _start_tell(index: int) -> void:
	var plan := choreography()
	var slot := reveal.slots[index]
	var tier := int(slot["tier"])
	var intensity := float(plan.tier_value(plan.tell_intensity, tier))
	if intensity <= 0.0:
		return
	var handle := _fx(plan.tell_fx, FxAnchor.control(slots[index]), {"color": _rarity_color(str(slot["rarity"])),
		"intensity": intensity, "pulse": float(plan.tier_value(plan.tell_pulse, tier))})
	_tells[index] = handle   # null when effects are off: still marks the glow as on


func _stop_tell(index: int) -> void:
	var handle: FxHandle = _tells.get(index)
	if handle != null and is_instance_valid(handle):
		handle.stop(0.15)
	_tells.erase(index)


# --- Beat 7: done ----------------------------------------------------------------------------------------------------------

## The cards leave the stage (Done). Await it.
func clear_cards() -> void:
	for index in _tells.keys():
		_stop_tell(index)
	if not slots.is_empty() and is_inside_tree():
		set_process(true)   # review fix: the 3D cards follow their slots off the stage
		var tween := create_tween().set_parallel(true)
		for slot in slots:
			tween.tween_property(slot, "position:y", size.y + slot.size.y, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		await tween.finished
	if is_instance_valid(self):
		clear()


## Everything off the stage at once.
func clear() -> void:
	_stop_wait()
	if _fly_tween != null and _fly_tween.is_valid():
		_fly_tween.kill()   # the pack leaves with the rest; its flight's awaiter never resumes
	_fly_tween = null
	for index in _tells.keys():
		_stop_tell(index)
	for view in views:
		if is_instance_valid(view):
			view.queue_free()
	for slot in slots:
		if is_instance_valid(slot):
			slot.queue_free()
	views.clear()
	slots.clear()
	reveal = null
	_turning = 0
	_announced = false
	if pack != null and is_instance_valid(pack):
		pack.queue_free()
	pack = null
	_free_pack_3d()
	busy = false
	set_process(false)


# --- Layout ----------------------------------------------------------------------------------------------------------------

## The five cards' rects (local), from the choreography's spots.
func _places() -> Array[Rect2]:
	var plan := choreography()
	var height := size.y * plan.card_height
	var card := Vector2(height * CardFaceView.SIZE.x / CardFaceView.SIZE.y, height)
	var rects: Array[Rect2] = []
	for index in 5:
		var spot: Vector2 = plan.spots[index] if index < plan.spots.size() else Vector2(0.5, 0.5)
		rects.append(Rect2(spot * size - card * 0.5, card))
	return rects


func _pack_rect() -> Rect2:
	var height := size.y * choreography().pack_height
	var pack_size := Vector2(height * 150.0 / 228.0, height)
	return Rect2(size * 0.5 - pack_size * 0.5, pack_size)


func _process(delta: float) -> void:
	_place_views()
	_place_pack_3d(delta)


## The 3D pack where its stand-in is (centre, size, turn, fade), swaying a little so the foil catches the light.
func _place_pack_3d(delta: float) -> void:
	if pack_3d == null or not is_instance_valid(pack_3d):
		return
	if pack == null or not is_instance_valid(pack) or stage.camera == null or not stage.camera.is_inside_tree():
		pack_3d.visible = false
		return
	var viewport_height := float(stage.viewport.size.y)
	if viewport_height <= 0.0 or absf(viewport_height - stage.size.y * stage.pixel_ratio()) > 2.0:
		pack_3d.visible = false   # the stage's viewport has not taken its size yet (the first frames): placing now would be wrong
		return
	_sway_time += delta
	var depth := stage.camera.position.z
	var world_per_pixel := 2.0 * depth * tan(deg_to_rad(stage.camera.fov) * 0.5) / viewport_height
	var center := pack.position + pack.pivot_offset + (pack.size * 0.5 - pack.pivot_offset).rotated(pack.rotation) * pack.scale
	pack_3d.position = stage.camera.project_position(stage.to_viewport(center), depth)
	var pixels_tall := pack.size.y * pack.scale.y * viewport_height / maxf(stage.size.y, 1.0)
	var fade := pack.modulate.a
	pack_3d.scale = Vector3.ONE * maxf(pixels_tall * world_per_pixel / pack_3d.height * fade, 0.001)
	pack_3d.visible = fade > 0.02
	var sway := choreography().pack_sway
	pack_3d.rotation = Vector3(sway * 0.35 * sin(_sway_time * 0.9), sway * sin(_sway_time * 1.3), -pack.rotation)


func _free_pack_3d() -> void:
	if pack_3d != null and is_instance_valid(pack_3d):
		pack_3d.queue_free()
	pack_3d = null
	if slots.is_empty() and is_inside_tree():
		set_process(false)


## The stage changed size: the pack in the socket and the cards move to their places at the new size (the labels with them), and
## the faces render at the new size. During a beat (the fan) it waits until the beat ends.
func _on_resized() -> void:
	if busy:
		_resize_pending = true
		return
	_resize_pending = false
	if pack != null and is_instance_valid(pack):
		var target := _pack_rect()
		pack.size = target.size
		pack.pivot_offset = target.size * 0.5
		pack.position = target.position
	if slots.is_empty():
		return
	var placed := _places()
	for index in slots.size():
		slots[index].size = placed[index].size
		slots[index].pivot_offset = slots[index].size * 0.5
		slots[index].position = placed[index].position
		if index < views.size():
			views[index].set_render_scale(_render_scale(placed[index].size.y))
	_place_views.call_deferred()


## Each view where its slot is, sized to it (the slots move during the fan and the labels follow).
func _place_views() -> void:
	if stage.camera == null or not stage.camera.is_inside_tree():
		return
	var viewport_height := float(stage.viewport.size.y)
	if viewport_height <= 0.0:
		return
	_depth = stage.camera.position.z
	var world_per_pixel := 2.0 * _depth * tan(deg_to_rad(stage.camera.fov) * 0.5) / viewport_height
	for index in mini(views.size(), slots.size()):
		var slot := slots[index]
		var view := views[index]
		var center := slot.position + slot.size * 0.5
		var at := stage.to_viewport(center)
		view.position = stage.camera.project_position(at, _depth)
		var pixels_tall := slot.size.y * slot.scale.y * viewport_height / maxf(stage.size.y, 1.0)
		view.set_height(pixels_tall * world_per_pixel)
		_place_labels(index)


func _place_labels(index: int) -> void:
	var labels: Control = slots[index].get_node_or_null("Labels")
	if labels == null:
		return
	var width := maxf(slots[index].size.x * 1.6, labels.get_combined_minimum_size().x)
	labels.size = Vector2(width, labels.get_combined_minimum_size().y)
	labels.position = Vector2((slots[index].size.x - width) * 0.5, slots[index].size.y + 8.0)


func _place_anchor(local_point: Vector2) -> void:
	if stage.camera == null or not stage.camera.is_inside_tree():
		return
	_anchor.position = stage.camera.project_position(stage.to_viewport(local_point), stage.camera.position.z)


func _render_scale(height: float) -> float:
	return CardView3D.clamp_scale(height * stage.pixel_ratio() / CardFaceView.SIZE.y)


func _rarity_color(rarity: String) -> Color:
	return (style if style != null else CardStyle.current()).rarity(rarity).color


func _on_slot_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		slots[index].accept_event()
		card_pressed.emit(index)
	elif event.is_action_pressed(&"ui_accept"):
		# Enter or Space (both ui_accept) on a face-down card flips it; on a face-up one, the next face-down card (spec 2.4:
		# Space flips the next), which then takes the focus.
		var target := index
		if reveal != null and index < reveal.size() and reveal.slots[index]["revealed"]:
			target = reveal.next_hidden()
		if target >= 0:
			slots[index].accept_event()   # with every card face up the key goes on to the screen (it opens the next pack)
			if target != index:
				slots[target].grab_focus()
			card_pressed.emit(target)


func _stop_wait() -> void:
	if _wait_tween != null:
		_wait_tween.kill()
		_wait_tween = null
	if _fly_tween != null and _fly_tween.is_valid() and (pack == null or not is_instance_valid(pack)):
		_fly_tween.kill()   # its pack is gone (cancelled, cleared): the flight's awaiter never resumes, so free the stage here
		busy = false
	_fly_tween = null if _fly_tween == null or not _fly_tween.is_valid() else _fly_tween


## Plays effect `id` (inert when effects are off or headless); null when there is none.
func _fx(id: StringName, anchor: FxAnchor, params: Dictionary) -> FxHandle:
	if id == &"" or not is_inside_tree():
		return null
	var service := get_node_or_null("/root/FxManager")
	if service == null:
		return null
	return service.play(id, anchor, params)


func _play_sound(id: String) -> void:
	if id == "" or not is_inside_tree():
		return
	var path := SfxBank.bank_path(id)
	if not ResourceLoader.exists(path):
		return
	var voice := _idle_voice()
	voice.stream = load(path)
	voice.volume_db = 0.0
	voice.play()


## An idle voice, a new one while there are fewer than MAX_VOICES, else the one that started longest ago.
func _idle_voice() -> AudioStreamPlayer:
	_voices = _voices.filter(func(v): return is_instance_valid(v) and not v.is_queued_for_deletion())
	for voice in _voices:
		if not voice.playing:
			return voice
	if _voices.size() >= MAX_VOICES:
		var oldest := _voices[_voice % _voices.size()]
		_voice = (_voice + 1) % _voices.size()
		return oldest
	var host := get_tree().root.get_node_or_null(VOICE_HOST)
	if host == null:
		host = Node.new()
		host.name = VOICE_HOST
		get_tree().root.add_child(host)
	var voice := AudioStreamPlayer.new()
	voice.name = "Voice"
	voice.bus = &"Ui"
	host.add_child(voice, true)
	_voices.append(voice)
	return voice


## The stage leaves: an idle voice goes at once, a ringing one fades out first.
func _exit_tree() -> void:
	var fade := maxf(choreography().sound_fade_seconds, 0.0)
	for voice in _voices:
		if not is_instance_valid(voice) or voice.is_queued_for_deletion():
			continue
		if not voice.playing or fade == 0.0 or not voice.is_inside_tree():
			voice.queue_free()
			continue
		var tween := voice.create_tween()
		tween.tween_property(voice, "volume_db", -60.0, fade).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tween.tween_callback(voice.queue_free)
	_voices.clear()
