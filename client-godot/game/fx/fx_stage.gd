## A 3D stage inside a 2D screen (spec vfx-framework F7): what Hearthstone-style card screens are built on. A Control
## (put it in any screen) that holds a transparent SubViewport with its own 3D world, camera and light, and an `overlay`
## Control above it. Card and pack meshes live under `world_root`; an effect anchored with FxAnchor.on_stage puts its 3D
## layers in the world and its 2D layers in the overlay, following the 3D node's screen position (`project`).
## The meshes, flips and pack models are slice card-ui; this is the stage they stand on. Presentation only.
class_name FxStage
extends Control

var container: SubViewportContainer
var viewport: SubViewport
var world_root: Node3D
var camera: Camera3D
var light: DirectionalLight3D
var environment: WorldEnvironment
## 2D layers of stage effects go here, above the 3D picture, in the stage's own coordinates.
var overlay: Control


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container = SubViewportContainer.new()
	container.name = "Container"
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(container)
	viewport = SubViewport.new()
	viewport.name = "Viewport"
	viewport.transparent_bg = true
	viewport.own_world_3d = true
	viewport.msaa_3d = GraphicsSettings.msaa_of(GraphicsSettings.saved_aa())  # playtest-fixes B25: the player's anti-aliasing
	viewport.handle_input_locally = false
	viewport.size = Vector2i(1280, 720)
	container.add_child(viewport)
	world_root = Node3D.new()
	world_root.name = "World"
	viewport.add_child(world_root)
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 35.0
	camera.position = Vector3(0, 0, 7)
	viewport.add_child(camera)
	camera.current = true
	light = DirectionalLight3D.new()
	light.name = "Light"
	light.rotation_degrees = Vector3(-35, 20, 0)
	viewport.add_child(light)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.55, 0.62)
	env.ambient_light_energy = 0.6
	environment = WorldEnvironment.new()
	environment.environment = env
	environment.name = "Environment"
	viewport.add_child(environment)
	overlay = Control.new()
	overlay.name = "Overlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)


## A world position as a point in the stage's own coordinates (what a 2D layer follows).
func project(world_position: Vector3) -> Vector2:
	if camera == null or not camera.is_inside_tree():
		return size * 0.5
	var point := camera.unproject_position(world_position)
	var viewport_size := Vector2(viewport.size)
	if viewport_size.x > 0.0 and viewport_size.y > 0.0:
		point *= size / viewport_size
	return point


## Spec card-ui 3.3: render the 3D picture at the window's real pixels. The project stretches its canvas (`canvas_items`, 1920 x
## 1080), so on a 4K screen a stretched stage would render at half the resolution and be scaled up (blurry cards). On: the
## container stops stretching, the viewport takes the stage's size times the screen's scale, and the container is drawn scaled
## down by the same factor, one viewport pixel per screen pixel. Off (the default): the container stretches, as before.
func match_screen_pixels(on: bool = true) -> void:
	_screen_pixels = on
	container.stretch = not on
	if on:
		if not resized.is_connected(_fit_screen_pixels):
			resized.connect(_fit_screen_pixels)
		if is_inside_tree():
			_notification(NOTIFICATION_ENTER_TREE)
		_fit_screen_pixels()
	else:
		container.scale = Vector2.ONE
		container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## Screen pixels per stage unit (1 unless match_screen_pixels is on).
func pixel_ratio() -> float:
	if not _screen_pixels or not is_inside_tree():
		return 1.0
	return maxf(get_viewport().get_screen_transform().get_scale().x * get_global_transform().get_scale().x, 0.25)


## A point in the stage's own coordinates as a point in the viewport (what Camera3D.project_position takes).
func to_viewport(point: Vector2) -> Vector2:
	var viewport_size := Vector2(viewport.size)
	if size.x <= 0.0 or size.y <= 0.0:
		return point
	return point * viewport_size / size


var _screen_pixels: bool = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE and _screen_pixels:
		var window := get_tree().root
		if not window.size_changed.is_connected(_fit_screen_pixels):
			window.size_changed.connect(_fit_screen_pixels)   # a fullscreen switch keeps the canvas size, not the pixels
		_fit_screen_pixels.call_deferred()
	elif what == NOTIFICATION_EXIT_TREE and is_inside_tree():
		var window := get_tree().root
		if window.size_changed.is_connected(_fit_screen_pixels):
			window.size_changed.disconnect(_fit_screen_pixels)


func _fit_screen_pixels() -> void:
	if not _screen_pixels or size.x <= 0.0 or size.y <= 0.0:
		return
	var ratio := pixel_ratio()
	var pixels := Vector2i(maxi(1, roundi(size.x * ratio)), maxi(1, roundi(size.y * ratio)))
	container.set_anchors_preset(Control.PRESET_TOP_LEFT)
	container.position = Vector2.ZERO
	container.scale = Vector2.ONE / ratio
	container.size = Vector2(pixels)
	viewport.size = pixels


func is_behind_camera(world_position: Vector3) -> bool:
	return camera != null and camera.is_inside_tree() and camera.is_position_behind(world_position)
