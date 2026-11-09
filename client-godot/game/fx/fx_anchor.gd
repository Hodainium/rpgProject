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


static func node3d(target: Node3D, shift: Vector3 = Vector3.ZERO) -> FxAnchor:
	var anchor := FxAnchor.new()
	anchor.kind = Kind.NODE3D
	anchor.node = target
	anchor.offset = shift
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
static func unit(id: StringName, shift: Vector3 = Vector3.ZERO) -> FxAnchor:
	var anchor := FxAnchor.new()
	anchor.kind = Kind.UNIT
	anchor.unit_id = id
	anchor.offset = shift
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
				return target.global_position + target.global_transform.basis * offset
			if kind == Kind.STAGE and target == null:
				return offset
	return null


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
