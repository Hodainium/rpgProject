## Spec card-ui 3.3: one card on a card stage (FxStage.world_root). Its face is rendered live, on demand (user, 2026-11-18: no
## face cache): the view owns a SubViewport holding the face scene (a CardFaceView) and shows its texture on a thin quad. A still
## face (Common, Rare, Epic) renders once (`UPDATE_ONCE`); a face with looping layers (Legendary, Mythic, corrupted) renders every
## frame (`UPDATE_ALWAYS`). The viewport and the face leave with the view (a page change frees them).
## Hover tilts the card toward the cursor with a moving glare and lifts it; a missing card is ghosted; a craft flashes it.
## Presentation only: never read by combat/, the run or the verifier.
class_name CardView3D
extends Node3D

## Design pixels around the face inside its texture: room for a corrupted card's glow, which reaches past the card.
const PAD: float = 30.0

@export var tilt_degrees: float = 9.0
## How far a hovered card comes toward the camera (world units) and how much it grows.
@export var hover_lift: float = 0.25
@export var hover_scale: float = 1.05
## How fast tilt and lift follow (per second, exponential).
@export var follow_speed: float = 14.0
@export var flash_seconds: float = 0.6

var face: CardFace
var face_view: CardFaceView
var viewport: SubViewport
var mesh: MeshInstance3D
var material: ShaderMaterial
## Spec card-ui 2.4: the card back (a pack's face-down cards), built by show_back(); null until then.
var back_mesh: MeshInstance3D
var back_viewport: SubViewport
## The hover tilt, lift and scale turn this node; the flip turns `flipper` under it (front and back quads).
var pivot: Node3D
var flipper: Node3D
## True while the back faces the camera.
var face_down: bool = false
var _flip_tween: Tween
## Pixels per design pixel of the face texture (the card's height on screen / 420).
var render_scale: float = 1.0
## The card's height in world units (the face, without PAD).
var card_height: float = 1.0

var _pointer: Vector2 = Vector2.ZERO   # -1..1 across the card
var _hovering: bool = false
var _raised: bool = false
var _tilt: Vector2 = Vector2.ZERO
var _lift: float = 0.0
var _flash_tween: Tween
## The style the face was drawn with (part of a baked face's cache key).
var _style_id: int = 0

const SHADER: Shader = preload("res://game/cards/shaders/card_view.gdshader")


func _init() -> void:
	viewport = SubViewport.new()
	viewport.name = "Face"
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.gui_disable_input = true
	viewport.handle_input_locally = false
	viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	material = ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter(&"texture_size", CardFaceView.SIZE + Vector2(PAD, PAD) * 2.0)
	material.set_shader_parameter(&"card_box", Vector4(PAD, PAD, CardFaceView.SIZE.x, CardFaceView.SIZE.y))
	pivot = Node3D.new()
	pivot.name = "Pivot"
	add_child(pivot)
	flipper = Node3D.new()
	flipper.name = "Flip"
	pivot.add_child(flipper)
	mesh = MeshInstance3D.new()
	mesh.name = "Card"
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.material_override = material
	flipper.add_child(mesh)
	set_process(false)


## Shows `card` drawn by `scene` (a CardFaceView scene) at `pixels_per_design_pixel`, the card `height` world units tall.
func show_face(card: CardFace, style: CardStyle, scene: PackedScene, height: float, pixels_per_design_pixel: float) -> void:
	face = card
	card_height = height
	_style_id = style.get_instance_id() if style != null else 0
	if face_view != null:
		face_view.queue_free()
		face_view = null
	if scene != null:
		face_view = scene.instantiate() as CardFaceView
	if face_view == null:
		push_warning("CardView3D: no face scene for %s" % card.id)
		return
	viewport.add_child(face_view)
	face_view.show_face(card, style)
	set_render_scale(pixels_per_design_pixel)
	_size_mesh()
	material.set_shader_parameter(&"face_tex", viewport.get_texture())


## True when the face has looping layers, so its texture is redrawn every frame.
func live() -> bool:
	return face_view != null and face_view.animate and face_view.has_loops()


## Re-renders the texture at `pixels_per_design_pixel` (the card got bigger or smaller on screen).
func set_render_scale(pixels_per_design_pixel: float) -> void:
	render_scale = clamp_scale(pixels_per_design_pixel)
	if face_view == null:
		return
	var design := CardFaceView.SIZE + Vector2(PAD, PAD) * 2.0
	viewport.size = Vector2i(ceili(design.x * render_scale), ceili(design.y * render_scale))
	face_view.scale = Vector2(render_scale, render_scale)
	face_view.position = Vector2(PAD, PAD) * render_scale
	redraw()
	_render_back()


## The render scales a face texture takes (a huge card on a big screen stops at 3 pixels per design pixel).
static func clamp_scale(pixels_per_design_pixel: float) -> float:
	return clampf(pixels_per_design_pixel, 0.5, 3.0)


## Draws the face again: every frame for a live face, once for a still one (or one lying face down: nothing of it shows).
func redraw() -> void:
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if live() and not face_down else SubViewport.UPDATE_ONCE


func set_height(height: float) -> void:
	if is_equal_approx(height, card_height) and mesh.mesh != null:
		return   # review fix: the pack stage places its cards every frame; an unchanged size makes no new mesh
	card_height = height
	_size_mesh()


func _size_mesh() -> void:
	var unit := card_height / CardFaceView.SIZE.y
	var quad := QuadMesh.new()
	quad.size = (CardFaceView.SIZE + Vector2(PAD, PAD) * 2.0) * unit
	mesh.mesh = quad
	if back_mesh != null:
		back_mesh.mesh = quad


## Spec card-ui 2.4: gives the card a back (the style's `back_texture`, else CardBackView) on the other side of the quad,
## rendered once. `down` turns the back to the camera.
func show_back(style: CardStyle, down: bool = true) -> void:
	if back_mesh == null:
		back_viewport = SubViewport.new()
		back_viewport.name = "Back"
		back_viewport.transparent_bg = true
		back_viewport.disable_3d = true
		back_viewport.gui_disable_input = true
		back_viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
		add_child(back_viewport)
		var back := CardBackView.new()
		back.name = "BackView"
		back.texture = style.back_texture if style != null else null
		back_viewport.add_child(back)
		var back_material := ShaderMaterial.new()
		back_material.shader = SHADER
		back_material.set_shader_parameter(&"texture_size", CardFaceView.SIZE + Vector2(PAD, PAD) * 2.0)
		back_material.set_shader_parameter(&"card_box", Vector4(PAD, PAD, CardFaceView.SIZE.x, CardFaceView.SIZE.y))
		back_material.set_shader_parameter(&"face_tex", back_viewport.get_texture())
		back_mesh = MeshInstance3D.new()
		back_mesh.name = "CardBack"
		back_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		back_mesh.material_override = back_material
		back_mesh.rotation = Vector3(0, PI, 0)
		flipper.add_child(back_mesh)
	_render_back()
	_size_mesh()
	set_face_down(down)


## The back's texture at the current render scale, drawn once.
func _render_back() -> void:
	if back_viewport == null:
		return
	var back_scale := maxf(render_scale, 0.5)
	var design := CardFaceView.SIZE + Vector2(PAD, PAD) * 2.0
	back_viewport.size = Vector2i(ceili(design.x * back_scale), ceili(design.y * back_scale))
	var view: Control = back_viewport.get_node("BackView")
	view.scale = Vector2(back_scale, back_scale)
	view.position = Vector2(PAD, PAD) * back_scale
	back_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## Turns the card at once (no animation): the back to the camera when `down`.
func set_face_down(down: bool) -> void:
	if _flip_tween != null:
		_flip_tween.kill()
	face_down = down
	flipper.rotation = Vector3(0, PI if down else 0.0, 0)
	flipper.position = Vector3.ZERO
	redraw()


## Spec card-ui 2.4 beat 5: the card lifts `lift` (world units at a card height of 1), turns face up over `seconds` and settles.
## Returns the tween (await its `finished`), or null when it was already face up.
func flip(seconds: float, lift: float = 0.35) -> Tween:
	if not face_down:
		return null
	face_down = false
	redraw()   # a live face goes live as it turns
	if _flip_tween != null:
		_flip_tween.kill()
	if seconds <= 0.0 or not is_inside_tree():
		set_face_down(false)
		return null
	var height := lift * card_height
	_flip_tween = create_tween()
	_flip_tween.set_parallel(true)
	_flip_tween.tween_property(flipper, "rotation:y", 0.0, seconds).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_flip_tween.tween_property(flipper, "position:z", height, seconds * 0.4).set_ease(Tween.EASE_OUT)
	_flip_tween.tween_property(flipper, "position:z", 0.0, seconds * 0.6).set_ease(Tween.EASE_IN_OUT).set_delay(seconds * 0.4)
	return _flip_tween


## Spec item-cards: baked faces by key ("<card id>", "back"), so a room rebuild reuses them; capped (a full set is ~1 MB each).
static var _baked: Dictionary = {}
const BAKED_CAP: int = 48


## Spec item-cards: for a small card in the world (a floor item). Godot 4.7.2 gives a viewport's texture no mipmaps, so a
## 360 x 480 face drawn on a quad a few dozen pixels tall shimmers. This renders the face (and the back) once, copies each into a
## texture with mipmaps (sampled anisotropically) and stops the viewports; a looping face (Legendary sheen) holds still. Baked
## faces are cached by what they show (the face's data, the style, the render scale), so a style, content or size change bakes
## anew. The waiting runs in a static function holding only a weak reference: a card freed mid-bake (a room rebuild) simply ends it.
func bake() -> void:
	if face_view != null:  # held at the start of its loops: a sheen starts fully off the card
		face_view.animate = false
		face_view.set_process(false)
		face_view._tick(0.0)
	# Called through the class, not the instance: the coroutine holds no instance, only the weak reference.
	CardView3D._bake_into(weakref(self), false, baked_face_key())
	if back_mesh != null:
		CardView3D._bake_into(weakref(self), true, "back:%d:%s" % [_style_id, maxf(render_scale, 0.5)])


## The bake of one side (the back when `back`) of the card `ref` points at; nothing when the card is gone by then.
static func _bake_into(ref: WeakRef, back: bool, key: String) -> void:
	var texture: ImageTexture = _baked.get(key)
	if texture == null:
		var card := ref.get_ref() as CardView3D
		if card == null:
			return
		var source: SubViewport = card.back_viewport if back else card.viewport
		if source == null:
			return
		source.render_target_update_mode = SubViewport.UPDATE_ONCE
		card = null  # hold no strong reference across the waits
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw   # the viewport drew after it entered the tree
		card = ref.get_ref() as CardView3D
		if card == null or not card.is_inside_tree():
			return
		source = card.back_viewport if back else card.viewport
		var image := source.get_texture().get_image() if source != null else null
		if image == null or image.is_empty():
			return
		image.generate_mipmaps()
		texture = ImageTexture.create_from_image(image)
		_store_baked(key, texture)
	_use_baked(ref, back, texture)


static func _use_baked(ref: WeakRef, back: bool, texture: ImageTexture) -> void:
	var card := ref.get_ref() as CardView3D
	if card == null:
		return
	var target: ShaderMaterial = (card.back_mesh.material_override as ShaderMaterial) if back else card.material
	var source: SubViewport = card.back_viewport if back else card.viewport
	if target == null or source == null:
		return
	target.set_shader_parameter(&"face_baked", texture)
	target.set_shader_parameter(&"use_baked", 1.0)
	source.render_target_update_mode = SubViewport.UPDATE_DISABLED


## Keeps a baked face; at the cap the oldest goes first (a Dictionary keeps insertion order).
static func _store_baked(key: String, texture: ImageTexture) -> void:
	_baked.erase(key)
	while _baked.size() >= BAKED_CAP:
		_baked.erase(_baked.keys()[0])
	_baked[key] = texture


## Forgets every baked face.
static func clear_baked() -> void:
	_baked.clear()


## The cache key of this card's face as bake() makes it (for tests and the console).
func baked_face_key() -> String:
	return "face:%d:%d:%s" % [hash(face.to_dict()) if face != null else 0, _style_id, render_scale]


## A missing card: greyed and tinted.
func set_ghost(on: bool) -> void:
	material.set_shader_parameter(&"ghost", 1.0 if on else 0.0)


## The cursor over the card: `point` -1..1 across it (x right, y down), `hovering` false when it left.
func set_pointer(point: Vector2, hovering: bool) -> void:
	_pointer = point.clamp(Vector2(-1, -1), Vector2(1, 1))
	_hovering = hovering
	set_process(true)


## Lifted without a tilt (keyboard or gamepad focus).
func set_raised(on: bool) -> void:
	_raised = on
	set_process(true)


## A short flash in `color` (a crafted card: its rarity's colour).
func flash(color: Color) -> void:
	material.set_shader_parameter(&"flash_color", color)
	if _flash_tween != null:
		_flash_tween.kill()
	_flash_tween = create_tween()
	_flash_tween.tween_method(_set_flash, 1.0, 0.0, flash_seconds).set_ease(Tween.EASE_OUT)


func _set_flash(value: float) -> void:
	material.set_shader_parameter(&"flash", value)


func _process(delta: float) -> void:
	var weight := 1.0 - exp(-follow_speed * delta)
	var target_tilt := _pointer if _hovering else Vector2.ZERO
	var target_lift := 1.0 if (_hovering or _raised) else 0.0
	_tilt = _tilt.lerp(target_tilt, weight)
	_lift = lerpf(_lift, target_lift, weight)
	pivot.rotation = Vector3(deg_to_rad(_tilt.y * tilt_degrees), deg_to_rad(_tilt.x * tilt_degrees), 0.0)
	pivot.position = Vector3(0, 0, _lift * hover_lift)
	pivot.scale = Vector3.ONE * lerpf(1.0, hover_scale, _lift)
	var glare_uv := Vector2(0.5, 0.5) + _tilt * 0.45
	material.set_shader_parameter(&"glare_pos", glare_uv)
	material.set_shader_parameter(&"glare_strength", clampf(_lift, 0.0, 1.0) if _hovering else 0.0)
	var at_rest := _tilt.length() < 0.001 and absf(_lift - target_lift) < 0.001 and not _hovering
	if at_rest:
		set_process(false)
