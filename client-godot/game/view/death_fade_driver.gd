## Spec battle-death-fade 3.2: plays a DeathFade on a dying enemy's view: every material under the view (the body and its
## attachments) goes to alpha mode, flashes white, tints to the fade colour with a glow, fades to nothing; then the view hides.
## Emits `finished` after the fade plus the end beat (what the battle's end waits for). Its own presentation clock (a child
## node, so the view's processing is left alone). cancel() puts every material back (a revive).
class_name DeathFadeDriver
extends Node

signal finished

## Every fade still in the tree joins this group; ViewGate.hold_end() waits while one of them is not done.
const GROUP: StringName = &"death_fades"

var fade: DeathFade
var clock: float = 0.0
var _view: Node3D
## [MeshInstance3D, its material before the fade, its fade copy].
var _meshes: Array = []
## [Label3D, its modulate, its outline modulate]: the unit's name and HP fade with it (review fix).
var _labels: Array = []
var _hidden: bool = false
var _done: bool = false


func _init(on_view: Node3D, settings: DeathFade) -> void:
	name = "DeathFade"
	_view = on_view
	fade = settings


func _ready() -> void:
	add_to_group(GROUP)
	for mesh in _view.find_children("*", "MeshInstance3D", true, false):
		var original := (mesh as MeshInstance3D).material_override as BaseMaterial3D
		if original == null:
			continue
		var copy := original.duplicate() as BaseMaterial3D
		copy.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA  # a transparent material takes no stencil stamp: accepted (spec 3.2)
		copy.stencil_mode = BaseMaterial3D.STENCIL_MODE_DISABLED
		copy.emission_enabled = true
		copy.emission = Color.BLACK
		_meshes.append([mesh, original, copy])
		(mesh as MeshInstance3D).material_override = copy
	for label in _view.find_children("*", "Label3D", true, false):
		_labels.append([label, (label as Label3D).modulate, (label as Label3D).outline_modulate])
	advance(0.0)


func _process(delta: float) -> void:
	advance(delta)


## Moves the fade on by `delta` seconds (tests drive it directly).
func advance(delta: float) -> void:
	if _done:
		return
	clock += delta
	var flash_end := fade.flash_seconds
	var tint_end := flash_end + fade.tint_seconds
	var fade_end := tint_end + fade.fade_seconds
	for entry in _meshes:
		var original: BaseMaterial3D = entry[1]
		var copy: BaseMaterial3D = entry[2]
		var base := original.albedo_color
		if clock < flash_end:
			copy.albedo_color = Color(1, 1, 1, 1)
			copy.emission = Color.WHITE
			copy.emission_energy_multiplier = maxf(fade.emission, 1.0)
		else:
			var tint := 1.0 if fade.tint_seconds <= 0.0 else clampf((clock - flash_end) / fade.tint_seconds, 0.0, 1.0)
			var alpha := 1.0 if clock < tint_end or fade.fade_seconds <= 0.0 else 1.0 - clampf((clock - tint_end) / fade.fade_seconds, 0.0, 1.0)
			var color := base.lerp(fade.color, tint)
			copy.albedo_color = Color(color.r, color.g, color.b, alpha)
			copy.emission = fade.color * tint
			copy.emission_energy_multiplier = fade.emission * alpha
	var label_alpha := 1.0 if clock < tint_end or fade.fade_seconds <= 0.0 else 1.0 - clampf((clock - tint_end) / fade.fade_seconds, 0.0, 1.0)
	for entry in _labels:
		if is_instance_valid(entry[0]):
			var label := entry[0] as Label3D
			label.modulate = Color(entry[1].r, entry[1].g, entry[1].b, entry[1].a * label_alpha)
			label.outline_modulate = Color(entry[2].r, entry[2].g, entry[2].b, entry[2].a * label_alpha)
	if not _hidden and clock >= fade_end:
		_hidden = true
		_view.visible = false
	if clock >= fade_end + fade.end_beat:
		_done = true
		set_process(false)
		finished.emit()


## True once the fade and its end beat are over.
func is_done() -> bool:
	return _done


## Ends the fade now (the battle's end stopped waiting: Skip, or the cap): the view hides, `finished` is emitted.
func finish_now() -> void:
	if _done:
		return
	advance(fade.hold_seconds() - clock + 0.001)


## Stops the fade and puts every material and label back and the view in sight (a revive). Does not emit `finished`.
func cancel() -> void:
	for entry in _meshes:
		if is_instance_valid(entry[0]):
			(entry[0] as MeshInstance3D).material_override = entry[1]
	for entry in _labels:
		if is_instance_valid(entry[0]):
			(entry[0] as Label3D).modulate = entry[1]
			(entry[0] as Label3D).outline_modulate = entry[2]
	_view.visible = true
	_done = true
	set_process(false)
