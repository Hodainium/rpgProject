## Spec ff7-ui 2.1 (F1): the FF7 window look as a StyleBox, set in the theme like any other: a three-stop gradient
## (top, middle, bottom; or left to right for bar fills) inside an inner ring and a light border, with rounded corners
## and a drop shadow. Every colour and size is an inspector field.
##
## The gradient is exact: the fill is split into two bands at `middle_at` (Geometry2D) and each vertex takes the
## colour of its position, which is linear within a band, so any triangulation draws it the same.
@tool
class_name UIWindowStyle
extends StyleBox

@export var top: Color = Color("3a4fb8"):
	set(value):
		top = value
		emit_changed()
@export var middle: Color = Color("1b2577"):
	set(value):
		middle = value
		emit_changed()
@export var bottom: Color = Color("121a5a"):
	set(value):
		bottom = value
		emit_changed()
## Where the middle colour sits, 0 (top) to 1 (bottom).
@export_range(0.0, 1.0) var middle_at: float = 0.55:
	set(value):
		middle_at = value
		emit_changed()
## Left to right instead of top to bottom (bar fills).
@export var horizontal: bool = false:
	set(value):
		horizontal = value
		emit_changed()
@export var border_color: Color = Color("d8dbe6"):
	set(value):
		border_color = value
		emit_changed()
@export var border_width: int = 2:
	set(value):
		border_width = value
		_update_margins()
@export var ring_color: Color = Color("4b5276"):
	set(value):
		ring_color = value
		emit_changed()
@export var ring_width: int = 2:
	set(value):
		ring_width = value
		_update_margins()
@export var corner_radius: int = 7:
	set(value):
		corner_radius = value
		emit_changed()
@export var shadow_color: Color = Color(0, 0, 0, 0.6):
	set(value):
		shadow_color = value
		emit_changed()
@export var shadow_offset: Vector2 = Vector2(0, 3):
	set(value):
		shadow_offset = value
		emit_changed()
## Space between the ring and the content, added to border and ring for the content margins.
@export var padding: int = 10:
	set(value):
		padding = value
		_update_margins()

## Points per rounded corner.
const CORNER_STEPS: int = 6


func _init() -> void:
	_update_margins()


func _update_margins() -> void:
	var margin := float(border_width + ring_width + padding)
	content_margin_left = margin
	content_margin_right = margin
	content_margin_top = margin
	content_margin_bottom = margin
	emit_changed()


## The gradient's colour at `point` of `rect` (the fill area).
func gradient_color(rect: Rect2, point: Vector2) -> Color:
	var t := 0.0
	if horizontal:
		t = (point.x - rect.position.x) / maxf(rect.size.x, 0.001)
	else:
		t = (point.y - rect.position.y) / maxf(rect.size.y, 0.001)
	t = clampf(t, 0.0, 1.0)
	if t <= middle_at:
		return top.lerp(middle, t / maxf(middle_at, 0.001))
	return middle.lerp(bottom, (t - middle_at) / maxf(1.0 - middle_at, 0.001))


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	if shadow_color.a > 0.0 and shadow_offset != Vector2.ZERO:
		_fill(to_canvas_item, _rounded(Rect2(rect.position + shadow_offset, rect.size), corner_radius), shadow_color)
	_fill(to_canvas_item, _rounded(rect, corner_radius), border_color)
	var ring_rect := rect.grow(-border_width)
	_fill(to_canvas_item, _rounded(ring_rect, corner_radius - border_width), ring_color)
	var fill_rect := ring_rect.grow(-ring_width)
	if fill_rect.size.x <= 0.0 or fill_rect.size.y <= 0.0:
		return
	var shape := _rounded(fill_rect, corner_radius - border_width - ring_width)
	var split := fill_rect.position + fill_rect.size * middle_at
	var bands: Array[PackedVector2Array] = []
	if horizontal:
		bands.append(_box(Rect2(fill_rect.position, Vector2(split.x - fill_rect.position.x, fill_rect.size.y))))
		bands.append(_box(Rect2(Vector2(split.x, fill_rect.position.y), Vector2(fill_rect.end.x - split.x, fill_rect.size.y))))
	else:
		bands.append(_box(Rect2(fill_rect.position, Vector2(fill_rect.size.x, split.y - fill_rect.position.y))))
		bands.append(_box(Rect2(Vector2(fill_rect.position.x, split.y), Vector2(fill_rect.size.x, fill_rect.end.y - split.y))))
	for band in bands:
		for piece in Geometry2D.intersect_polygons(shape, band):
			var colors := PackedColorArray()
			for point in piece:
				colors.append(gradient_color(fill_rect, point))
			RenderingServer.canvas_item_add_polygon(to_canvas_item, piece, colors)


func _fill(canvas_item: RID, points: PackedVector2Array, color: Color) -> void:
	if points.size() >= 3:
		RenderingServer.canvas_item_add_polygon(canvas_item, points, PackedColorArray([color]))


static func _box(rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end,
		Vector2(rect.position.x, rect.end.y)])


## A rounded rectangle as a clockwise polygon.
static func _rounded(rect: Rect2, radius: float) -> PackedVector2Array:
	var r := clampf(radius, 0.0, minf(rect.size.x, rect.size.y) * 0.5)
	if r <= 0.0:
		return _box(rect)
	var points := PackedVector2Array()
	var centres := [Vector2(rect.end.x - r, rect.position.y + r), Vector2(rect.end.x - r, rect.end.y - r),
		Vector2(rect.position.x + r, rect.end.y - r), Vector2(rect.position.x + r, rect.position.y + r)]
	var start_angles := [-PI / 2.0, 0.0, PI / 2.0, PI]
	for corner in 4:
		for step in CORNER_STEPS + 1:
			var angle: float = start_angles[corner] + (PI / 2.0) * step / CORNER_STEPS
			points.append(centres[corner] + Vector2(cos(angle), sin(angle)) * r)
	return points
