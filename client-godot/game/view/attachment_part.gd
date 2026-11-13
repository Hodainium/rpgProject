## Spec cube-style 3.3: one primitive of an AttachmentShape (a crown's band, one of its spikes, a gem). Data only: AttachmentMesh
## builds and caches its mesh on first use. Presentation only.
class_name AttachmentPart
extends Resource

enum Kind { BOX, CYLINDER, SPHERE, TORUS, PRISM, LATHE, TUBE, EXTRUDE }

@export var kind: Kind = Kind.BOX
## BOX / PRISM size; EXTRUDE's depth is size.z.
@export var size: Vector3 = Vector3(0.2, 0.2, 0.2)
## CYLINDER (0 on one end = a cone); SPHERE: radius_bottom; TORUS: radius_bottom inner, radius_top outer; TUBE: start and end radius.
@export var radius_bottom: float = 0.1
@export var radius_top: float = 0.1
@export var height: float = 0.2
## LATHE: the profile (x = radius, y = height), a closed outline; EXTRUDE: the outline in the XY plane.
@export var profile: PackedVector2Array = PackedVector2Array()
## TUBE: three control points (start, bend, end) of a quadratic curve.
@export var curve: PackedVector3Array = PackedVector3Array()
## Sides of round shapes, steps along a tube.
@export_range(3, 128) var segments: int = 24

@export var position: Vector3 = Vector3.ZERO
@export var rotation_degrees: Vector3 = Vector3.ZERO
@export var scale: Vector3 = Vector3.ONE
## Repeat the part this many times around Y at ring_radius (a crown's spikes); 0 or 1 = once, where it is.
@export_range(0, 64) var ring_count: int = 0
@export var ring_radius: float = 0.0

@export var color: Color = Color.WHITE
@export_range(0.0, 1.0) var metallic: float = 0.0
@export_range(0.0, 1.0) var roughness: float = 0.6
## Above 0: the part glows in its colour (and blooms with the mood's glow).
@export_range(0.0, 16.0) var emission: float = 0.0
## Whether a UnitAttachment's tint replaces this part's colour (a gem keeps its own).
@export var tintable: bool = true


## What decides the mesh (not placement or material): the cache key.
func mesh_key() -> String:
	return var_to_str([kind, size, radius_bottom, radius_top, height, profile, curve, segments])


## A problem that keeps the mesh from being built, or "" (the validator's style_part_invalid).
func problem() -> String:
	match kind:
		Kind.LATHE:
			if profile.size() < 2:
				return "a lathe needs a profile of at least 2 points"
		Kind.EXTRUDE:
			if profile.size() < 3:
				return "an extruded outline needs at least 3 points"
			if Geometry2D.triangulate_polygon(profile).is_empty():
				return "the outline crosses itself (it cannot be filled)"
		Kind.TUBE:
			if curve.size() != 3:
				return "a tube needs 3 curve points (start, bend, end)"
		Kind.TORUS:
			if radius_top <= radius_bottom:
				return "a torus needs radius_top (outer) above radius_bottom (inner)"
		Kind.CYLINDER:
			if height <= 0.0 or (radius_bottom <= 0.0 and radius_top <= 0.0):
				return "a cylinder needs a height and a radius"
		Kind.SPHERE:
			if radius_bottom <= 0.0:
				return "a sphere needs radius_bottom"
	return ""


## Its material, with `tint` replacing the colour when given and the part is tintable.
func material(tint: Variant = null) -> StandardMaterial3D:
	var paint := StandardMaterial3D.new()
	var base: Color = tint if tint != null and tintable else color
	paint.albedo_color = base
	paint.metallic = metallic
	paint.roughness = roughness
	if emission > 0.0:
		paint.emission_enabled = true
		paint.emission = base
		paint.emission_energy_multiplier = emission
	return paint


## Where each copy sits: one transform, or ring_count around Y.
func transforms() -> Array[Transform3D]:
	var basis := Basis.from_euler(rotation_degrees * PI / 180.0) * Basis.from_scale(scale)  # scale along the part's own axes, as Node3D does
	var placed: Array[Transform3D] = []
	if ring_count <= 1:
		placed.append(Transform3D(basis, position))
		return placed
	for i in ring_count:
		var angle := TAU * i / ring_count
		var around := Basis(Vector3.UP, -angle)
		placed.append(Transform3D(around * basis, position + Vector3(cos(angle), 0, sin(angle)) * ring_radius))
	return placed
