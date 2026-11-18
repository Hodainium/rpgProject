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
	mesh = MeshInstance3D.new()
	mesh.name = "Card"
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.material_override = material
	add_child(mesh)
	set_process(false)


## Shows `card` drawn by `scene` (a CardFaceView scene) at `pixels_per_design_pixel`, the card `height` world units tall.
func show_face(card: CardFace, style: CardStyle, scene: PackedScene, height: float, pixels_per_design_pixel: float) -> void:
	face = card
	card_height = height
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


## The render scales a face texture takes (a huge card on a big screen stops at 3 pixels per design pixel).
static func clamp_scale(pixels_per_design_pixel: float) -> float:
	return clampf(pixels_per_design_pixel, 0.5, 3.0)


## Draws the face again: every frame for a live face, once for a still one.
func redraw() -> void:
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if live() else SubViewport.UPDATE_ONCE


func set_height(height: float) -> void:
	card_height = height
	_size_mesh()


func _size_mesh() -> void:
	var unit := card_height / CardFaceView.SIZE.y
	var quad := QuadMesh.new()
	quad.size = (CardFaceView.SIZE + Vector2(PAD, PAD) * 2.0) * unit
	mesh.mesh = quad


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
	mesh.rotation = Vector3(deg_to_rad(_tilt.y * tilt_degrees), deg_to_rad(_tilt.x * tilt_degrees), 0.0)
	mesh.position = Vector3(0, 0, _lift * hover_lift)
	mesh.scale = Vector3.ONE * lerpf(1.0, hover_scale, _lift)
	var glare_uv := Vector2(0.5, 0.5) + _tilt * 0.45
	material.set_shader_parameter(&"glare_pos", glare_uv)
	material.set_shader_parameter(&"glare_strength", clampf(_lift, 0.0, 1.0) if _hovering else 0.0)
	var at_rest := _tilt.length() < 0.001 and absf(_lift - target_lift) < 0.001 and not _hovering
	if at_rest:
		set_process(false)
