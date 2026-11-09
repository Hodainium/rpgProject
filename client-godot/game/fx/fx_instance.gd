## The nodes of one playable copy of an FxDefinition (spec vfx-framework 2): a 2D holder and a 3D holder, with one
## child per layer, built once and kept in the pool. FxService attaches the holders where the anchor needs them. The
## layer resources stay stateless; everything per-play lives on these nodes.
class_name FxInstance
extends RefCounted

var definition: FxDefinition
var holder_ui: Control
var holder_3d: Node3D
## Layers whose node is neither a CanvasItem nor a Node3D (a shake, a tween, a sub-effect, a 2D sound) live here, under the
## service, so they outlive an anchor that is freed mid-play and can still give back what they changed.
var holder_state: Node
## One node per layer slot, in the definition's order (null for an empty slot).
var nodes: Array[Node] = []
## Per layer: FxLayer.Space.UI or WORLD_3D (where its node lives).
var spaces: PackedInt32Array = PackedInt32Array()


static func build(def: FxDefinition) -> FxInstance:
	var instance := FxInstance.new()
	instance.definition = def
	instance.holder_ui = Control.new()
	instance.holder_ui.name = "FxUI_%s" % def.id
	instance.holder_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	instance.holder_ui.focus_mode = Control.FOCUS_NONE
	instance.holder_3d = Node3D.new()
	instance.holder_3d.name = "Fx3D_%s" % def.id
	instance.holder_state = Node.new()
	instance.holder_state.name = "FxState_%s" % def.id
	for index in def.layers.size():
		var layer := def.layers[index]
		if layer == null:
			instance.nodes.append(null)
			instance.spaces.append(FxLayer.Space.UI)
			continue
		var node := layer.build()
		node.name = String(layer.id) if layer.id != &"" else "layer%d" % index
		var space := layer.resolved_space(int(def.space))
		var holder: Node = instance.holder_state
		if node is Node3D:
			holder = instance.holder_3d
		elif node is CanvasItem:
			holder = instance.holder_ui
		holder.add_child(node)
		FxLayer.set_node_visible(node, false)
		instance.nodes.append(node)
		instance.spaces.append(space)
	return instance


## True while every node is still alive (an anchor freed mid-play frees the holders it carried).
func is_intact() -> bool:
	if not is_instance_valid(holder_ui) or not is_instance_valid(holder_3d) or not is_instance_valid(holder_state):
		return false
	for node in nodes:
		if node != null and not is_instance_valid(node):
			return false
	return true


## The holder a layer's node sits in.
func holder_of(index: int) -> Node:
	var node := nodes[index]
	if node == null:
		return null
	return node.get_parent()


func uses_ui() -> bool:
	return _has_layers(holder_ui)


func uses_3d() -> bool:
	return _has_layers(holder_3d)


func detach() -> void:
	for holder in [holder_ui, holder_3d, holder_state]:
		if is_instance_valid(holder) and holder.get_parent() != null:
			holder.get_parent().remove_child(holder)


func free_nodes() -> void:
	detach()
	for holder in [holder_ui, holder_3d, holder_state]:
		if is_instance_valid(holder):
			holder.free()


func _has_layers(holder: Node) -> bool:
	return is_instance_valid(holder) and holder.get_child_count() > 0
