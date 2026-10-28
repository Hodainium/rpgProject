## Spec ff7-ui 2.2: one line of the battle feed ("Warrior used Ice Blast"). The rule's variation colours the text
## (FeedCritical, FeedBroken, FeedDown, FeedUlt, FeedHeal). Slides in from the left, fades out; real time.
extends PanelContainer

@export var slide_seconds: float = 0.25
@export var slide_distance: float = 30.0
@export var fade_seconds: float = 0.5


func set_item(toast: Dictionary, _context: UIContext) -> void:
	%Text.text = toast.get("title", "")
	%Text.theme_type_variation = StringName(toast.get("variation", &""))
	modulate.a = 0.0
	# On the tween's first step (next frame, once the line is laid out); the tween dies with the line.
	create_tween().set_ignore_time_scale(true).tween_callback(_slide_in)


## Slides the text in from the left to the place the line's layout gave it (spec ui-fixes B5).
func _slide_in() -> void:
	var place: float = %Text.position.x
	var tween := create_tween().set_ignore_time_scale(true).set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, slide_seconds)
	tween.tween_property(%Text, "position:x", place, slide_seconds).from(place - slide_distance).set_ease(
		Tween.EASE_OUT)


func leave() -> void:
	var tween := create_tween().set_ignore_time_scale(true)
	tween.tween_property(self, "modulate:a", 0.0, fade_seconds)
	tween.tween_callback(queue_free)
