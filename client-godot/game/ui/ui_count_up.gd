## A number on a label that counts up or down to its new value (gems, dust) instead of jumping: the Shop, the Collection and
## Open packs share it (it was copied in each). A negative value hides the label (the total is unknown: offline, no session).
## Presentation only.
class_name UICountUp
extends RefCounted

var label: Label
## The label's text, with one %d for the number ("%d gems").
var template: String
var seconds: float
## The number on the label now (-1 = none shown yet: the next value shows at once, nothing to count from).
var shown: float = -1.0
var _tween: Tween


func _init(target: Label, text: String, tween_seconds: float = 0.6) -> void:
	label = target
	template = text
	seconds = tween_seconds


## Shows `value`; `animate` counts from the number shown (when there is one).
func set_value(value: int, animate: bool) -> void:
	label.visible = value >= 0
	if _tween != null:
		_tween.kill()
		_tween = null
	if value < 0:
		shown = -1.0
		return
	if not animate or shown < 0.0 or seconds <= 0.0 or not label.is_inside_tree():
		_show(float(value))
		return
	_tween = label.create_tween()
	_tween.tween_method(_show, shown, float(value), seconds)


func _show(value: float) -> void:
	shown = value
	label.text = template % roundi(value)
