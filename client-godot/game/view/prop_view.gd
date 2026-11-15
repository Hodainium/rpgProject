## Spec cube-style 6a Set K: one pickup on the floor drawn from a PropLook (a key, an armor icon) or a ChestLook (a chest in one of its
## three states): the shape on a turning, bobbing holder, a rarity outline, a looping effect while shown, and a name label. Its origin
## is on the floor's top. Presentation only: nothing here reads or changes the run.
class_name PropView
extends Node3D

## Effects on a prop are sized by this radius (FxAttach.radius reads it), not by the shape's bounds.
@export var fx_radius: float = 0.45

var colour: Color = Color.WHITE
var holder: Node3D
var lid_pivot: Node3D
var _spin: float = 0.0
var _bob_amount: float = 0.0
var _bob_speed: float = 0.0
var _rest: Vector3 = Vector3.ZERO
var _clock: float = 0.0
var _effect: FxDefinition
var _effect_params: Dictionary = {}
var _fx: FxHandle


## A floating pickup. `color` tints the shape's tintable parts and colours the outline and the effect (an armor piece's rarity);
## null = the shape's own colours and the look's outline_color.
static func pickup(look: PropLook, text: String, color: Variant = null) -> PropView:
	var view := PropView.new()
	view.name = "Prop"
	view.colour = color if color != null else look.outline_color
	view.holder = _holder(look.offset, look.rotation_degrees, look.scale)
	view.add_child(view.holder)
	if look.shape != null:
		var shape := look.shape.build(color)
		view.holder.get_child(0).add_child(shape)
		if look.outline > 0.0:
			outline(shape, view.colour, look.outline)
	view._spin = look.spin_speed
	view._bob_amount = look.bob_amount
	view._bob_speed = look.bob_speed
	view._rest = view.holder.position
	view._set_effect(look.effect, look.effect_params, color)
	view._label(text, look.label_height)
	return view


## A chest in `state` (ChestLook.State): the body, the lid closed or turned back on its hinge, what lies inside an open chest, and
## the reward's glow over a filled one.
static func chest(look: ChestLook, state: int, text: String) -> PropView:
	var view := PropView.new()
	view.name = "Chest"
	var tint: Variant = look.tint if look.use_tint else null
	view.holder = _holder(look.offset, look.rotation_degrees, look.scale)
	view.add_child(view.holder)
	var inner := view.holder.get_child(0)
	if look.body != null:
		inner.add_child(look.body.build(tint))
	view.lid_pivot = Node3D.new()
	view.lid_pivot.name = "Lid"
	view.lid_pivot.position = look.hinge
	view.lid_pivot.rotation_degrees.x = 0.0 if state == ChestLook.State.CLOSED else -look.open_degrees  # back, around the hinge
	inner.add_child(view.lid_pivot)
	if look.lid != null:
		view.lid_pivot.add_child(look.lid.build(tint))
	var inside: AttachmentShape = look.filled_inside if state == ChestLook.State.OPEN_FILLED else (
		look.empty_inside if state == ChestLook.State.OPEN_EMPTY else null)
	if inside != null:
		inner.add_child(inside.build(tint))
	view._rest = view.holder.position
	if state == ChestLook.State.OPEN_FILLED:
		view._set_effect(look.filled_effect, look.filled_params, null)
	view._label(text, look.label_height)
	return view


## Adds a silhouette outline to every mesh under `root`: an inverted hull (the part grown along its normals, front faces culled,
## unshaded) as each material's next pass. Props are not units, so no stencil stamp is needed.
static func outline(root: Node, color: Color, width: float) -> void:
	var hull := StandardMaterial3D.new()
	hull.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hull.cull_mode = BaseMaterial3D.CULL_FRONT
	hull.grow = true
	hull.grow_amount = width
	hull.albedo_color = color
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		var material := mesh_node.material_override as BaseMaterial3D
		if material != null:
			material.next_pass = hull  # each part's material is its own (AttachmentPart.material makes a new one)


## The holder that moves (spin, bob) and, inside it, the node that carries the look's own rotation and scale, so a spin always
## turns around the world's up.
static func _holder(offset: Vector3, rotation_deg: Vector3, scale_by: Vector3) -> Node3D:
	var moving := Node3D.new()
	moving.name = "Holder"
	moving.position = offset
	var posed := Node3D.new()
	posed.name = "Pose"
	posed.rotation_degrees = rotation_deg
	posed.scale = scale_by
	moving.add_child(posed)
	return moving


## The floor under the prop is its Base socket (a floating shape's bounds would put Base in the air).
func _init() -> void:
	var base := FxSocket.new()
	base.name = "Base"
	base.role = FxSocket.BASE
	base.position = Vector3(0, 0.03, 0)  # just above the floor, so a floor glow never cuts into it
	add_child(base)


func _label(text: String, height: float) -> void:
	if text == "":
		return
	var label := Label3D.new()
	label.name = "Label"
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, height, 0)
	add_child(label)


## `color` (the prop's own colour, or null) fills the effect's `color` parameter when the look's params leave it unset; with
## none, the effect keeps its own default.
func _set_effect(effect: FxDefinition, params: Dictionary, color: Variant) -> void:
	_effect = effect
	_effect_params = params.duplicate()
	if color != null and effect != null and not _effect_params.has("color") 			and effect.params.any(func(p: FxParam) -> bool: return p.name == &"color"):
		_effect_params["color"] = color


func _ready() -> void:
	visibility_changed.connect(_sync_effect)  # the room hides its props during a battle
	set_process(_spin != 0.0 or _bob_amount != 0.0)


func _process(delta: float) -> void:
	_clock += delta
	if holder == null:
		return
	holder.rotation.y = _clock * _spin * TAU
	holder.position = _rest + Vector3(0, sin(_clock * _bob_speed * TAU) * _bob_amount, 0)


func _enter_tree() -> void:
	if not FxManager.quality_changed.is_connected(_sync_effect):
		FxManager.quality_changed.connect(_sync_effect)
	_sync_effect.call_deferred()


func _exit_tree() -> void:
	if FxManager.quality_changed.is_connected(_sync_effect):
		FxManager.quality_changed.disconnect(_sync_effect)
	if _fx != null:
		_fx.stop(0.0)
		_fx = null


## The effect plays while the prop is in the tree, visible, and effects are on; a quality change resyncs it.
func _sync_effect(_tier: int = 0) -> void:
	var shown := _effect != null and is_inside_tree() and is_visible_in_tree() and FxManager.enabled and FxManager.quality != FxQuality.OFF
	if _fx != null and (not shown or not _fx.is_playing()):
		_fx.stop(0.2)
		_fx = null
	if shown and _fx == null:
		_fx = FxManager.play(_effect, FxAnchor.node3d(self), _effect_params)


## The effect that plays on this prop (for tests and the console), or null.
func effect() -> FxDefinition:
	return _effect


func effect_params() -> Dictionary:
	return _effect_params
