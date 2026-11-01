## Spec playtest-fixes B9: a reusable busy indicator, a spinning arc drawn in code (no texture). Turns in real time
## while visible; put it in any screen that waits on something.
class_name UISpinner
extends Control

@export var color: Color = Color(1, 1, 1)
## The faint full ring behind the arc (alpha 0 hides it).
@export var track_color: Color = Color(1, 1, 1, 0.15)
@export var thickness: float = 4.0
## How much of the circle the arc covers, in degrees.
@export_range(10.0, 350.0) var arc_degrees: float = 270.0
## Turns per second.
@export var speed: float = 1.2

var _angle: float = 0.0


func _ready() -> void:
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(32, 32)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	var real := delta / maxf(Engine.time_scale, 0.0001)  # real time, like the toasts
	_angle = fmod(_angle + TAU * speed * real, TAU)
	queue_redraw()


func _draw() -> void:
	var radius := minf(size.x, size.y) * 0.5 - thickness * 0.5
	if radius <= 0.0:
		return
	var centre := size * 0.5
	if track_color.a > 0.0:
		draw_arc(centre, radius, 0.0, TAU, 48, track_color, thickness, true)
	draw_arc(centre, radius, _angle, _angle + deg_to_rad(arc_degrees), 48, color, thickness, true)
