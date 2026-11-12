## The Stencil page (spec vfx-stencil 3.7) and probe part 2. The experiment's scene, built from the real pieces: the demo cube unit
## view (presentation/demo/unit_view.tscn) with its stencil stamp, the real FxManager, FxAnchor.unit and FxShaderQuadLayer.
##   godot --path client-godot res://game/dev/fx_stencil_stage.tscn                     (a window: B / S switch bias / stencil)
##   ... -- --compare <dir> [--frames 300]                                              (probe part 2: both modes, shots, report, quit)
## The scene: a back unit E1 with a glow on it and a front unit P1 standing 0.3 in front of it (the leak of playtest-fixes B14),
## a floor ring under P1, a unit E2 half behind a wall with a glow, and a big glow disc on E3 leaning into the floor. Dev only.
extends Node3D

const UNIT_VIEW := "res://presentation/demo/unit_view.tscn"
const GLOW_SHADER := "res://game/fx/shaders/glow_3d.gdshader"
const RING_SHADER := "res://game/fx/shaders/rune_circle.gdshader"
## Each unit: id, position, colour.
const UNITS := [
	[&"E1", Vector3(0.0, 0.0, 0.0), Color(0.85, 0.55, 0.25)],
	# 0.05 in front of E1 (cubes are 0.8; the bias is their radius, about 0.69): units close in formation, where the bias leaks
	# (playtest-fixes B14, "what stays"). Further back, the front cube's visible faces are already more than the bias closer to the
	# camera than E1's centre and no leak shows.
	[&"P1", Vector3(0.5, 0.0, 0.85), Color(0.25, 0.4, 0.9)],
	[&"E2", Vector3(-2.6, 0.0, 0.0), Color(0.4, 0.75, 0.4)],
	[&"E3", Vector3(2.9, 0.0, 0.0), Color(0.6, 0.6, 0.65)],
]
## Effects: id, unit, definition maker.
const PLAYS := [[&"stencil.glow", &"E1"], [&"stencil.glow", &"E2"], [&"stencil.ring", &"P1"], [&"stencil.disc", &"E3"]]
## Points read by the probe (world space) and what each shows.
const POINTS := {
	"own_unit_visible": Vector3(-0.3, 0.25, 0.5),  # the back cube's own visible face: glow wanted
	"behind_wall": Vector3(-2.75, 0.25, 1.11),  # the wall's face in front of E2: no glow wanted
	"ring_behind_front_unit": Vector3(0.5, -0.38, 0.5),  # the ring's back half, hidden by the front cube
	"disc_near_floor": Vector3(2.9, -0.42, 0.6),  # the big disc where it meets the floor: the fade band
	"shadow_on_floor": Vector3(-0.9, -0.5, -0.9),  # the floor in the back cube's shadow (H3)
}

var _views: Dictionary = {}  # unit id -> UnitAnimator
var _handles: Array[FxHandle] = []
var _camera: Camera3D
var _label: Label


func _ready() -> void:
	_build_world()
	_register_effects()
	var args := OS.get_cmdline_user_args()
	var at := args.find("--compare")
	if at >= 0 and at + 1 < args.size():
		var frames_at := args.find("--frames")
		var frames := int(args[frames_at + 1]) if frames_at >= 0 and frames_at + 1 < args.size() else 300
		var ok: bool = await _compare(args[at + 1], maxi(frames, 1))
		get_tree().quit(0 if ok else 1)
		return
	_label = Label.new()
	_label.position = Vector2(16, 16)
	add_child(_label)
	_set_mode(FxStencilShaders.BIAS)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	if key.keycode == KEY_B:
		_set_mode(FxStencilShaders.BIAS)
	elif key.keycode == KEY_S:
		_set_mode(FxStencilShaders.STENCIL)


func _set_mode(mode: StringName, play_effects: bool = true) -> void:
	for handle in _handles:
		FxManager.stop_handle(handle, 0.0)
	_handles.clear()
	FxStencilShaders.mode = mode
	for view in _views.values():
		(view as UnitAnimator).assign_stencil()
	if not play_effects:
		return
	for play in PLAYS:
		_handles.append(FxManager.play(play[0], FxAnchor.unit(play[1])))
	if _label != null:
		_label.text = "mode: %s   (B bias, S stencil)   copies made: %d" % [mode, FxStencilShaders.made]


# --- Probe part 2 ------------------------------------------------------------------------------------------------------

## Returns false when the report could not be written.
func _compare(out_dir: String, frames: int) -> bool:
	DirAccess.make_dir_recursive_absolute(out_dir)
	var viewport_rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	var report := {"engine": {"version": Engine.get_version_info()["string"], "driver": RenderingServer.get_current_rendering_driver_name(),
		"method": RenderingServer.get_current_rendering_method(), "adapter": RenderingServer.get_video_adapter_name()},
		"frames": frames, "modes": {}}
	for view in _views.values():
		if (view as UnitAnimator).label != null:
			(view as UnitAnimator).label.visible = false  # labels sit over the glows; they would read as leaks
		# The idle animation bobs the cubes: frozen, so every frame catches each unit in the same place (else edges read as leaks).
		(view as UnitAnimator).tree.active = false
	# P1's pixels (H1): everything else hidden, against the clear colour.
	for handle in _handles:
		FxManager.stop_handle(handle, 0.0)
	var hidden: Array[Node3D] = []
	for child in get_children():
		if child is MeshInstance3D or (child is UnitAnimator and child != _views[&"P1"]):
			hidden.append(child)
			child.visible = false
	await _settle(10)
	var mask_image := get_viewport().get_texture().get_image()
	for node in hidden:
		node.visible = true
	var front_pixels := _front_unit_pixels(mask_image)
	# Baseline: the scene with no effect, so a point's change is the effect's own light.
	await _settle(20)
	var baseline := get_viewport().get_texture().get_image()
	baseline.save_png(out_dir.path_join("none.png"))
	var shots: Array[Image] = [baseline]
	_save_crop(baseline, out_dir.path_join("crop_none.png"))
	# H3 / H6: the same frame with the units stamped (stencil mode, no effect). Shadows, SSAO and shading must not change.
	_set_mode(FxStencilShaders.STENCIL, false)
	await _settle(20)
	var stamped := get_viewport().get_texture().get_image()
	stamped.save_png(out_dir.path_join("none_stamped.png"))
	report["stamped_units_change"] = {"mean_pixel_change": snappedf(_mean_change(baseline, stamped), 0.0001),
		"shadow_point_change": snappedf(_change(baseline, stamped, POINTS["shadow_on_floor"]), 0.001)}
	for mode in [FxStencilShaders.BIAS, FxStencilShaders.STENCIL]:
		var made_before := FxStencilShaders.made
		var switch_started := Time.get_ticks_usec()
		_set_mode(mode)
		var first_frames: Array[float] = []
		for i in 10:
			var tick := Time.get_ticks_usec()
			await get_tree().process_frame
			first_frames.append((Time.get_ticks_usec() - tick) / 1000.0)
		await _settle(20)
		var image := get_viewport().get_texture().get_image()
		image.save_png(out_dir.path_join("%s.png" % mode))
		_save_crop(image, out_dir.path_join("crop_%s.png" % mode))
		shots.append(image)
		# Stability (H5): the own-unit point over 60 frames.
		var own_values: Array[String] = []
		for i in 60:
			await RenderingServer.frame_post_draw
			if i % 10 == 0:
				own_values.append(str(_pixel(get_viewport().get_texture().get_image(), POINTS["own_unit_visible"])))
		var gpu := 0.0
		var cpu := 0.0
		for i in frames:
			await RenderingServer.frame_post_draw
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
			cpu += RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		var points := {}
		for key in POINTS:
			var with_fx := _pixel(image, POINTS[key])
			var without := _pixel(baseline, POINTS[key])
			points[key] = {"rgb": [snappedf(with_fx.r, 0.01), snappedf(with_fx.g, 0.01), snappedf(with_fx.b, 0.01)],
				"change": snappedf(Vector3(with_fx.r - without.r, with_fx.g - without.g, with_fx.b - without.b).length(), 0.001)}
		# H1: glow light on the front cube's own pixels (it stands in front of the glowing E1), against the same mode with no effect
		# (stamped units for stencil), so only the effect's light counts.
		var reference: Image = stamped if mode == FxStencilShaders.STENCIL else baseline
		var leaked := 0
		var leak_max := 0.0
		var marked := image.duplicate() as Image
		for at in front_pixels:
			var a := reference.get_pixelv(at)
			var b := image.get_pixelv(at)
			var change := Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()
			leak_max = maxf(leak_max, change)
			if change > 0.08:
				leaked += 1
				marked.set_pixelv(at, Color(0, 1, 0))
		_save_crop(marked, out_dir.path_join("lit_%s.png" % mode))
		report["modes"][mode] = {
			"points": points,
			"front_unit_pixels": front_pixels.size(),
			"front_unit_pixels_lit": leaked,
			"front_unit_max_change": snappedf(leak_max, 0.001),
			"gpu_ms": snappedf(gpu / frames, 0.001), "cpu_render_ms": snappedf(cpu / frames, 0.001),
			"first_frames_ms": first_frames.map(func(v: float) -> float: return snappedf(v, 0.1)),
			"switch_ms": snappedf((Time.get_ticks_usec() - switch_started) / 1000.0, 0.1),
			"copies_made": FxStencilShaders.made - made_before, "copies_build_ms": snappedf(FxStencilShaders.build_ms, 0.01),
			"own_point_stable": own_values.all(func(v: String) -> bool: return v == own_values[0]),
			"live_effects": _handles.size(),
		}
	_save_sheet(shots, out_dir.path_join("compare.png"))
	report["checks"] = _checks(report)
	var file := FileAccess.open(out_dir.path_join("report.json"), FileAccess.WRITE)
	if file == null:
		printerr("stencil compare: cannot write %s (%s)" % [out_dir, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("stencil compare: ", JSON.stringify(report["checks"]))
	return true


## The switch is a static: leaving the page puts it back to the default, so nothing after it runs in stencil mode by accident.
func _exit_tree() -> void:
	FxStencilShaders.mode = FxStencilShaders.BIAS


## H1 and friends as yes / no, from the points (a change above 0.05 is the effect's light).
func _checks(report: Dictionary) -> Dictionary:
	var bias: Dictionary = report["modes"][FxStencilShaders.BIAS]["points"]
	var stencil: Dictionary = report["modes"][FxStencilShaders.STENCIL]["points"]
	var lit := func(points: Dictionary, key: String) -> bool: return float(points[key]["change"]) > 0.05
	return {
		# Edge pixels where the front unit's own floor ring meets its base light up in both modes (a handful), so the leak is the
		# difference: removed when stencil lights under a tenth of what bias does.
		"H1_leak_in_bias": int(report["modes"][FxStencilShaders.BIAS]["front_unit_pixels_lit"]) > 50,
		"H1_leak_removed_in_stencil": int(report["modes"][FxStencilShaders.STENCIL]["front_unit_pixels_lit"]) * 10
			< int(report["modes"][FxStencilShaders.BIAS]["front_unit_pixels_lit"]),
		"H1_own_unit_lit_in_stencil": lit.call(stencil, "own_unit_visible"),
		"behind_wall_lit_in_stencil": lit.call(stencil, "behind_wall"),
		"ring_back_half_lit_in_stencil": lit.call(stencil, "ring_behind_front_unit"),
		"H3_H6_stamping_changes_nothing": float(report["stamped_units_change"]["mean_pixel_change"]) < 0.002,
		"H5_stable_in_stencil": report["modes"][FxStencilShaders.STENCIL]["own_point_stable"],
	}


## The pixels that are not the clear colour in a frame showing only the front unit.
func _front_unit_pixels(image: Image) -> Array[Vector2i]:
	var pixels: Array[Vector2i] = []
	var clear := Color(0.08, 0.08, 0.1)
	for y in range(0, image.get_height(), 2):
		for x in range(0, image.get_width(), 2):
			var c := image.get_pixel(x, y)
			if Vector3(c.r - clear.r, c.g - clear.g, c.b - clear.b).length() > 0.06:
				pixels.append(Vector2i(x, y))
	return pixels


func _change(before: Image, after: Image, world: Vector3) -> float:
	var a := _pixel(before, world)
	var b := _pixel(after, world)
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()


## The mean colour change over the whole frame (sampled every 4th pixel).
func _mean_change(before: Image, after: Image) -> float:
	var total := 0.0
	var count := 0
	for y in range(0, before.get_height(), 4):
		for x in range(0, before.get_width(), 4):
			var a := before.get_pixel(x, y)
			var b := after.get_pixel(x, y)
			total += Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()
			count += 1
	return total / maxf(count, 1)


## A 1.5x crop around the overlapping cubes (E1 behind P1), to judge the leak by eye.
func _save_crop(image: Image, path: String) -> void:
	var centre := Vector2i(_camera.unproject_position(Vector3(0.25, 0.1, 0.45)))
	var region := Rect2i(centre - Vector2i(260, 240), Vector2i(520, 480)).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var crop := image.get_region(region)
	crop.resize(int(region.size.x * 1.5), int(region.size.y * 1.5))
	crop.save_png(path)


func _settle(count: int) -> void:
	for i in count:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _pixel(image: Image, world: Vector3) -> Color:
	var at := _camera.unproject_position(world)
	return image.get_pixelv(Vector2i(clampi(int(at.x), 0, image.get_width() - 1), clampi(int(at.y), 0, image.get_height() - 1)))


func _save_sheet(images: Array[Image], path: String) -> void:
	var width := images[0].get_width() / 2
	var height := images[0].get_height() / 2
	var sheet := Image.create(width * images.size(), height, false, images[0].get_format())
	for index in images.size():
		var small := images[index].duplicate() as Image
		small.resize(width, height)
		sheet.blit_rect(small, Rect2i(Vector2i.ZERO, Vector2i(width, height)), Vector2i(index * width, 0))
	sheet.save_png(path)


# --- The scene ---------------------------------------------------------------------------------------------------------

func _build_world() -> void:
	_camera = Camera3D.new()
	_camera.position = Vector3(0, 4.2, 7.5)
	_camera.rotation_degrees = Vector3(-28, 0, 0)
	_camera.fov = 45.0
	add_child(_camera)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.08, 0.08, 0.1)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.35, 0.35, 0.4)
	environment.ssao_enabled = true  # H6: the stamped units must keep it
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, 35, 0)
	light.shadow_enabled = true
	add_child(light)
	_box(Vector3(14, 0.2, 9), Vector3(0, -0.6, 0), Color(0.3, 0.31, 0.36))  # the floor
	_box(Vector3(1.3, 2.2, 0.2), Vector3(-3.15, 0.4, 1.0), Color(0.5, 0.48, 0.45))  # the wall half in front of E2
	var scene := load(UNIT_VIEW) as PackedScene
	for unit in UNITS:
		var view := scene.instantiate() as UnitAnimator
		add_child(view)
		view.position = unit[1]
		view.setup(String(unit[0]), unit[2])
		view.unit_id = unit[0]
		_views[unit[0]] = view


func _box(size: Vector3, at: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	node.material_override = material
	add_child(node)


## Three effects made in code for the experiment (no files): a camera-facing glow bigger than a unit, a floor ring (a flat quad laid
## on the floor at the unit's base), and a big disc that leans into the floor. Each takes the unit's radius as its depth bias, the way
## the content's effects do.
func _register_effects() -> void:
	FxManager.register(_effect(&"stencil.glow", &"Center", _quad(load(GLOW_SHADER), Vector2(2.4, 2.4), true,
		{"color": Color(1.0, 0.2, 0.9), "intensity": 2.0, "falloff": 1.6, "fade_out": 0.0})))
	FxManager.register(_effect(&"stencil.ring", &"Base", _quad(load(RING_SHADER), Vector2(2.6, 2.6), false, {})))
	FxManager.register(_effect(&"stencil.disc", &"Center", _quad(load(GLOW_SHADER), Vector2(4.0, 4.0), true,
		{"color": Color(0.3, 0.9, 1.0), "intensity": 1.6, "falloff": 1.2, "fade_out": 0.0})))


func _effect(id: StringName, socket: StringName, layer: FxShaderQuadLayer) -> FxDefinition:
	var definition := FxDefinition.new()
	definition.id = id
	definition.socket = socket
	definition.space = FxDefinition.Space.WORLD_3D
	var bias := FxParam.new()
	bias.name = &"depth_bias"
	bias.kind = FxParam.Kind.FLOAT
	bias.default_value = 0.0
	definition.params = [bias]
	var binding := FxBinding.new()
	binding.property = "material:shader_parameter/depth_bias"
	binding.param = &"depth_bias"
	layer.bindings = [binding]
	if not layer.face_camera:
		# Laid flat on the floor, the way the content's rings are (a rotation_degrees:x binding).
		var tilt := FxParam.new()
		tilt.name = &"tilt"
		tilt.kind = FxParam.Kind.FLOAT
		tilt.default_value = -90.0
		tilt.min_value = -180.0
		tilt.max_value = 180.0
		definition.params.append(tilt)
		var lay := FxBinding.new()
		lay.property = "rotation_degrees:x"
		lay.param = &"tilt"
		layer.bindings.append(lay)
	definition.layers = [layer]
	return definition


func _quad(shader: Shader, size: Vector2, facing: bool, params: Dictionary) -> FxShaderQuadLayer:
	var layer := FxShaderQuadLayer.new()
	layer.id = &"quad"
	layer.space = FxLayer.Space.WORLD_3D
	layer.shader = shader
	layer.size = size
	layer.face_camera = facing
	layer.loop = true
	layer.shader_params = params
	return layer
