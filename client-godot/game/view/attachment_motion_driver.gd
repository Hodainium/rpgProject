## Spec cube-style 3.3: moves a view's attachments (bob, spin, flap) on its own presentation clock. A child of the attachments
## holder, so it leaves the view's own processing alone (a custom view may have a _process of its own) and goes with the holder.
## Never in a hash.
class_name AttachmentMotionDriver
extends Node

## [UnitAttachment, [[pivot, rest transform], ...]] for each attachment that moves.
var moving: Array = []
var clock: float = 0.0


func _init() -> void:
	name = "Motion"


## Runs the motion, or stops it and puts every pivot back at rest (a dead unit is still).
func set_running(running: bool) -> void:
	running = running and not moving.is_empty()
	set_process(running)
	if not running:
		for entry in moving:
			for pivot in entry[1]:
				(pivot[0] as Node3D).transform = pivot[1]


func _process(delta: float) -> void:
	clock += delta
	for entry in moving:
		var attachment: UnitAttachment = entry[0]
		for pivot in entry[1]:
			(pivot[0] as Node3D).transform = attachment.animate(pivot[1], clock)
