## Spec ff7-ui 2.2: one run toast (an Isaac-style banner): kicker, title, subtitle. Slides in, fades out; real time,
## so the battle speed never changes it. Empty parts are hidden; empty " · " pieces of a line are dropped.
extends PanelContainer

@export var slide_seconds: float = 0.3
@export var slide_distance: float = 40.0
@export var fade_seconds: float = 0.3


func set_item(toast: Dictionary, _context: UIContext) -> void:
	_fill(%Kicker, toast.get("kicker", ""))
	_fill(%Title, toast.get("title", ""))
	_fill(%Subtitle, toast.get("subtitle", ""))
	if StringName(toast.get("variation", &"")) != &"":
		%Kicker.theme_type_variation = StringName(toast["variation"])
	modulate.a = 0.0
	var tween := create_tween().set_ignore_time_scale(true).set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, slide_seconds)
	tween.tween_property(%Lines, "position:y", 0.0, slide_seconds).from(-slide_distance).set_ease(Tween.EASE_OUT)


func leave() -> void:
	var tween := create_tween().set_ignore_time_scale(true)
	tween.tween_property(self, "modulate:a", 0.0, fade_seconds)
	tween.tween_callback(queue_free)


func _fill(label: Label, text: String) -> void:
	var parts := Array(text.split(" · ")).map(func(part) -> String: return part.strip_edges())
	label.text = " · ".join(PackedStringArray(parts.filter(func(part) -> bool: return part != "")))
	label.visible = label.text != ""
