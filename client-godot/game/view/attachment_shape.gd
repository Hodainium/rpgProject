## Spec cube-style 3.3: an object a cube can wear (a crown, wings, a hat) as a list of primitives. Data, edited in the inspector;
## build() makes the nodes, AttachmentMesh caches the meshes. Presentation only.
class_name AttachmentShape
extends Resource

@export var display_name: String = ""
@export var parts: Array[AttachmentPart] = []


## The shape's nodes: one MeshInstance3D per part (and per ring copy). `tint` (a Color or null) recolours tintable parts; `stamp`
## takes each material and returns the one to use (the unit's mark_stencil), or is empty.
func build(tint: Variant = null, stamp: Callable = Callable()) -> Node3D:
	var root := Node3D.new()
	root.name = display_name.validate_node_name() if display_name != "" else "Shape"
	for part in parts:
		if part == null or part.problem() != "":
			continue
		var mesh := AttachmentMesh.mesh_for(part)
		if mesh == null:
			continue
		var paint: Material = part.material(tint)
		if stamp.is_valid():
			paint = stamp.call(paint)
		for placed in part.transforms():
			var instance := MeshInstance3D.new()
			instance.mesh = mesh
			instance.material_override = paint
			instance.transform = placed
			root.add_child(instance)
	return root
