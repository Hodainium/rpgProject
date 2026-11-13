## Spec cube-style 3.3/3.5: builds an AttachmentPart's mesh and caches it by the part's mesh parameters (an edit makes a new mesh;
## equal parts share one). Engine primitive meshes for the simple kinds, SurfaceTool for the lathe, the tapering tube and the
## extruded outline (the generators the 2026-11-12 preview proved on 4.7.2). Triangles are wound clockwise from outside (Godot's
## front faces) and carry outward normals. Presentation only.
class_name AttachmentMesh
extends RefCounted

static var _cache: Dictionary = {}


static func mesh_for(part: AttachmentPart) -> Mesh:
	if part == null or part.problem() != "":
		return null
	var key := part.mesh_key()
	if not _cache.has(key):
		_cache[key] = _build(part)
	return _cache[key]


static func clear_cache() -> void:
	_cache.clear()


static func cache_size() -> int:
	return _cache.size()


static func _build(part: AttachmentPart) -> Mesh:
	match part.kind:
		AttachmentPart.Kind.BOX:
			var box := BoxMesh.new()
			box.size = part.size
			return box
		AttachmentPart.Kind.CYLINDER:
			var cylinder := CylinderMesh.new()
			cylinder.bottom_radius = part.radius_bottom
			cylinder.top_radius = part.radius_top
			cylinder.height = part.height
			cylinder.radial_segments = part.segments
			return cylinder
		AttachmentPart.Kind.SPHERE:
			var sphere := SphereMesh.new()
			sphere.radius = part.radius_bottom
			sphere.height = part.radius_bottom * 2.0
			sphere.radial_segments = part.segments
			sphere.rings = maxi(4, part.segments / 2)
			return sphere
		AttachmentPart.Kind.TORUS:
			var torus := TorusMesh.new()
			torus.inner_radius = part.radius_bottom
			torus.outer_radius = part.radius_top
			torus.rings = part.segments * 2
			torus.ring_segments = maxi(6, part.segments / 2)
			return torus
		AttachmentPart.Kind.PRISM:
			var prism := PrismMesh.new()
			prism.size = part.size
			return prism
		AttachmentPart.Kind.LATHE:
			return lathe(part.profile, part.segments)
		AttachmentPart.Kind.TUBE:
			return tube(bezier(part.curve[0], part.curve[1], part.curve[2], part.segments), part.radius_bottom, part.radius_top,
				maxi(6, part.segments / 2))
		AttachmentPart.Kind.EXTRUDE:
			return extrude(part.profile, part.size.z)
	return null


## Points along the quadratic curve p0 → p2 bent toward p1.
static func bezier(p0: Vector3, p1: Vector3, p2: Vector3, steps: int) -> PackedVector3Array:
	var points := PackedVector3Array()
	steps = maxi(2, steps)
	for i in steps + 1:
		var t := float(i) / steps
		points.append(p0.lerp(p1, t).lerp(p1.lerp(p2, t), t))
	return points


## Adds a triangle wound so its front faces `outward`, with per-vertex normals (or the flat outward one).
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, outward: Vector3, na := Vector3.ZERO, nb := Vector3.ZERO,
		nc := Vector3.ZERO) -> void:
	var flat := (b - a).cross(c - a)
	if flat.dot(outward) > 0.0:  # counter-clockwise from outside: swap to clockwise
		var t := b
		b = c
		c = t
		var tn := nb
		nb = nc
		nc = tn
	var n := flat.normalized()
	if n.dot(outward) < 0.0:
		n = -n
	for pair in [[a, na], [b, nb], [c, nc]]:
		st.set_normal(pair[1] if pair[1] != Vector3.ZERO else n)
		st.add_vertex(pair[0])


## The outward normal of the edge p → q of `outline` (by the outline's winding, so concave outlines such as a wing's scallops face
## out too). A two-point lathe profile (an open surface) faces away from the Y axis.
static func _edge_out(outline: PackedVector2Array, p: Vector2, q: Vector2) -> Vector2:
	var normal := Vector2(q.y - p.y, -(q.x - p.x))  # outward for a counter-clockwise outline (y up)
	if outline.size() < 3:
		return normal if normal.x >= 0.0 else -normal
	return -normal if Geometry2D.is_polygon_clockwise(outline) else normal


## A closed profile (x = radius, y = height) spun around Y.
static func lathe(profile: PackedVector2Array, sides: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := profile.size()
	for s in sides:
		var a0 := TAU * s / sides
		var a1 := TAU * (s + 1) / sides
		for i in count:
			var p := profile[i]
			var q := profile[(i + 1) % count]
			if count == 2 and i == 1:
				break  # two points: one surface, not a closed loop
			var p0 := Vector3(cos(a0) * p.x, p.y, sin(a0) * p.x)
			var p1 := Vector3(cos(a1) * p.x, p.y, sin(a1) * p.x)
			var q0 := Vector3(cos(a0) * q.x, q.y, sin(a0) * q.x)
			var q1 := Vector3(cos(a1) * q.x, q.y, sin(a1) * q.x)
			var edge_out := _edge_out(profile, p, q)
			var mid := (a0 + a1) * 0.5
			var out := Vector3(cos(mid) * edge_out.x, edge_out.y, sin(mid) * edge_out.x)
			_tri(st, p0, p1, q0, out)
			_tri(st, p1, q1, q0, out)
	return st.commit()


## A tube along `points` tapering from r0 to r1, smooth normals, its start capped.
static func tube(points: PackedVector3Array, r0: float, r1: float, sides: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: Array = []
	var n := points.size()
	# A frame carried along the curve (parallel transport): each ring's side vector is the previous one, turned by the change of
	# direction, so rings never twist against each other wherever the curve points.
	var side := Vector3.ZERO
	var previous_forward := Vector3.ZERO
	for i in n:
		var forward := (points[mini(i + 1, n - 1)] - points[maxi(i - 1, 0)]).normalized()
		if i == 0:
			var reference := Vector3.FORWARD if absf(forward.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
			side = forward.cross(reference).normalized()
		else:
			var axis := previous_forward.cross(forward)
			if axis.length() > 0.000001:
				side = side.rotated(axis.normalized(), previous_forward.angle_to(forward))
			side = (side - forward * side.dot(forward)).normalized()
		previous_forward = forward
		var up := side.cross(forward).normalized()
		var radius := lerpf(r0, r1, float(i) / (n - 1))
		var ring: Array = []
		for s in sides:
			var angle := TAU * s / sides
			var direction := side * cos(angle) + up * sin(angle)
			ring.append([points[i] + direction * radius, direction])
		rings.append(ring)
	for i in n - 1:
		for s in sides:
			var a: Array = rings[i][s]
			var b: Array = rings[i][(s + 1) % sides]
			var c: Array = rings[i + 1][s]
			var d: Array = rings[i + 1][(s + 1) % sides]
			var out: Vector3 = a[1] + b[1] + c[1] + d[1]
			_tri(st, a[0], b[0], c[0], out, a[1], b[1], c[1])
			_tri(st, b[0], d[0], c[0], out, b[1], d[1], c[1])
	var base_direction := (points[0] - points[1]).normalized()
	for s in sides:
		_tri(st, points[0], rings[0][s][0], rings[0][(s + 1) % sides][0], base_direction)
	return st.commit()


## An outline in the XY plane, `depth` thick along Z (centred), with its side walls.
static func extrude(outline: PackedVector2Array, depth: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := maxf(depth, 0.002) * 0.5
	var triangles := Geometry2D.triangulate_polygon(outline)
	for z in [half, -half]:
		for t in range(0, triangles.size(), 3):
			var a := outline[triangles[t]]
			var b := outline[triangles[t + 1]]
			var c := outline[triangles[t + 2]]
			_tri(st, Vector3(a.x, a.y, z), Vector3(b.x, b.y, z), Vector3(c.x, c.y, z), Vector3(0, 0, z))
	for i in outline.size():
		var p := outline[i]
		var q := outline[(i + 1) % outline.size()]
		var out2 := _edge_out(outline, p, q)
		var out := Vector3(out2.x, out2.y, 0)
		_tri(st, Vector3(p.x, p.y, half), Vector3(q.x, q.y, half), Vector3(p.x, p.y, -half), out)
		_tri(st, Vector3(q.x, q.y, half), Vector3(q.x, q.y, -half), Vector3(p.x, p.y, -half), out)
	return st.commit()
