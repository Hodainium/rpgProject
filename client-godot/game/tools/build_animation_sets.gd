## Builds the demo's default unit animation set (spec animation-sets 3.3) from the cube motions unit_view.gd used to
## tween by hand. Writes into presentation/demo/animation_sets/ only and never overwrites an existing file, like
## build_demo. Run once with the user's go-ahead; afterwards the files are theirs to tune.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_animation_sets.tscn
extends Node

const ROOT: String = "res://presentation/demo/animation_sets/"

var _written: int = 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "default"))
	var tilt := Vector3(0, 0, PI / 2)
	var animations := {
		# Gentle bob while waiting.
		&"idle": _animation(1.6, true, "Body:position", [Vector3.ZERO, Vector3(0, 0.05, 0), Vector3.ZERO]),
		# Waddle (unused until in-room walking).
		&"walk": _animation(0.5, true, "Body:rotation", [Vector3.ZERO, Vector3(0, 0, 0.08), Vector3.ZERO,
			Vector3(0, 0, -0.08), Vector3.ZERO]),
		# Additive: the old hit flash, a quick scale pulse around the rest scale.
		&"hit": _animation(0.18, false, "Body:scale", [Vector3.ONE, Vector3.ONE * 1.25, Vector3.ONE]),
		# Additive: a squash.
		&"block": _animation(0.25, false, "Body:scale", [Vector3.ONE, Vector3(1.1, 0.8, 1.1), Vector3.ONE]),
		# Falls onto its side, then stays there.
		&"death": _animation(0.4, false, "Body:rotation", [Vector3.ZERO, tilt]),
		&"dead": _animation(0.5, true, "Body:rotation", [tilt, tilt]),
		&"revive": _animation(0.4, false, "Body:rotation", [tilt, Vector3.ZERO]),
		# A spin with a hop.
		&"victory": _animation(0.8, false, "Body:rotation", [Vector3.ZERO, Vector3(0, PI, 0), Vector3(0, TAU, 0)],
			"Body:position", [Vector3.ZERO, Vector3(0, 0.5, 0), Vector3.ZERO]),
		# The hop the cube did under abilities that don't move it.
		&"cast": _animation(0.3, false, "Body:position", [Vector3.ZERO, Vector3(0, 0.8, 0), Vector3.ZERO]),
	}
	for slot in animations:
		_save(animations[slot], ROOT + "default/%s.tres" % slot)
	var set_path := ROOT + "default.tres"
	if not FileAccess.file_exists(set_path):
		var default_set := UnitAnimationSet.new()
		for slot in animations:
			default_set.set(slot, load(ROOT + "default/%s.tres" % slot))
		_save(default_set, set_path)
	print("Animation sets under %s: %d file(s) written" % [ROOT, _written])
	get_tree().quit(0)


## Keys spread evenly over `length`, on one or two value tracks.
func _animation(length: float, looping: bool, path: String, values: Array, second_path: String = "",
		second_values: Array = []) -> Animation:
	var animation := Animation.new()
	animation.length = length
	if looping:
		animation.loop_mode = Animation.LOOP_LINEAR
	_track(animation, path, values)
	if second_path != "":
		_track(animation, second_path, second_values)
	return animation


func _track(animation: Animation, path: String, values: Array) -> void:
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath(path))
	for index in values.size():
		animation.track_insert_key(track, animation.length * index / maxf(values.size() - 1, 1), values[index])


func _save(resource: Resource, path: String) -> void:
	if FileAccess.file_exists(path):
		return
	var error := ResourceSaver.save(resource, path)
	if error != OK:
		push_error("build_animation_sets: could not save %s (%s)" % [path, error_string(error)])
		return
	_written += 1
