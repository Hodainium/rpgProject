## A unit's view (spec animation-sets): plays its UnitAnimationSet and the abilities it casts through one shared
## AnimationTree, and releases the battle's presentation gate from the ability's `execute` keys.
##
## Tree (built once in code, shared by every unit; each unit has its own libraries and parameters):
##   state (StateMachine over the slots) ─▶ montage (OneShot: the cast ability's animation) ─▶ flinch (Add2) ─▶ output
##                                                          react (OneShot over a neutral pose: hit / block) ─┘
## The montage plays `montage/current`, swapped per cast, so the shared tree is never edited. The flinch is additive:
## a unit hit mid-cast keeps casting. Death waits for a running cast. Presentation only: nothing here touches combat
## state, and the headless verifier never builds a view.
## A view scene's root script extends this (the demo cube: presentation/demo/unit_view.gd) and may override _paint().
class_name UnitAnimator
extends Node3D

const MONTAGE: StringName = &"montage/current"
## Extra time after an ability animation's length before the gate is released anyway (a broken or interrupted
## animation never stalls the battle).
const SAFETY_SECONDS: float = 0.5
const MONTAGE_FADE: float = 0.1
## Value-track properties that move a model; an ability animation with none of them gets the set's `cast` merged in.
const MODEL_PROPERTIES: Array[String] = ["position", "rotation", "rotation_degrees", "scale", "transform",
	"quaternion", "basis", "visible"]
const STATES: Array[StringName] = [&"idle", &"walk", &"cast", &"death", &"dead", &"revive", &"victory"]
## Every live view joins this group (the console's `anim` finds them through it).
const GROUP: StringName = &"unit_animators"

@export var animation_set: UnitAnimationSet
@export var label: Label3D

var tree: AnimationTree
var display_color: Color = Color.WHITE
var is_dead: bool = false
## The unit definition this view shows (set by instantiate_for).
var definition_id: StringName = &""
## Spec cube-style 3.2: the definition itself and its resolved look (UnitStyle), both set by instantiate_for; look null = no style
## registry in use (today's look). A view paints with body_color() and body_material().
var unit_definition: UnitDefinition
var look: UnitLook
## Spec cube-style 3.4: the body's size, centred on the view, for the attachment sockets (the demo cube: 0.8).
@export var body_size: Vector3 = Vector3(0.8, 0.8, 0.8)
## Spec cube-style 3.3: the look's attachments, under the "Body" node (so unit animations move them) or the view.
var _attachments: Node3D
## [UnitAttachment, [[pivot, rest transform], ...]] for each attachment that moves.
var _moving: Array = []
## The attachments' presentation clock (never in a hash).
var _style_clock: float = 0.0
var _warned_missing_shape: bool = false
## Meta key on each attachment mesh: the part's own material, repainted from on a stencil change or a death.
const STYLE_PAINT: StringName = &"style_paint"
## Spec vfx-content-pass 3.6: the unit's radius for effects (world units). 0 = derived from its mesh's bounding sphere.
@export var fx_radius: float = 0.0
## The battle unit this view shows ("P1", "E2"), set by the room view; the effects system finds a unit's view by it
## (spec vfx-framework: FxAnchor.unit). Empty outside a battle.
var unit_id: StringName = &"":
	set(value):
		unit_id = value
		_face_attachments()  # spec cube-style 3.4: an enemy's attachments turn toward the party
## Spec vfx-stencil 3.2: the stencil value of the unit's battle position (StencilIds), set by the room view; 0 = none (stencil off,
## outside a battle). A new value repaints the view, and _paint() stamps it through mark_stencil().
var stencil_value: int = 0:
	set(value):
		if value == stencil_value:
			return
		stencil_value = value
		_stamped = false  # nothing carries the new value until a paint stamps it
		if is_node_ready():
			_paint()  # before ready, the view's own setup paints (its nodes are not there yet)
			_repaint_attachments()  # spec cube-style: their materials carry the stamp too

## Whether the latest mark_stencil() stamped its material (a view that never calls it, as the base _paint() does, stays false:
## its effects use the plain depth test). The latest paint decides, so a unit that fades out and comes back solid is stamped again.
var _stamped: bool = false
var _warned_unstamped: bool = false

var _gate: ClientGate
var _cast_id: int = 0
var _pending_death: bool = false
## The montage was seen playing since the last cast started (its end is when it stops).
var _montage_live: bool = false

static var _shared_tree: AnimationNodeBlendTree
static var _merged: Dictionary = {}  # "ability id:cast id" -> merged Animation


func _ready() -> void:
	add_to_group(GROUP)
	tree = AnimationTree.new()
	tree.name = "AnimationTree"
	add_child(tree)
	tree.root_node = NodePath("..")
	tree.callback_mode_method = AnimationMixer.ANIMATION_CALLBACK_MODE_METHOD_IMMEDIATE
	_add_libraries()
	tree.tree_root = shared_tree()
	tree.animation_finished.connect(_on_animation_finished)
	tree.mixer_applied.connect(_on_mixer_applied)
	tree.active = true
	tree.set("parameters/flinch/add_amount", 1.0)
	_start(&"idle")
	_build_attachments()


## The scene to instantiate for a unit: its definition's `view` (a res:// or uid:// path), else `default_scene`.
static func view_scene(definition: UnitDefinition, default_scene: PackedScene) -> PackedScene:
	if definition != null and definition.view != "" and ResourceLoader.exists(definition.view):
		var scene := load(definition.view) as PackedScene
		if scene != null:
			return scene
	return default_scene


## A new view for `definition` (view_scene), tagged with its id.
static func instantiate_for(definition: UnitDefinition, default_scene: PackedScene) -> Node3D:
	var view: Node3D = view_scene(definition, default_scene).instantiate()
	if view is UnitAnimator and definition != null:
		view.definition_id = definition.id
		view.unit_definition = definition
		view.look = UnitStyle.look_for(definition)  # spec cube-style: null headless or with no registry
	return view


## Spec cube-style 3.2: the body's colour: the look's override, else the definition's display_color (setup's colour).
func body_color() -> Color:
	return look.body_color(display_color) if look != null else display_color


## Spec cube-style 3.2: a new body material in `color` with this unit's look (rim, roughness). A look with a surface (3.4) starts
## from a copy of that surface (its textures and bumps) tinted by `color`, so one stone dresses any unit in its own colour (and a
## dead one in grey). Pass it through mark_stencil().
func body_material(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D
	if look != null and look.surface != null:
		material = look.surface.duplicate() as StandardMaterial3D
	else:
		material = StandardMaterial3D.new()
	material.albedo_color = color
	if look != null:
		look.paint(material)
	return material


## Spec cube-style 3.8: resolves the look again from the registry in use (the console's `style` changes it) and repaints.
func restyle() -> void:
	look = UnitStyle.look_for(unit_definition) if unit_definition != null else null
	if is_node_ready():
		_paint()
		_build_attachments()


## Spec cube-style 3.4: a socket's position on the body (centred on the view) in the unit's own frame, before facing turns it:
## Center, Top, Base, and the face centres Front (+Z, toward its opponents once faced), Back, and its own Left (+X) and Right (-X).
## An unknown socket is the centre.
func socket_position(socket: StringName) -> Vector3:
	var half := body_size * 0.5
	match socket:
		&"Top":
			return Vector3(0, half.y, 0)
		&"Base":
			return Vector3(0, -half.y, 0)
		&"Front":
			return Vector3(0, 0, half.z)
		&"Back":
			return Vector3(0, 0, -half.z)
		&"Left":
			return Vector3(half.x, 0, 0)  # facing +Z with up +Y, the unit's own left is +X
		&"Right":
			return Vector3(-half.x, 0, 0)
	return Vector3.ZERO


## The node holding the look's attachments (null when it wears nothing).
func attachments_node() -> Node3D:
	return _attachments


## Spec cube-style 3.3: (re)builds the look's attachments at their sockets, then paints them (_repaint_attachments). Called at ready
## and on restyle(); a new stencil value or a death only repaints.
func _build_attachments() -> void:
	if _attachments != null:
		_attachments.free()
		_attachments = null
	_moving.clear()
	set_process(false)
	if look == null or look.attachments.is_empty():
		return
	var body := get_node_or_null(^"Body") as Node3D
	_attachments = Node3D.new()
	_attachments.name = "Attachments"
	(body if body != null else self).add_child(_attachments)
	for attachment in look.attachments:
		if attachment == null or attachment.shape == null:
			if not _warned_missing_shape:  # spec cube-style 4: the unit without it, a warning once per unit
				_warned_missing_shape = true
				push_warning("style: unit '%s' lists an attachment with no shape (style check)" % definition_id)
			continue
		var pivots: Array = []
		_attachments.add_child(attachment.build(socket_position(attachment.socket), Callable(), pivots))
		if attachment.motion != UnitAttachment.Motion.NONE:
			_moving.append([attachment, pivots])
	for mesh in _attachments.find_children("*", "MeshInstance3D", true, false):
		mesh.set_meta(STYLE_PAINT, (mesh as MeshInstance3D).material_override)  # the part's own material, before any stamp
	_face_attachments()
	_repaint_attachments()


## Spec cube-style 3.4: which way the unit faces, as a turn around Y of its attachments (their Front is local +Z, toward the
## camera): toward its opponents. The party stands on the left and turns toward +X; enemies (battle ids "E…") toward -X. How far
## (90 = sideways, 45 = three-quarter) is the style registry's facing().
func facing_degrees() -> float:
	var registry := UnitStyle.registry()
	var turn := registry.facing() if registry != null else 90.0
	return -turn if String(unit_id).begins_with("E") else turn


func _face_attachments() -> void:
	if _attachments != null:
		_attachments.rotation_degrees = Vector3(0, facing_degrees(), 0)


## Paints the built attachments from their own materials: grey and still while the unit is dead, stamped with the unit's stencil
## value. The body decides whether the unit counts as stamped (effect_stencil_value), so these stamps never change it.
func _repaint_attachments() -> void:
	if _attachments == null:
		return
	var body_stamped := _stamped
	for mesh in _attachments.find_children("*", "MeshInstance3D", true, false):
		var own := mesh.get_meta(STYLE_PAINT) as StandardMaterial3D
		if own == null:
			continue
		var paint := own
		if is_dead:
			paint = own.duplicate() as StandardMaterial3D
			paint.albedo_color = Color(0.35, 0.35, 0.35)
			paint.emission_enabled = false
		(mesh as MeshInstance3D).material_override = mark_stencil(paint)
	_stamped = body_stamped
	set_process(not _moving.is_empty() and not is_dead)


func _process(delta: float) -> void:
	_style_clock += delta
	for entry in _moving:
		var attachment: UnitAttachment = entry[0]
		for pivot in entry[1]:
			(pivot[0] as Node3D).transform = attachment.animate(pivot[1], _style_clock)


func setup(title: String, color: Color) -> void:
	display_color = color
	set_stats(title)
	_paint()


func set_stats(text: String) -> void:
	if label != null:
		label.text = text


## Instant pose (building a room or a battle): lying down or standing, no animation.
func set_dead(dead: bool) -> void:
	is_dead = dead
	_pending_death = false
	_paint()
	_repaint_attachments()  # spec cube-style: grey and still while dead
	_start(&"dead" if dead else &"idle")


## The unit died: `death`, then `dead`. Waits for a cast that is still playing.
func die() -> void:
	is_dead = true
	_paint()
	_repaint_attachments()
	if _gate != null or bool(tree.get("parameters/montage/active")):
		_pending_death = true
	else:
		_start(&"death")


func revive() -> void:
	is_dead = false
	_pending_death = false
	_paint()
	_repaint_attachments()
	_start(&"revive")


func celebrate() -> void:
	if not is_dead:
		_start(&"victory")


## Additive flinch on top of whatever plays (idle or a cast). `blocked` uses the `block` slot when the set has one.
func flinch(blocked: bool = false) -> void:
	var animation: Animation = animation_set.animation_for(&"block") if blocked and animation_set != null else null
	if animation == null and animation_set != null:
		animation = animation_set.animation_for(&"hit")
	if animation == null:
		return
	_swap(&"react", animation)
	tree.set("parameters/react/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


## Plays the ability's animation as the montage. Its `execute` keys call execute(); its end (or the safety timer)
## releases the rest of the gate.
func play(ability: BattleAbility, gate: ClientGate) -> void:
	var animation := ability.animation
	if animation == null:
		gate.release_finished()
		return
	_gate = gate
	_cast_id += 1
	_montage_live = false
	var montage := _montage_for(animation)
	_swap(&"montage", montage)
	tree.set("parameters/montage/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	var cast_id := _cast_id
	var view: WeakRef = weakref(self)
	get_tree().create_timer(montage.length + SAFETY_SECONDS).timeout.connect(func() -> void:
		var animator: UnitAnimator = view.get_ref()
		if animator != null and animator._cast_id == cast_id:
			animator._finish_montage())


## Plays one slot as the game would (`hit` / `block` as flinches, the rest as states). For previews and `anim`.
func play_slot(slot: StringName) -> bool:
	if slot == &"hit" or slot == &"block":
		flinch(slot == &"block")
		return true
	if slot in STATES:
		_start(slot)
		return true
	return false


## Called by an ability animation's `execute` keys (method track on the view root).
func execute(row_id: StringName) -> void:
	if _gate != null:
		_gate.release_execution(row_id)


## Override to recolour the model (the demo cube greys out when dead). Pass each material through mark_stencil().
func _paint() -> void:
	pass


## Spec vfx-stencil 3.2: a copy of `material` set to stamp this unit's stencil value where it is drawn, so an effect on this unit can
## draw over exactly these pixels. A copy, so a material shared by several views (an imported model's) never carries another
## view's value. A BaseMaterial3D drawn in the opaque pass (opaque, alpha scissor, alpha hash) gets Custom / Write / Always / the
## value and nothing else (it stays opaque: the probe's K1). Returned untouched, and the view counts as not stamped (its effects
## use the plain depth test, see effect_stencil_value):
## - a blending material (alpha, depth pre-pass): it draws with the effects, so its stamp could land after they tested;
## - any other material (a ShaderMaterial; step 2 adds the unit include), with one warning.
## Value 0 returns the material untouched.
func mark_stencil(material: Material) -> Material:
	if not StencilIds.is_unit(stencil_value):
		return material
	var base := material as BaseMaterial3D
	if base == null or base.transparency in [BaseMaterial3D.TRANSPARENCY_ALPHA, BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS]:
		_stamped = false
		if base == null and material != null and not _warned_unstamped:
			_warned_unstamped = true
			push_warning("stencil: view '%s' has a %s, which takes no stamp; its effects use the plain depth test" % [unit_id, material.get_class()])
		return material
	var stamped := base.duplicate() as BaseMaterial3D
	stamped.stencil_mode = BaseMaterial3D.STENCIL_MODE_CUSTOM
	stamped.stencil_flags = BaseMaterial3D.STENCIL_FLAG_WRITE
	stamped.stencil_compare = BaseMaterial3D.STENCIL_COMPARE_ALWAYS
	stamped.stencil_reference = stencil_value
	_stamped = true
	return stamped


## Spec vfx-stencil 3.3: the value effects on this unit draw with: its stencil value while its materials carry the stamp, else 0
## (an effect on an unstamped unit draws once with the plain depth test, not over a stamp that is not there).
func effect_stencil_value() -> int:
	return stencil_value if _stamped else StencilIds.NONE


## Spec vfx-stencil 3.1: takes the stencil value of this view's battle position from its unit_id (0 with stencil off). The room view
## calls it after setting unit_id.
func assign_stencil() -> void:
	var value := StencilIds.for_unit_id(unit_id) if FxStencilShaders.enabled() else StencilIds.NONE
	if value == StencilIds.NONE and FxStencilShaders.enabled() and unit_id != &"":
		push_warning("stencil: no value for unit '%s' (position outside the table); its effects use the plain depth test" % unit_id)
	stencil_value = value


## True when the animation moves the model (transform or visibility tracks), not only keys and sounds.
static func moves_model(animation: Animation) -> bool:
	for track in animation.get_track_count():
		match animation.track_get_type(track):
			Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D, Animation.TYPE_BLEND_SHAPE:
				return true
			Animation.TYPE_VALUE, Animation.TYPE_BEZIER:
				var property := String(animation.track_get_path(track).get_concatenated_subnames()).get_slice(":", 0)
				if property in MODEL_PROPERTIES:
					return true
	return false


static func shared_tree() -> AnimationNodeBlendTree:
	if _shared_tree == null:
		_shared_tree = build_tree()
	return _shared_tree


static func build_tree() -> AnimationNodeBlendTree:
	var machine := AnimationNodeStateMachine.new()
	for state in STATES:
		var node := AnimationNodeAnimation.new()
		node.animation = StringName("set/" + state)
		machine.add_node(state, node)
	machine.add_transition(&"Start", &"idle", _auto_transition(false))
	for pair in [[&"death", &"dead"], [&"revive", &"idle"], [&"victory", &"idle"], [&"cast", &"idle"]]:
		machine.add_transition(pair[0], pair[1], _auto_transition(true))
	var blend := AnimationNodeBlendTree.new()
	blend.add_node(&"state", machine)
	var montage_anim := AnimationNodeAnimation.new()
	montage_anim.animation = MONTAGE
	blend.add_node(&"montage_anim", montage_anim)
	var montage := AnimationNodeOneShot.new()
	montage.fadein_time = MONTAGE_FADE
	montage.fadeout_time = MONTAGE_FADE
	blend.add_node(&"montage", montage)
	var neutral := AnimationNodeAnimation.new()
	neutral.animation = &"react/neutral"
	blend.add_node(&"neutral", neutral)
	var react_anim := AnimationNodeAnimation.new()
	react_anim.animation = &"react/current"
	blend.add_node(&"react_anim", react_anim)
	blend.add_node(&"react", AnimationNodeOneShot.new())
	blend.add_node(&"flinch", AnimationNodeAdd2.new())
	blend.connect_node(&"montage", 0, &"state")
	blend.connect_node(&"montage", 1, &"montage_anim")
	blend.connect_node(&"react", 0, &"neutral")
	blend.connect_node(&"react", 1, &"react_anim")
	blend.connect_node(&"flinch", 0, &"montage")
	blend.connect_node(&"flinch", 1, &"react")
	blend.connect_node(&"output", 0, &"flinch")
	return blend


static func _auto_transition(at_end: bool) -> AnimationNodeStateMachineTransition:
	var transition := AnimationNodeStateMachineTransition.new()
	transition.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	if at_end:
		transition.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	return transition


## Every slot (empty ones as short silent animations, so the tree always has something to play), plus the
## per-unit montage and reaction slots.
func _add_libraries() -> void:
	var slots := AnimationLibrary.new()
	for slot in UnitAnimationSet.SLOTS:
		var animation: Animation = animation_set.animation_for(slot) if animation_set != null else null
		slots.add_animation(slot, animation if animation != null else _silent(slot in UnitAnimationSet.LOOPING))
	tree.add_animation_library(&"set", slots)
	var montage := AnimationLibrary.new()
	montage.add_animation(&"current", _silent(false))
	tree.add_animation_library(&"montage", montage)
	var react := AnimationLibrary.new()
	react.add_animation(&"neutral", _silent(true))
	react.add_animation(&"current", _silent(false))
	tree.add_animation_library(&"react", react)
	var rest := AnimationLibrary.new()
	rest.add_animation(&"RESET", Animation.new())
	tree.add_animation_library(&"", rest)
	for slot in UnitAnimationSet.SLOTS:
		_record_rest(slots.get_animation(slot))


static func _silent(looping: bool) -> Animation:
	var animation := Animation.new()
	animation.length = 0.1
	if looping:
		animation.loop_mode = Animation.LOOP_LINEAR
	return animation


func _swap(library_name: StringName, animation: Animation) -> void:
	_record_rest(animation)
	var library := tree.get_animation_library(library_name)
	library.remove_animation(&"current")
	library.add_animation(&"current", animation)


## Godot's deterministic blending adds every track onto its RESET value, or zero without one: a scale or `visible`
## track would drop to 0 / false whenever nothing plays it (after a flinch, after a flash ability). So every value
## track a slot or an ability animates gets a RESET key with the property's rest value. A property is recorded the
## first time any animation uses it, before the tree has ever moved it, so its current value is the rest value.
func _record_rest(animation: Animation) -> void:
	var library := tree.get_animation_library(&"")
	var reset := library.get_animation(&"RESET")
	var added := false
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_VALUE:
			continue
		var path := animation.track_get_path(track)
		if reset.find_track(path, Animation.TYPE_VALUE) != -1:
			continue
		var node := get_node_or_null(NodePath(path.get_concatenated_names()))
		if node == null:
			continue
		var copy := reset.add_track(Animation.TYPE_VALUE)
		reset.track_set_path(copy, path)
		reset.track_insert_key(copy, 0.0, node.get_indexed(NodePath(path.get_concatenated_subnames())))
		added = true
	if added:  # re-adding the animation makes the mixer rebuild its track cache
		library.remove_animation(&"RESET")
		library.add_animation(&"RESET", reset)


## The ability's animation, or (when it doesn't move the model) a copy with the set's `cast` tracks merged in. A
## keys-only animation would otherwise hide the pose underneath for its whole length.
func _montage_for(animation: Animation) -> Animation:
	var cast: Animation = animation_set.animation_for(&"cast") if animation_set != null else null
	if cast == null or moves_model(animation):
		return animation
	var key := "%d:%d" % [animation.get_instance_id(), cast.get_instance_id()]
	if not _merged.has(key):
		var merged: Animation = animation.duplicate()
		for track in cast.get_track_count():
			var copy := merged.add_track(cast.track_get_type(track))
			merged.track_set_path(copy, cast.track_get_path(track))
			merged.track_set_interpolation_type(copy, cast.track_get_interpolation_type(track))
			for index in cast.track_get_key_count(track):
				merged.track_insert_key(copy, cast.track_get_key_time(track, index),
					cast.track_get_key_value(track, index), cast.track_get_key_transition(track, index))
		merged.length = maxf(animation.length, cast.length)
		_merged[key] = merged
	return _merged[key]


func _on_animation_finished(animation_name: StringName) -> void:
	if animation_name == MONTAGE:
		_finish_montage()


## The OneShot's `active` drops when the montage ends (with a fade-out the animation itself may never report
## finished), so the end is read here after every tree update.
func _on_mixer_applied() -> void:
	if _gate == null:
		return
	if bool(tree.get("parameters/montage/active")):
		_montage_live = true
	elif _montage_live:
		_finish_montage()


func _finish_montage() -> void:
	_montage_live = false
	if _gate != null:
		var gate := _gate
		_gate = null
		gate.release_finished()
	if _pending_death:
		_pending_death = false
		_start(&"death")


func _start(state: StringName) -> void:
	var playback: AnimationNodeStateMachinePlayback = tree.get("parameters/state/playback")
	if playback != null:
		playback.start(state)
