## Where on a unit's view an effect attaches, and how big the unit is (spec vfx-content-pass 3.6). Reads the view's explicit
## FxSocket markers, else derives the four roles from the bounding box of its first mesh; the radius is that box's
## bounding-sphere radius unless the view has an `fx_radius` above 0. Everything is in the view's local space.
## Presentation only.
class_name FxAttach
extends RefCounted


## The position of `role` in `view`'s local space: its FxSocket marker, else the box-derived point; ZERO when the view has no
## mesh and no marker (a plain node: the effect sits on its origin, as before sockets).
static func socket_position(view: Node3D, role: StringName) -> Vector3:
	var marker := _marker(view, role)
	if marker != null:
		return _relative(view, marker).origin
	var box := local_bounds(view)
	if box.size == Vector3.ZERO:
		return Vector3.ZERO
	var center := box.get_center()
	match role:
		FxSocket.TOP:
			return Vector3(center.x, box.end.y, center.z)
		FxSocket.BASE:
			return Vector3(center.x, box.position.y, center.z)
	return center  # Center and Hit


## The unit's radius in world units: `fx_radius` when the view sets one, else the bounding sphere of its mesh; 0 for a plain node.
static func radius(view: Node3D) -> float:
	if view == null:
		return 0.0
	if "fx_radius" in view and float(view.get("fx_radius")) > 0.0:
		return float(view.get("fx_radius"))
	return local_bounds(view).size.length() * 0.5


## The first mesh of the view's body, skipping effect holders and quads.
static func first_mesh(view: Node3D) -> MeshInstance3D:
	return FxMeshFlashLayer._first_mesh(view) as MeshInstance3D if view != null else null


## The first mesh's bounding box in `view`'s local space (zero-size when there is no mesh).
static func local_bounds(view: Node3D) -> AABB:
	var mesh := first_mesh(view)
	if mesh == null or mesh.mesh == null:
		return AABB()
	var into_view := view.global_transform.affine_inverse() * mesh.global_transform if view.is_inside_tree() and mesh.is_inside_tree() \
		else _relative(view, mesh)
	return into_view * mesh.mesh.get_aabb()


## The transform of `mesh` relative to `view` for nodes that are not in a tree (tests build views in memory).
static func _relative(view: Node3D, mesh: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = mesh
	while current != null and current != view:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


static func _marker(view: Node, role: StringName) -> FxSocket:
	for child in view.get_children():
		if child is FxSocket and child.role == role:
			return child
		if child is Node3D and not child.name.begins_with("Fx3D_"):
			var found := _marker(child, role)
			if found != null:
				return found
	return null
