## Spec card-ui 2.3a / 2.3: a pack drawn from its `CardPackLook` (the prototype's foil wrapper): a crimped body in its two
## colours, a glare sweeping across it, the glyph, a band with the label in the name font, and an optional count badge
## ("x 7" on Open packs). Drawn in code so the Shop and Open packs share it; presentation only.
class_name CardPackView
extends Control

@export var look: CardPackLook:
	set(value):
		look = value
		queue_redraw()
@export var label: String = "":
	set(value):
		label = value
		queue_redraw()
## The badge in the top right corner; 0 hides it.
@export var count: int = 0:
	set(value):
		count = value
		queue_redraw()
## Seconds per glare sweep (0 = no glare).
@export var glare_period: float = 5.0
@export var name_font: Font
## The count badge: its text, fill and size (the outline is the pack's accent).
@export var badge_text: String = "x %d"
@export var badge_color: Color = Color(0.106, 0.145, 0.467)
@export var badge_font_size: int = 16
@export var glare_color: Color = Color(1, 1, 1, 0.22)

const CRIMPS: int = 20
## The part of each glare period the glare moves; it rests for the rest.
const GLARE_SWEEP: float = 0.6

var _time: float = 0.0


func _ready() -> void:
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(150, 228)
	set_process(glare_period > 0.0)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	var was_resting := _time / glare_period > GLARE_SWEEP
	_time = fmod(_time + delta, maxf(glare_period, 0.01))
	if not (was_resting and _time / glare_period > GLARE_SWEEP):
		queue_redraw()  # a resting glare draws nothing new


func _draw() -> void:
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
	draw_rect(Rect2(band.position + Vector2(0, band.size.y * 0.55), Vector2(band.size.x, band.size.y * 0.45)), pack.accent.darkened(0.3))
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
	var text := badge_text % count
	var font := get_theme_default_font()
	var font_size := badge_font_size
	var width := maxf(32.0, font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 14.0)
	var badge := Rect2(Vector2(area.size.x - width + 8.0, -8.0), Vector2(width, 28.0))
	draw_rect(badge, badge_color)
	draw_rect(badge, pack.accent, false, 2.0)
	var baseline := badge.position.y + (badge.size.y + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	draw_string(font, Vector2(badge.position.x + (badge.size.x - font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		font_size).x) * 0.5, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


## The largest size up to `wanted` at which `text` fits in `width` (shrink to fit).
static func _fit(font: Font, text: String, wanted: int, width: float) -> int:
	var font_size := maxi(wanted, 8)
	while font_size > 8 and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > width:
		font_size -= 1
	return font_size
