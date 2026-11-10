## Flashes the anchor's own mesh (spec vfx-framework 3.1): an additive colour overlay on the first mesh under the
## anchor's 3D node (the battle unit's cube), faded by `curve` over the layer. The mesh's old overlay is put back.
## 3D anchors only. Bind `color` and `intensity`.
class_name FxMeshFlashLayer
extends FxLayer

@export var color: Color = Color.WHITE
@export var intensity: float = 1.0
## Over the layer's 0..1 time; none = a quick fade out.
@export var curve: Curve
@export var seconds: float = 0.25

const OVERLAY: StringName = &"fx_overlay"
const MESH: StringName = &"fx_mesh"
const STACK: StringName = &"fx_flash_stack"


func kind() -> StringName:
	return &"mesh_flash"


func native_space() -> int:
	return Space.WORLD_3D


func build() -> Node:
	return FxValueNode.new().declare({"color": color, "intensity": intensity})


func start(node: Node) -> void:
	super(node)
	var anchor: FxAnchor = node.get_meta(META_ANCHOR)
	var mesh := _first_mesh(anchor.world_node())
	if mesh == null:
		return
	var overlay := make_overlay()
	node.set_meta(MESH, weakref(mesh))
	node.set_meta(OVERLAY, overlay)
	# Flashes that overlap on one mesh share its original overlay: the first records it, the last puts it back, and the
	# newest flash shows while others run.
	var state: Dictionary = mesh.get_meta(STACK) if mesh.has_meta(STACK) else {"base": mesh.material_overlay, "active": []}
	state["active"].append(overlay)
	mesh.set_meta(STACK, state)
	mesh.material_overlay = overlay


func update(node: Node, local_time: float, length_seconds: float, params: Dictionary) -> void:
	var overlay: Material = FxLayer.meta_of(node, OVERLAY)
	if overlay != null:
		var u := progress(local_time, length_seconds)
		var strength: float = curve.sample_baked(u) if curve != null else 1.0 - u
		set_strength(overlay, node, strength)
	super(node, local_time, length_seconds, params)


func ended(node: Node) -> void:
	var reference: WeakRef = FxLayer.meta_of(node, MESH)
	var mesh: GeometryInstance3D = reference.get_ref() if reference != null else null
	var overlay: Material = FxLayer.meta_of(node, OVERLAY)
	if mesh != null and mesh.has_meta(STACK):
		var state: Dictionary = mesh.get_meta(STACK)
		state["active"].erase(overlay)
		if state["active"].is_empty():
			mesh.material_overlay = state["base"]
			mesh.remove_meta(STACK)
		else:
			mesh.material_overlay = state["active"].back()
	node.set_meta(MESH, null)
	node.set_meta(OVERLAY, null)
	super(node)


## The overlay material this kind puts on the mesh (a subclass, FxFresnelLayer, makes a rim-glow shader instead).
func make_overlay() -> Material:
	var overlay := StandardMaterial3D.new()
	overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	overlay.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return overlay


## Fades the overlay: `strength` is the curve's 0..1 value now; `node` carries the bound colour and intensity.
func set_strength(overlay: Material, node: Node, strength: float) -> void:
	var tint: Color = node.get(&"color")
	(overlay as StandardMaterial3D).albedo_color = Color(tint.r, tint.g, tint.b,
		clampf(tint.a * strength * float(node.get(&"intensity")), 0.0, 1.0))


func natural_length(_node: Node, _params: Dictionary) -> float:
	return seconds


## The first MeshInstance3D at or under `root`, breadth first.
static func _first_mesh(root: Node) -> GeometryInstance3D:
	if root == null:
		return null
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var current: Node = queue.pop_front()
		if current.name.begins_with("Fx3D_") or current is FxQuad3D:
			continue  # an effect's own holder and quads are not the unit's body
		if current is MeshInstance3D:
			return current
		queue.append_array(current.get_children())
	return null
