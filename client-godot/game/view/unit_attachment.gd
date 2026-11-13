## Spec cube-style 3.3: one AttachmentShape on a unit: its socket, placement, an optional mirrored copy, a tint and a simple motion.
## Listed in a UnitLook. Presentation only: the motion runs on the view's own clock.
class_name UnitAttachment
extends Resource

enum Motion { NONE, BOB, SPIN, FLAP }

const SOCKETS: Array[StringName] = [&"Center", &"Top", &"Base", &"Front", &"Back", &"Left", &"Right"]

@export var shape: AttachmentShape
## Center, Top, Base, Front (+Z, the face the camera sees), Back, Left, Right.
@export var socket: StringName = &"Top"
@export var offset: Vector3 = Vector3.ZERO
@export var rotation_degrees: Vector3 = Vector3.ZERO
@export var scale: Vector3 = Vector3.ONE
## Also a copy mirrored across the unit's middle (X): a pair of wings, two horns.
@export var mirror: bool = false
@export var use_tint: bool = false
@export var tint: Color = Color.WHITE
@export var motion: Motion = Motion.NONE
## Cycles a second (BOB, FLAP) or turns a second (SPIN).
@export var motion_speed: float = 1.0
## BOB: units up and down; FLAP: degrees each way; SPIN: unused.
@export var motion_amount: float = 0.05
## SPIN only: the axis it turns around in the attachment's own frame (after rotation_degrees; the scale stays outside the turn, so
## a stretched gear turns rigidly), so a gear stood on its side turns on its own axle. Zero (unset) = around the parent's up (Y),
## as before. Ignored by the other motions (the style check warns).
@export var spin_axis: Vector3 = Vector3.ZERO


## The attachment's nodes at `socket_position`: one pivot per copy (the mirrored one under a scale (-1, 1, 1) node), each holding the
## shape with its own materials (the view stamps and greys them afterwards). Returns the pivots that move (for animate) in `pivots`.
func build(socket_position: Vector3, pivots: Array) -> Node3D:
	var holder := Node3D.new()
	holder.name = "Attachment"
	if shape == null:
		return holder
	for copy in (2 if mirror else 1):
		var side := holder
		if copy == 1:
			side = Node3D.new()
			side.name = "Mirror"
			side.scale = Vector3(-1, 1, 1)
			holder.add_child(side)
		var pivot := Node3D.new()
		pivot.name = "Pivot"
		pivot.position = socket_position + offset
		pivot.rotation_degrees = rotation_degrees
		pivot.scale = scale
		pivot.add_child(shape.build(tint if use_tint else null))
		side.add_child(pivot)
		pivots.append([pivot, pivot.transform])
	return holder


## The pivot's transform `time` seconds into the motion, from its rest transform.
func animate(rest: Transform3D, time: float) -> Transform3D:
	var phase := sin(time * motion_speed * TAU)
	match motion:
		Motion.BOB:
			return Transform3D(rest.basis, rest.origin + Vector3(0, phase * motion_amount, 0))
		Motion.SPIN:
			var angle := time * motion_speed * TAU
			if spin_axis.is_zero_approx():
				return Transform3D(Basis(Vector3.UP, angle) * rest.basis, rest.origin)
			var turn := rest.basis.orthonormalized() * Basis(spin_axis.normalized(), angle)  # R * spin * S: no shear on a scale
			return Transform3D(turn * Basis.from_scale(rest.basis.get_scale()), rest.origin)
		Motion.FLAP:
			return Transform3D(rest.basis * Basis(Vector3.FORWARD, deg_to_rad(phase * motion_amount)), rest.origin)
	return rest
