## Spec ff7-ui 2.2: one line of the battle feed ("Warrior used Ice Blast"). The rule's variation colours the text
## (FeedCritical, FeedBroken, FeedDown, FeedUlt, FeedHeal). Slides in from the left, fades out; real time.
extends PanelContainer

@export var slide_seconds: float = 0.25
@export var slide_distance: float = 30.0
@export var fade_seconds: float = 0.5


## How far left of its laid-out place the text is (−slide_distance → 0 while sliding in).
var _slide: float = 0.0


func set_item(toast: Dictionary, _context: UIContext) -> void:
	%Text.text = toast.get("title", "")
	%Text.theme_type_variation = StringName(toast.get("variation", &""))
	modulate.a = 0.0
	# Spec playtest-fixes B8: the offset is added after every layout pass, so the slide never ends at a place read
	# before the line was laid out (a line pushed from a timer used to end at x 0). The tween dies with the line.
	sort_children.connect(_apply_slide)
	var tween := create_tween().set_ignore_time_scale(true).set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, slide_seconds)
	tween.tween_method(_set_slide, -slide_distance, 0.0, slide_seconds).set_ease(Tween.EASE_OUT)


## Slides the text in from the left to the place the line's layout gives it (spec ui-fixes B5).
func _set_slide(offset: float) -> void:
	_slide = offset
	queue_sort()  # the layout puts the text back at its place, then _apply_slide moves it


func _apply_slide() -> void:
	%Text.position.x += _slide


func leave() -> void:
	var tween := create_tween().set_ignore_time_scale(true)
	tween.tween_property(self, "modulate:a", 0.0, fade_seconds)
	tween.tween_callback(queue_free)
