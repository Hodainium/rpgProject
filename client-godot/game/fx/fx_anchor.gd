## Where an effect plays (spec vfx-framework 3.2). Built with the factories: node3d / position3d (the 3D world),
## control (a UI node), screen (the whole window), unit (a battle unit's view, by unit id) and stage (a 3D node inside
## a hybrid FxStage). An effect's 2D layers follow a 3D anchor by projecting it to the screen; its 3D layers go in the
## world (or the stage's world) when the anchor has one. Presentation only.
class_name FxAnchor
extends RefCounted

enum Kind { NODE3D, POSITION3D, CONTROL, SCREEN, UNIT, STAGE }

var kind: Kind = Kind.SCREEN
## The Node3D (NODE3D, UNIT once resolved, STAGE when the effect sits on a mesh) or the Control (CONTROL).
var node: Node
var position: Vector3 = Vector3.ZERO
var unit_id: StringName = &""
var stage: FxStage
## Shifts the effect's 3D holder from the anchor (local to the node, or in the world for POSITION3D).
var offset: Vector3 = Vector3.ZERO
## Spec vfx-content-pass 3.6: which socket role the effect attaches to (FxSocket.ROLES); empty = the effect's own default.
var socket: StringName = &""
## Set by FxService when it places the effect: where the socket is in the node's local space, and the unit's radius.
var socket_offset: Vector3 = Vector3.ZERO
var radius: float = 0.0
## Spec vfx-stencil 3.3: the stencil value of the unit the effect sits on (its view's effect_stencil_value()), set with the radius
## when the effect is placed; 0 = no unit, an unstamped unit or stencil off: one pass, the plain depth test.
var stencil_value: int = 0
## True when the caller set the value (the effect's `stencil_unit` parameter, a beam marking its caster): it is never re-read.
var stencil_forced: bool = false


static func node3d(target: Node3D, shift: Vector3 = Vector3.ZERO, socket_role: StringName = &"") -> FxAnchor:
	var anchor := FxAnchor.new()
	anchor.kind = Kind.NODE3D
	anchor.node = target
	anchor.offset = shift
	anchor.socket = socket_role
	return anchor


static func position3d(world_position: Vector3) -> FxAnchor:
	var anchor := FxAnchor.new()
	anchor.kind = Kind.POSITION3D
	anchor.position = world_position
	return anchor


static func control(target: Control) -> FxAnchor:
	var anchor := FxAnchor.new()
	anchor.kind = Kind.CONTROL
	anchor.node = target
	return anchor


static func screen() -> FxAnchor:
	return FxAnchor.new()


## A battle unit's view by its unit id ("P1", "E2"); the service finds the view (UnitAnimator.unit_id).
static func unit(id: StringName, shift: Vector3 = Vector3.ZERO, socket_role: StringName = &"") -> FxAnchor:
	var anchor := FxAnchor.new()
	anchor.kind = Kind.UNIT
	anchor.unit_id = id
	anchor.offset = shift
	anchor.socket = socket_role
	return anchor


## A hybrid screen's stage; with `target` the effect sits on that 3D node inside the stage, else on the stage itself.
static func on_stage(host: FxStage, target: Node3D = null, shift: Vector3 = Vector3.ZERO) -> FxAnchor:
	var anchor := FxAnchor.new()
	anchor.kind = Kind.STAGE
	anchor.stage = host
	anchor.node = target
	anchor.offset = shift
	return anchor


## Still usable: the node (if any) is alive and in the tree, the stage too.
func is_valid() -> bool:
	match kind:
		Kind.NODE3D, Kind.CONTROL, Kind.UNIT:
			return node != null and is_instance_valid(node) and node.is_inside_tree()
		Kind.STAGE:
			return stage != null and is_instance_valid(stage) and stage.is_inside_tree() \
				and (node == null or (is_instance_valid(node) and node.is_inside_tree()))
	return true


## The 3D node the effect's world layers hang on, or null (a position anchor, a control or the screen have none of
## their own).
func world_node() -> Node3D:
	match kind:
		Kind.NODE3D, Kind.UNIT, Kind.STAGE:
			return node as Node3D
	return null


## Where the anchor is in the world, for projecting 2D layers onto it. Null-safe: returns false when it has no place.
func world_position() -> Variant:
	match kind:
		Kind.POSITION3D:
			return position + offset
		Kind.NODE3D, Kind.UNIT, Kind.STAGE:
			var target := node as Node3D
			if target != null and is_instance_valid(target) and target.is_inside_tree():
				return target.global_position + target.global_transform.basis * (socket_offset + offset)
			if kind == Kind.STAGE and target == null:
				return offset
	return null


## A copy for one play with the socket placed (the caller's anchor is left alone, so it can be reused for another play).
func placed(default_socket: StringName) -> FxAnchor:
	var copy := FxAnchor.new()
	copy.kind = kind
	copy.node = node
	copy.position = position
	copy.unit_id = unit_id
	copy.stage = stage
	copy.offset = offset
	copy.socket = socket
	var target := world_node()
	if target != null and is_instance_valid(target):
		copy.socket_offset = FxAttach.socket_position(target, socket if socket != &"" else default_socket)
		copy.radius = FxAttach.radius(target)
		if stencil_forced:
			copy.stencil_value = stencil_value  # the caller's value (a sub-effect of a beam that marks its caster keeps it)
			copy.stencil_forced = true
		elif target is UnitAnimator and kind in [Kind.UNIT, Kind.NODE3D]:  # not a stage: its world is not stamped (spec 3.5)
			copy.stencil_value = (target as UnitAnimator).effect_stencil_value()
	return copy


## The value now: a unit view's current effect_stencil_value() (its stamp may have changed since the effect was placed), else the
## value set at placing (or by the caller).
func live_stencil_value() -> int:
	if not stencil_forced and kind in [Kind.UNIT, Kind.NODE3D] and is_instance_valid(node) and node is UnitAnimator:
		return (node as UnitAnimator).effect_stencil_value()
	return stencil_value


func describe() -> String:
	match kind:
		Kind.NODE3D:
			return "node3d %s" % (node.name if node != null else "<gone>")
		Kind.POSITION3D:
			return "position %s" % position
		Kind.CONTROL:
			return "control %s" % (node.name if node != null else "<gone>")
		Kind.UNIT:
			return "unit %s" % unit_id
		Kind.STAGE:
			return "stage%s" % (" " + node.name if node != null else "")
	return "screen"
