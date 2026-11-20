## Spec card-ui 3.5: the portrait studio, where a character card's art is shot. A dark backdrop and a matte floor at the cube's
## feet, a warm key spot, a rim and a low glow in the character's colour, a soft fill, rising motes, its own Environment and a
## camera facing the cube's front. Presentation data the user tunes in presentation/demo/cards/portrait_studio.tscn; the
## portrait tool (game/tools/build_card_portraits.tscn) stands one character's real view at `Stand` and shoots it.
class_name PortraitStudio
extends Node3D

## Character id → its rim, glow and mote colour (the approved portrait shots of 2026-11-15); others use `default_rim`.
@export var rim_colors: Dictionary[StringName, Color] = {}
@export var default_rim: Color = Color(0.55, 0.65, 1.0)
## Where the camera and the key spot aim (the camera stays where the scene puts it, facing the cube's front).
@export var camera_target: Vector3 = Vector3(0, 0.12, 0)
@export var key_target: Vector3 = Vector3(0, 0.1, 0)


func _ready() -> void:
	$Camera.look_at(camera_target)
	$Key.look_at(key_target)
	var motes := get_node_or_null("Motes") as CPUParticles3D
	if motes != null and motes.mesh != null:
		motes.mesh = motes.mesh.duplicate(true)  # light_for recolours this copy, never the scene's resource


## Colours the rim lights, the glow and the motes for `character_id`.
func light_for(character_id: StringName) -> void:
	apply_color(rim_colors.get(character_id, default_rim))


## The colour `character_id` is lit in, or `fallback` when the studio has none for it (spec class-pick 2.2: the class's own
## display_color rather than the studio's default).
func rim_color(character_id: StringName, fallback: Color) -> Color:
	return rim_colors.get(character_id, fallback)


## Colours the rim lights, the glow and the motes (the class pick blends this colour from one class to the next).
func apply_color(rim: Color) -> void:
	for light_name in ["Rim", "Rim2", "Glow"]:
		var light := get_node_or_null(light_name) as Light3D
		if light != null:
			light.light_color = rim
	var motes := get_node_or_null("Motes") as CPUParticles3D
	if motes != null and motes.mesh is PrimitiveMesh and (motes.mesh as PrimitiveMesh).material is StandardMaterial3D:
		var material := (motes.mesh as PrimitiveMesh).material as StandardMaterial3D
		material.albedo_color = rim
		material.emission = rim


## Where the character stands (its centre; the floor is at the cube's feet).
func stand() -> Node3D:
	return $Stand


func camera() -> Camera3D:
	return $Camera
