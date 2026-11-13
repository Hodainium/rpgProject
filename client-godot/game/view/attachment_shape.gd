## Spec cube-style 3.3: an object a cube can wear (a crown, wings, a hat) as a list of primitives. Data, edited in the inspector;
## build() makes the nodes, AttachmentMesh caches the meshes. Presentation only.
class_name AttachmentShape
extends Resource

@export var display_name: String = ""
@export var parts: Array[AttachmentPart] = []


## The shape's nodes: one MeshInstance3D per part (and per ring copy). `tint` (a Color or null) recolours tintable parts. A part that
## cannot be built is left out (AttachmentMesh.mesh_for returns null; the validator reports it).
func build(tint: Variant = null) -> Node3D:
	var root := Node3D.new()
	root.name = display_name.validate_node_name() if display_name != "" else "Shape"
	for part in parts:
		var mesh := AttachmentMesh.mesh_for(part)
		if mesh == null:
			continue
		var paint: Material = part.material(tint)
		for placed in part.transforms():
			var instance := MeshInstance3D.new()
			instance.mesh = mesh
			instance.material_override = paint
			instance.transform = placed
			root.add_child(instance)
	return root
