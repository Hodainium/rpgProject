## Spec cube-style 3.9: where the room camera stands, out of battle (StyleRegistry.explore_camera) or in battle (battle_camera).
## The defaults are today's camera, so a framing left at its defaults changes nothing. Presentation only.
class_name CameraFraming
extends Resource

@export var position: Vector3 = Vector3(0, 9, 8)
@export var rotation_degrees: Vector3 = Vector3(-50, 0, 0)
@export_range(1.0, 179.0) var fov: float = 75.0


## Today's framing (what RoomView3D always used).
static func today() -> CameraFraming:
	return CameraFraming.new()


## The camera's running framing move is kept on the camera under this meta key, so a new framing (or an instant one) stops it
## first and the old move never overwrites the new framing.
const TWEEN_META: StringName = &"framing_tween"


## Places `camera` at this framing now (stopping a framing move still running).
func apply_to(camera: Camera3D) -> void:
	stop_move(camera)
	camera.position = position
	camera.rotation_degrees = rotation_degrees
	camera.fov = fov


## Moves `camera` to this framing over `seconds` (0 = at once), replacing a move still running. Returns the tween, or null when it
## applied at once.
func tween_to(camera: Camera3D, seconds: float) -> Tween:
	if seconds <= 0.0 or not camera.is_inside_tree() or is_at(camera):
		apply_to(camera)
		return null
	stop_move(camera)
	var tween := camera.create_tween().set_parallel().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(camera, "position", position, seconds)
	tween.tween_property(camera, "rotation_degrees", rotation_degrees, seconds)
	tween.tween_property(camera, "fov", fov, seconds)
	camera.set_meta(TWEEN_META, tween)
	return tween


## Whether `camera` already stands at this framing (then a move would do nothing: no tween is made).
func is_at(camera: Camera3D) -> bool:
	return camera.position.is_equal_approx(position) and camera.rotation_degrees.is_equal_approx(rotation_degrees) \
		and is_equal_approx(camera.fov, fov)


## Stops the framing move running on `camera`, if any.
static func stop_move(camera: Camera3D) -> void:
	if camera.has_meta(TWEEN_META):
		var running: Tween = camera.get_meta(TWEEN_META)
		if running != null and running.is_valid():
			running.kill()
		camera.remove_meta(TWEEN_META)
