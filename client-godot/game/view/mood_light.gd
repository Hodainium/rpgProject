## Spec cube-style 3.6: one light of a StageMood's three-point rig (key, fill, rim). Presentation only.
class_name MoodLight
extends Resource

@export var color: Color = Color.WHITE
@export_range(0.0, 16.0) var energy: float = 1.0
## The light shines along its local -Z: (-60, 30, 0) is today's room light; a rim light faces the camera from behind the units.
@export var rotation_degrees: Vector3 = Vector3(-60, 30, 0)
@export var shadows: bool = false


func apply_to(light: DirectionalLight3D) -> void:
	light.light_color = color
	light.light_energy = energy
	light.rotation_degrees = rotation_degrees
	light.shadow_enabled = shadows
