## Animates the anchor itself (spec vfx-framework 3.1): its curve tracks write the ANCHOR's properties, not the layer's
## own node: a card's scale punch, a unit's modulate flash, a control's offset. The values the anchor had are put back
## when the layer ends. Targets: the anchor's Control, or its Node3D (a unit view, a card mesh). Screen and position
## anchors have nothing to tween. Define the motion with `tracks` (FxCurveTrack, mode MULTIPLY for a punch).
class_name FxTweenLayer
extends FxLayer

@export var seconds: float = 0.3


func kind() -> StringName:
	return &"tween"


func build() -> Node:
	return FxValueNode.new()


func track_target(node: Node) -> Object:
	var anchor: FxAnchor = FxLayer.meta_of(node, META_ANCHOR)
	if anchor == null:
		return null
	match anchor.kind:
		FxAnchor.Kind.CONTROL, FxAnchor.Kind.NODE3D, FxAnchor.Kind.UNIT:
			return anchor.node if is_instance_valid(anchor.node) else null
		FxAnchor.Kind.STAGE:
			return anchor.node if anchor.node != null and is_instance_valid(anchor.node) else null
	return null


func natural_length(_node: Node, _params: Dictionary) -> float:
	return seconds
