## Spec card-ui 3.2: the card back drawn in code when the style has no `back_texture`: navy with a gold frame and the cube
## emblem (the game's cubes), at the face's design size (CardFaceView.SIZE) so CardView3D renders it like a face. Presentation only.
class_name CardBackView
extends Control

@export var texture: Texture2D
@export var navy_light: Color = Color("24306e")
@export var navy_dark: Color = Color("0c1233")
@export var gold: Color = Color("e9c46a")
@export var gold_dark: Color = Color("9a7a2c")
@export var border: Color = Color("05060c")


func _init() -> void:
	size = CardFaceView.SIZE
	custom_minimum_size = CardFaceView.SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var area := Rect2(Vector2.ZERO, CardFaceView.SIZE)
	if texture != null:
		draw_texture_rect(texture, area, false)
		return
	draw_rect(area, border)
	var inner := area.grow(-10)
	var points := PackedVector2Array([inner.position, Vector2(inner.end.x, inner.position.y), inner.end,
		Vector2(inner.position.x, inner.end.y)])
	draw_polygon(points, PackedColorArray([navy_light, navy_light, navy_dark, navy_dark]))
	draw_rect(inner.grow(-8), gold, false, 3.0)
	draw_rect(inner.grow(-16), gold_dark, false, 1.5)
	# A diamond lattice, faint.
	var lattice := Color(gold, 0.08)
	var step := 28.0
	var box := inner.grow(-18)
	var x := box.position.x - box.size.y
	while x < box.end.x:
		draw_line(_clip(box, Vector2(x, box.position.y), Vector2(x + box.size.y, box.end.y)), _clip_end(box, Vector2(x, box.position.y),
			Vector2(x + box.size.y, box.end.y)), lattice, 1.0)
		draw_line(_clip(box, Vector2(x + box.size.y, box.position.y), Vector2(x, box.end.y)), _clip_end(box, Vector2(x + box.size.y,
			box.position.y), Vector2(x, box.end.y)), lattice, 1.0)
		x += step
	_draw_cube(area.get_center(), 62.0)


## An isometric cube: three faces in gold shades with dark edges.
func _draw_cube(center: Vector2, radius: float) -> void:
	var h := radius * 0.866
	var top := center + Vector2(0, -radius)
	var right_top := center + Vector2(h, -radius * 0.5)
	var right_bottom := center + Vector2(h, radius * 0.5)
	var bottom := center + Vector2(0, radius)
	var left_bottom := center + Vector2(-h, radius * 0.5)
	var left_top := center + Vector2(-h, -radius * 0.5)
	draw_colored_polygon(PackedVector2Array([top, right_top, center, left_top]), gold.lightened(0.25))
	draw_colored_polygon(PackedVector2Array([left_top, center, bottom, left_bottom]), gold)
	draw_colored_polygon(PackedVector2Array([center, right_top, right_bottom, bottom]), gold_dark)
	var outline := PackedVector2Array([top, right_top, right_bottom, bottom, left_bottom, left_top, top])
	draw_polyline(outline, navy_dark, 3.0)
	draw_line(center, left_top, navy_dark, 2.0)
	draw_line(center, right_top, navy_dark, 2.0)
	draw_line(center, bottom, navy_dark, 2.0)
	draw_arc(center, radius * 1.35, 0.0, TAU, 64, gold_dark, 2.0)


## The segment a→b clipped to `box` (Liang–Barsky): its start, and _clip_end its end.
static func _clip(box: Rect2, a: Vector2, b: Vector2) -> Vector2:
	var t := _clip_range(box, a, b)
	return a.lerp(b, t.x)


static func _clip_end(box: Rect2, a: Vector2, b: Vector2) -> Vector2:
	var t := _clip_range(box, a, b)
	return a.lerp(b, t.y)


static func _clip_range(box: Rect2, a: Vector2, b: Vector2) -> Vector2:
	var t0 := 0.0
	var t1 := 1.0
	var d := b - a
	var p := [-d.x, d.x, -d.y, d.y]
	var q := [a.x - box.position.x, box.end.x - a.x, a.y - box.position.y, box.end.y - a.y]
	for i in 4:
		if absf(p[i]) < 0.0001:
			if q[i] < 0.0:
				return Vector2(0, 0)
			continue
		var r: float = q[i] / p[i]
		if p[i] < 0.0:
			t0 = maxf(t0, r)
		else:
			t1 = minf(t1, r)
	return Vector2(t0, maxf(t0, t1))
