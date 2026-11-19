## Spec card-ui 2.3a / 2.3: a pack drawn from its `CardPackLook` (the prototype's foil wrapper): a crimped body in its two
## colours, a glare sweeping across it, the glyph, a band with the label in the name font, and an optional count badge
## ("x 7" on Open packs). Drawn in code so the Shop and Open packs share it; presentation only.
class_name CardPackView
extends Control

@export var look: CardPackLook:
	set(value):
		look = value
		queue_redraw()
		_refresh_solid()
@export var label: String = "":
	set(value):
		label = value
		queue_redraw()
		_refresh_solid()
## The badge in the top right corner; 0 hides it.
@export var count: int = 0:
	set(value):
		count = value
		queue_redraw()
		if _badge_layer != null:
			_badge_layer.queue_redraw()
## Seconds per glare sweep (0 = no glare).
@export var glare_period: float = 5.0
@export var name_font: Font
## The count badge: its text, fill and size (the outline is the pack's accent).
@export var badge_text: String = "x %d"
@export var badge_color: Color = Color(0.106, 0.145, 0.467)
@export var badge_font_size: int = 16
@export var glare_color: Color = Color(1, 1, 1, 0.22)
## Optional foil drawn over the pack's body (a ShaderMaterial on game/cards/shaders/pack_foil.gdshader, UV 0..1 over the pack;
## its `pack_size` is kept up to date). None = no foil.
@export var foil: ShaderMaterial:
	set(value):
		foil = value
		_sync_foil()

var _foil_layer: Control

## Shows the pack as the 3D metallic foil pouch (CardPack3D in a small 3D view of its own, swaying, tilting toward the pointer)
## instead of drawing it flat; the count badge is drawn over it. The user's pick for Open packs, 2026-11-18.
@export var solid: bool = false:
	set(value):
		solid = value
		if is_inside_tree():
			_sync_solid()
		queue_redraw()

var _solid_port: SubViewport
var _solid_picture: TextureRect
var _solid_pack: CardPack3D
var _badge_layer: Control
var _sway: float = 0.0
var _tilt := Vector2.ZERO

const CRIMPS: int = 20
## The part of each glare period the glare moves; it rests for the rest.
const GLARE_SWEEP: float = 0.6

var _time: float = 0.0


func _ready() -> void:
	resized.connect(_sync_foil)
	_sync_foil()
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(150, 228)
	resized.connect(_size_solid)
	_sync_solid()
	set_process(glare_period > 0.0 or solid)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	if solid:
		_turn_solid(delta)
		return
	var was_resting := _time / glare_period > GLARE_SWEEP
	_time = fmod(_time + delta, maxf(glare_period, 0.01))
	if not (was_resting and _time / glare_period > GLARE_SWEEP):
		queue_redraw()  # a resting glare draws nothing new


func _draw() -> void:
	if solid:
		return   # the 3D pack shows; the badge layer draws the count over it
	var pack: CardPackLook = look if look != null else CardPackLook.new()
	var area := Rect2(Vector2.ZERO, size)
	var body := _crimped(area)
	var colors := PackedColorArray()
	for point in body:
		colors.append(pack.color_light.lerp(pack.color_dark, clampf(point.y / maxf(area.size.y, 1.0), 0.0, 1.0)))
	draw_polygon(body, colors)
	_draw_glare(area, body)
	if pack.glyph != null:
		var side := area.size.x * 0.44
		var rect := Rect2(Vector2((area.size.x - side) * 0.5, area.size.y * 0.18), Vector2(side, side))
		draw_texture_rect(pack.glyph, rect, false, pack.accent)
	var band := Rect2(0, area.size.y * 0.56, area.size.x, area.size.y * 0.16)
	draw_rect(band, pack.accent)
	# Playtest 2026-11-18: one solid band (its darker lower half drew a line through the title).
	var text := label if label != "" else pack.label
	var font: Font = name_font if name_font != null else get_theme_default_font()
	if text != "" and font != null:
		var font_size := _fit(font, text, int(band.size.y * 0.5), band.size.x - 12.0)
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var baseline := band.position.y + (band.size.y + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
		draw_string(font, Vector2((area.size.x - width) * 0.5, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
			pack.color_dark.darkened(0.4))
	if count > 0:
		_draw_badge(area, pack)


## The foil layer: a child over the pack drawing its crimped body with the foil's material (made when a foil is set).
func _sync_foil() -> void:
	if foil == null:
		if _foil_layer != null:
			_foil_layer.visible = false
		return
	if _foil_layer == null:
		_foil_layer = Control.new()
		_foil_layer.name = "Foil"
		_foil_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_foil_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
		_foil_layer.draw.connect(_draw_foil)
		add_child(_foil_layer, false, Node.INTERNAL_MODE_FRONT)
	_foil_layer.visible = true
	_foil_layer.material = foil
	foil.set_shader_parameter(&"pack_size", size)
	_foil_layer.queue_redraw()


func _draw_foil() -> void:
	var area := Rect2(Vector2.ZERO, size)
	var body := _crimped(area)
	var uvs := PackedVector2Array()
	for point in body:
		uvs.append(point / Vector2(maxf(size.x, 1.0), maxf(size.y, 1.0)))
	_foil_layer.draw_polygon(body, PackedColorArray([Color.WHITE]), uvs)


## Builds or removes the 3D view (a SubViewport with its own world: camera, sky to reflect, lights, the pack) and the badge layer.
func _sync_solid() -> void:
	if not solid:
		for node in [_solid_picture, _solid_port, _badge_layer]:
			if node != null:
				node.queue_free()
		_solid_picture = null
		_solid_port = null
		_solid_pack = null
		_badge_layer = null
		set_process(glare_period > 0.0)
		return
	if _solid_port == null:
		_solid_port = SubViewport.new()
		_solid_port.name = "SolidView"
		_solid_port.own_world_3d = true
		_solid_port.transparent_bg = true
		_solid_port.msaa_3d = Viewport.MSAA_4X
		add_child(_solid_port, false, Node.INTERNAL_MODE_FRONT)
		var camera := Camera3D.new()
		camera.fov = 30.0
		camera.position = Vector3(0, 0, 3.3)   # the pack (1.52 tall) fills the view with room to sway
		_solid_port.add_child(camera)
		var environment := WorldEnvironment.new()
		var env := Environment.new()
		env.background_mode = Environment.BG_CLEAR_COLOR
		var sky := Sky.new()
		var sky_material := ProceduralSkyMaterial.new()
		sky_material.sky_top_color = Color(0.35, 0.4, 0.6)
		sky_material.sky_horizon_color = Color(0.9, 0.85, 0.8)
		sky_material.ground_bottom_color = Color(0.08, 0.06, 0.12)
		sky_material.ground_horizon_color = Color(0.5, 0.45, 0.5)
		sky.sky_material = sky_material
		env.sky = sky
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
		env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		environment.environment = env
		_solid_port.add_child(environment)
		var key := DirectionalLight3D.new()
		key.rotation_degrees = Vector3(-30, 25, 0)
		_solid_port.add_child(key)
		var light := OmniLight3D.new()
		light.position = Vector3(0.6, 0.8, 2.2)
		light.omni_range = 6.0
		light.light_energy = 2.5
		_solid_port.add_child(light)
		_solid_pack = CardPack3D.new()
		_solid_port.add_child(_solid_pack)
		_solid_picture = TextureRect.new()
		_solid_picture.name = "SolidPicture"
		_solid_picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_solid_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_solid_picture.stretch_mode = TextureRect.STRETCH_SCALE
		_solid_picture.set_anchors_preset(Control.PRESET_FULL_RECT)
		_solid_picture.texture = _solid_port.get_texture()
		add_child(_solid_picture, false, Node.INTERNAL_MODE_FRONT)
		_badge_layer = Control.new()
		_badge_layer.name = "Badge"
		_badge_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_badge_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
		_badge_layer.draw.connect(func() -> void:
			if count > 0:
				_draw_badge_on(_badge_layer, Rect2(Vector2.ZERO, size), look if look != null else CardPackLook.new()))
		add_child(_badge_layer, false, Node.INTERNAL_MODE_FRONT)
	_solid_pack.show_pack(look, label, name_font)
	_badge_layer.queue_redraw()
	_size_solid()
	set_process(true)


## A new look or label redraws the 3D pack's picture.
func _refresh_solid() -> void:
	if solid and _solid_pack != null and is_inside_tree():
		_solid_pack.show_pack(look, label, name_font)


## The 3D view renders at the pack's size on screen (sharp at 4K).
func _size_solid() -> void:
	if _solid_port == null or not is_inside_tree():
		return
	var ratio := maxf(get_viewport().get_screen_transform().get_scale().x * get_global_transform().get_scale().x, 0.25)
	_solid_port.size = Vector2i(maxi(1, roundi(size.x * ratio)), maxi(1, roundi(size.y * ratio)))


## A slow sway, and a tilt toward the pointer while it is over the pack.
func _turn_solid(delta: float) -> void:
	if _solid_pack == null:
		return
	_sway += delta
	var wanted := Vector2.ZERO
	var local := get_local_mouse_position()
	if Rect2(Vector2.ZERO, size).has_point(local):
		wanted = (local / size - Vector2(0.5, 0.5)) * 2.0
	_tilt = _tilt.lerp(wanted, minf(delta * 8.0, 1.0))
	_solid_pack.rotation = Vector3(_tilt.y * 0.3 + 0.05 * sin(_sway * 0.8), _tilt.x * 0.5 + 0.18 * sin(_sway * 1.1), 0.0)


## The wrapper's outline: crimped top and bottom edges, like a foil pack.
func _crimped(area: Rect2) -> PackedVector2Array:
	var points := PackedVector2Array()
	var depth := area.size.y * 0.03
	for index in CRIMPS + 1:
		points.append(Vector2(area.size.x * index / CRIMPS, depth if index % 2 == 0 else 0.0))
	for index in range(CRIMPS, -1, -1):
		points.append(Vector2(area.size.x * index / CRIMPS, area.size.y - (depth if index % 2 == 0 else 0.0)))
	return points


func _draw_glare(area: Rect2, body: PackedVector2Array) -> void:
	if glare_period <= 0.0:
		return
	var sweep := _time / glare_period
	if sweep > GLARE_SWEEP:
		return  # the glare rests between sweeps
	var x := lerpf(-area.size.x * 0.6, area.size.x * 1.6, sweep / GLARE_SWEEP)
	var width := area.size.x * 0.22
	var slant := area.size.y * 0.35
	var glare := PackedVector2Array([Vector2(x - width, 0), Vector2(x, 0), Vector2(x - slant, area.size.y),
		Vector2(x - slant - width, area.size.y)])
	var inside := Geometry2D.intersect_polygons(glare, body)
	for part in inside:
		draw_colored_polygon(part, glare_color)


func _draw_badge(area: Rect2, pack: CardPackLook) -> void:
	_draw_badge_on(self, area, pack)


func _draw_badge_on(target: CanvasItem, area: Rect2, pack: CardPackLook) -> void:
	var text := badge_text % count
	var font := get_theme_default_font()
	var font_size := badge_font_size
	var width := maxf(32.0, font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 14.0)
	# Playtest fix: inside the pack's own rect (it used to stick out 8 px and was cut off by the column).
	var badge := Rect2(Vector2(area.size.x - width - 4.0, 4.0), Vector2(width, 28.0))
	target.draw_rect(badge, badge_color)
	target.draw_rect(badge, pack.accent, false, 2.0)
	var baseline := badge.position.y + (badge.size.y + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	target.draw_string(font, Vector2(badge.position.x + (badge.size.x - font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		font_size).x) * 0.5, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


## The largest size up to `wanted` at which `text` fits in `width` (shrink to fit).
static func _fit(font: Font, text: String, wanted: int, width: float) -> int:
	var font_size := maxi(wanted, 8)
	while font_size > 8 and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > width:
		font_size -= 1
	return font_size
