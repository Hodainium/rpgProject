## Spec cube-style 3.6: shows a StageMood in a room view: one WorldEnvironment and a key, fill and rim light. With no mood it is
## today's room: no environment and one white light at (-60, 30, 0). Presentation only.
class_name StageRig
extends Node3D

## The mood shown (null = today's look).
var mood: StageMood
var world_environment: WorldEnvironment
var key: DirectionalLight3D
var fill: DirectionalLight3D
var rim: DirectionalLight3D
## False while the room view is hidden (the menus): the environment is detached so it never tints a menu.
var active: bool = true:
	set(value):
		active = value
		_apply_environment()


func _init() -> void:
	name = "StageRig"
	world_environment = WorldEnvironment.new()
	world_environment.name = "Environment"
	add_child(world_environment)
	key = _light("Key")
	fill = _light("Fill")
	rim = _light("Rim")
	apply(null)


## Shows `new_mood` (null = today's look).
func apply(new_mood: StageMood) -> void:
	mood = new_mood
	_apply_environment()
	if mood == null:
		MoodLight.new().apply_to(key)  # today's light
		key.visible = true
		fill.visible = false
		rim.visible = false
		return
	_set_light(key, mood.key_light)
	_set_light(fill, mood.fill_light)
	_set_light(rim, mood.rim_light)


func floor_material() -> Material:
	return mood.floor_material if mood != null else null


func wall_material() -> Material:
	return mood.wall_material if mood != null else null


func _apply_environment() -> void:
	if world_environment != null:
		world_environment.environment = mood.environment if mood != null and active else null


func _light(light_name: String) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.name = light_name
	add_child(light)
	return light


static func _set_light(light: DirectionalLight3D, data: MoodLight) -> void:
	light.visible = data != null
	if data != null:
		data.apply_to(light)
