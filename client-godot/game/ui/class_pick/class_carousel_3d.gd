## Spec class-pick 2.2: the class pick's turntable. Every class stands on one ring (the front stand on the camera axis, at the
## portrait studio's Stand), its real view (UnitAnimator.instantiate_for: look, attachments, look effect) facing the screen. Only
## turn() moves the ring (the arrows, D13); the cubes ride it and never turn about themselves (D3); once the ring rests, the cube
## in front sways a little either side of facing the screen. The studio's rim, glow and mote colour blends to the selected
## class's colour (D4). Presentation only: never read by combat/, the run, a hash, a snapshot or an upload. Headless (or with
## `build_views` false) it builds no views and keeps only its index, so the screen logic still runs in tests.
class_name ClassCarousel3D
extends Node3D

## The selected index changed (at once, on each turn; the ring then eases there).
signal selected_changed(index: int)

## The portrait studio instanced in the scene (lights, motes, backdrop, floor, camera).
@export var studio: PortraitStudio
@export var unit_view_scene: PackedScene
@export var ring_radius: float = 2.4
## The ring's depth as a share of its radius (an oval: above 1 the neighbours sit farther back and read smaller).
@export var ring_depth: float = 1.0
## How long a turn takes. It eases in and out (the same curve both ways, so a cube coming in grows as smoothly as one going
## out shrinks; user, 2026-11-19); a turn pressed while one is under way carries on from where the ring is, easing out only.
@export var turn_seconds: float = 0.25
## The front cube's sway either side of facing the screen (Q2), and one sway cycle.
@export var sway_degrees: float = 15.0
@export var sway_seconds: float = 3.0
@export var color_blend_seconds: float = 0.4
## Cubes farther than `shrink_start` places from the front shrink away, gone at `shrink_end` (they grow back as they come round),
## so the back of the ring never reaches the studio's wall (user, 2026-11-19).
@export var shrink_start: float = 1.0
@export var shrink_end: float = 2.6

var characters: Array = []
var index: int = 0
## Build the views (false headless, or for a test that only needs the index).
var build_views: bool = DisplayServer.get_name() != "headless"
var views: Array[Node3D] = []

var _ring: Node3D
var _position: float = 0.0   # the ring's eased position, in slots (index + whole laps)
var _target: float = 0.0
var _from: float = 0.0       # where the ring was when the turn under way began
var _turn_t: float = 1.0     # 0..1 through it
var _ease_in: bool = true    # false for a turn pressed while another was still going
var _time: float = 0.0
var _color: Color = Color.WHITE
var _color_from: Color = Color.WHITE
var _color_to: Color = Color.WHITE
var _color_t: float = 1.0


func _ready() -> void:
	# A quality change re-applies the running effects' layers (their own particle space): take the ring's space again after it.
	FxManager.quality_changed.connect(func(_tier: int) -> void:
		for view in views:
			var anchor: Node3D = view.look_anchor if view is UnitAnimator else null
			if anchor != null and is_instance_valid(anchor):
				anchor.remove_meta(&"carousel_children"))
	_ring = Node3D.new()
	_ring.name = "Ring"
	add_child(_ring)
	if studio != null:
		_ring.position = studio.stand().position


## Stands `list` (CharacterDefinitions, in ring order) and greys the ids `locked` names (id String → true). Keeps the index when
## it is still in range.
func show_characters(list: Array, locked: Dictionary = {}) -> void:
	characters = list.duplicate()
	index = clampi(index, 0, maxi(characters.size() - 1, 0))
	_position = float(index)
	_target = _position
	_from = _position
	_turn_t = 1.0
	for view in views:
		view.queue_free()
	views.clear()
	if build_views and _ring != null and unit_view_scene != null:
		for character in characters:
			var view := UnitAnimator.instantiate_for(character, unit_view_scene)
			if view is UnitAnimator:
				(view as UnitAnimator).facing_override = 0.0
				(view as UnitAnimator).upright_look_effect = true   # the floor effect stays still while the cube sways
			_ring.add_child(view)
			if view.has_method("setup"):
				view.setup("", character.display_color)
			if view.has_method("set_stats"):
				view.set_stats("")
			views.append(view)
	set_locked(locked)
	_place()
	_color_from = _class_color()
	_color_to = _color_from
	_color_t = 1.0
	_apply_color(_color_to)


## Greys the views of the ids `locked` names; the others get their colours back.
func set_locked(locked: Dictionary) -> void:
	for i in views.size():
		var view := views[i] as UnitAnimator
		if view != null and i < characters.size():
			view.set_greyed(locked.has(String(characters[i].id)))


## The selected character, or null.
func selected() -> CharacterDefinition:
	return characters[index] if index >= 0 and index < characters.size() else null


## Turns the ring `steps` classes (positive = the next to the right comes to the front), wrapping around.
func turn(steps: int) -> void:
	if characters.is_empty() or steps == 0:
		return
	index = wrapi(index + steps, 0, characters.size())
	_ease_in = not turning()
	_from = _position
	_target += steps
	_turn_t = 0.0
	_start_color_blend()
	selected_changed.emit(index)


## Brings `target_index` to the front the shortest way (scripts and tests; the player uses the arrows).
func select(target_index: int) -> void:
	if characters.is_empty():
		return
	var count := characters.size()
	var delta := wrapi(target_index - index, 0, count)
	if delta > count / 2:
		delta -= count
	turn(delta)


## True while the ring is still easing toward the selected class.
## The front cube on screen, in the viewport's pixels: its centre and its height (the body, without hats). Rect2() without a
## camera. The class pick puts the lock over it (user, 2026-11-19).
func front_on_screen(body_height: float = 0.8) -> Rect2:
	var camera := studio.camera() if studio != null else null
	if camera == null or _ring == null or not camera.is_inside_tree():
		return Rect2()
	var centre := camera.unproject_position(_ring.global_position)
	var top := camera.unproject_position(_ring.global_position + Vector3(0.0, body_height * 0.5, 0.0))
	var height := absf(centre.y - top.y) * 2.0
	return Rect2(centre - Vector2(height, height) * 0.5, Vector2(height, height))


func turning() -> bool:
	return _turn_t < 1.0


func _process(delta: float) -> void:
	_time += delta
	if turning():
		_turn_t = minf(_turn_t + delta / maxf(turn_seconds, 0.01), 1.0)
		var eased := smoothstep(0.0, 1.0, _turn_t) if _ease_in else 1.0 - (1.0 - _turn_t) * (1.0 - _turn_t)
		_position = lerpf(_from, _target, eased)
	if _color_t < 1.0:
		_color_t = minf(_color_t + delta / maxf(color_blend_seconds, 0.01), 1.0)
		_apply_color(_color_from.lerp(_color_to, smoothstep(0.0, 1.0, _color_t)))
	_place()


## Each view on the ring at its slot's angle; the front one sways once the ring rests.
func _place() -> void:
	var count := views.size()
	if count == 0:
		return
	var settle := 1.0 - clampf(absf(_target - _position) * 2.0, 0.0, 1.0)
	var sway := deg_to_rad(sway_degrees) * sin(_time * TAU / maxf(sway_seconds, 0.01)) * settle
	for i in count:
		var offset := fposmod(float(i) - _position + count * 0.5, float(count)) - count * 0.5
		var angle := offset * TAU / count
		views[i].position = Vector3(ring_radius * sin(angle), 0.0, ring_radius * ring_depth * (cos(angle) - 1.0))
		var front := 1.0 - clampf(absf(offset) * 2.0, 0.0, 1.0)
		views[i].rotation = Vector3(0.0, sway * front, 0.0)
		var anchor: Node3D = views[i].look_anchor if views[i] is UnitAnimator else null
		if anchor != null and is_instance_valid(anchor):
			anchor.rotation = Vector3(0.0, -sway * front, 0.0)   # the floor effect holds still
		var size := 1.0 - smoothstep(shrink_start, shrink_end, absf(offset))
		views[i].scale = Vector3.ONE * maxf(size, 0.001)
		var shown := size > 0.01
		if shown and not views[i].visible:
			_clear_particles(views[i])
		views[i].visible = shown
		_particles_in_view_space(views[i])


## A look effect's particles live in the world by default: they would keep their full size on a cube shrunk at the back of the
## ring and trail behind it as it turns (user, 2026-11-19). On the ring they live in the cube's own space instead, so they scale
## and travel with it. Checked when the effect's nodes change (it starts a frame after the view is built).
func _particles_in_view_space(view: Node3D) -> void:
	var anchor: Node3D = view.look_anchor if view is UnitAnimator else null
	if anchor == null or not is_instance_valid(anchor):
		return
	var count := anchor.get_child_count()
	if int(anchor.get_meta(&"carousel_children", -1)) == count:
		return
	anchor.set_meta(&"carousel_children", count)
	for particles in anchor.find_children("*", "GPUParticles3D", true, false):
		(particles as GPUParticles3D).local_coords = true
	for particles in anchor.find_children("*", "CPUParticles3D", true, false):
		(particles as CPUParticles3D).local_coords = true


## A cube hidden at the back wraps from one side of the ring to the other; its effect's particles live in the world, so those
## emitted on the old side would flash there as it shows again (user, 2026-11-19). Clear them as it comes into view.
static func _clear_particles(view: Node) -> void:
	for particles in view.find_children("*", "GPUParticles3D", true, false):
		(particles as GPUParticles3D).restart()
	for particles in view.find_children("*", "CPUParticles3D", true, false):
		(particles as CPUParticles3D).restart()


func _start_color_blend() -> void:
	_color_from = _color
	_color_to = _class_color()
	_color_t = 0.0 if color_blend_seconds > 0.0 else 1.0
	if _color_t >= 1.0:
		_apply_color(_color_to)


## The selected class's colour (Q1): the studio's approved rim colour, else the class's display_color.
func _class_color() -> Color:
	var character := selected()
	if character == null:
		return studio.default_rim if studio != null else Color.WHITE
	return studio.rim_color(character.id, character.display_color) if studio != null else character.display_color


func _apply_color(color: Color) -> void:
	_color = color
	if studio != null:
		studio.apply_color(color)
