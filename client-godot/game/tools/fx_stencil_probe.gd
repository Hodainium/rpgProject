## Spec vfx-stencil 1.4 and 3.7, probe part 1: tests the documented stencil claims on the Godot build we run, before anything is
## built on them. Windowed (needs a GPU); every claim gets small scenes of its own in SubViewports, rendered, read back by pixel
## and logged. Writes findings.json and one PNG per scene into --out.
##   godot --path client-godot res://game/tools/fx_stencil_probe.tscn -- --out <dir>
## Claims (spec 1.4): K1 writers are drawn in the transparent pass, K2 opaque readers fail, K4 no shader or compositor reads stencil,
## K5 the reference is a literal in shader code, K6 no masks, K7 writes happen where the depth test passes (or fails).
## K3 (experimental) is not a runtime fact; the findings note checks it in the 4.7.2 source. Probe only: nothing ships it.
extends Node

const PASS_SCRIPT := preload("res://game/tools/fx_stencil_probe_pass.gd")
const CELL := Vector2i(240, 180)
const SETTLE_FRAMES := 24
const PALETTE := {
	"black": Color(0, 0, 0), "red": Color(1, 0, 0), "green": Color(0, 1, 0), "blue": Color(0, 0, 1),
	"magenta": Color(1, 0, 1), "grey": Color(0.5, 0.5, 0.5), "white": Color(1, 1, 1),
}


class ProbeLogger extends Logger:
	var _mutex := Mutex.new()
	var _lines: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var kind := "warning" if error_type == ERROR_TYPE_WARNING else ("shader" if error_type == ERROR_TYPE_SHADER else "error")
		_add("%s: %s (%s at %s:%d)" % [kind, rationale if rationale != "" else code, function, file.get_file(), line])

	func _log_message(message: String, error: bool) -> void:
		var text := message.strip_edges()
		if error or "SHADER" in text or "stencil" in text.to_lower():
			_add(text)

	func _add(text: String) -> void:
		_mutex.lock()
		if _lines.size() < 200:
			_lines.append(text)
		_mutex.unlock()

	func take() -> Array[String]:
		_mutex.lock()
		var taken := _lines.duplicate()
		_lines.clear()
		_mutex.unlock()
		return taken


var _out_dir := ""
var _logger := ProbeLogger.new()
var _findings: Dictionary = {}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--out")
	_out_dir = args[at + 1] if at >= 0 and at + 1 < args.size() else OS.get_user_data_dir().path_join("stencil_probe")
	DirAccess.make_dir_recursive_absolute(_out_dir)
	OS.add_logger(_logger)
	_findings["engine"] = {
		"version": Engine.get_version_info()["string"],
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"driver": RenderingServer.get_current_rendering_driver_name(),
		"adapter": RenderingServer.get_video_adapter_name(),
	}
	await _k1()
	await _k2()
	await _k4()
	await _k5()
	await _k6()
	await _k7()
	var file := FileAccess.open(_out_dir.path_join("findings.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(_findings, "\t"))
	file.close()
	print("stencil probe: findings in ", _out_dir)
	OS.remove_logger(_logger)
	get_tree().quit(0)


# --- K1: a stencil writer is drawn in the transparent pass ---------------------------------------------------------------
# The screen texture is copied after the opaque pass. A quad in front shows that copy: opaque objects appear in it, objects
# drawn in the transparent pass do not. Red: plain opaque cube. Green: the stencil writer. Blue: a plain transparent cube (control).
func _k1() -> void:
	var plain := _cell("k1_without_copy")
	_k1_scene(plain)
	var copied := _cell("k1_screen_copy")
	_k1_scene(copied)
	_quad(copied, Vector3(0, 0, 3), Vector2(8, 6), _shader("""
render_mode unshaded;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
void fragment() { ALBEDO = texture(screen_tex, SCREEN_UV).rgb; ALPHA = 1.0; }
""", 10))
	var a := await _render(plain)
	var b := await _render(copied)
	var points := {"opaque_red": Vector3(-1.6, 0, 0.5), "writer_green": Vector3(1.6, 0, 0.5), "transparent_blue": Vector3(0, 0, 0.5),
		"shader_writer_white": Vector3(0, -1.2, 0.4)}
	var seen_plain := _sample(plain, a, points)
	var seen_copy := _sample(copied, b, points)
	# Holds only if both kinds of writer (BaseMaterial3D and a ShaderMaterial with stencil_mode write) are missing from the copy.
	var holds: bool = seen_plain["writer_green"] == "green" and seen_copy["opaque_red"] == "red" \
		and seen_copy["transparent_blue"] == "black" and seen_copy["writer_green"] == "black" \
		and seen_copy["shader_writer_white"] == "black"
	_findings["K1"] = {"claim": "a stencil-writing material is drawn in the transparent pass",
		"without_copy": seen_plain, "in_screen_copy": seen_copy, "logs": plain["logs"] + copied["logs"],
		"verdict": "holds" if holds else "fails",
		"read": "writer missing from the post-opaque screen copy = transparent pass"}


func _k1_scene(cell: Dictionary) -> void:
	_box(cell, Vector3(-1.6, 0, 0), Vector3.ONE, _unshaded(Color.RED))
	_box(cell, Vector3(1.6, 0, 0), Vector3.ONE, _writer(Color.GREEN, 1))
	var see_through := _unshaded(Color.BLUE)
	see_through.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_box(cell, Vector3(0, 0, 0), Vector3.ONE, see_through)
	_box(cell, Vector3(0, -1.2, 0), Vector3(0.8, 0.8, 0.8), _shader("""
render_mode unshaded;
stencil_mode write, compare_always, 1;
void fragment() { ALBEDO = vec3(1.0); }
""", 0))


# --- K2: a stencil reader in the opaque pass fails -----------------------------------------------------------------------
func _k2() -> void:
	var cell := _cell("k2_opaque_reader")
	_quad(cell, Vector3(0, 0, 0), Vector2(4, 3), _writer(Color.GREEN, 1))
	_box(cell, Vector3(-0.9, 0, 1), Vector3(0.8, 0.8, 0.8), _shader("""
render_mode unshaded;
stencil_mode read, compare_equal, 1;
void fragment() { ALBEDO = vec3(1.0, 0.0, 1.0); }
""", 1))
	_box(cell, Vector3(0.9, 0, 1), Vector3(0.8, 0.8, 0.8), _shader("""
render_mode unshaded;
stencil_mode read, compare_equal, 1;
void fragment() { ALBEDO = vec3(1.0, 0.0, 1.0); ALPHA = 1.0; }
""", 1))
	var image := await _render(cell)
	var seen := _sample(cell, image, {"opaque_reader": Vector3(-0.9, 0, 1.4), "transparent_reader": Vector3(0.9, 0, 1.4)})
	var complained: bool = cell["logs"].any(func(line: String) -> bool: return "alpha queue" in line or "stencil" in line.to_lower())
	var verdict := "holds" if seen["transparent_reader"] == "magenta" and (seen["opaque_reader"] != "magenta" or complained) else "fails"
	if verdict == "holds" and seen["opaque_reader"] == "magenta":
		verdict = "partly: the opaque reader still drew as if it read; the engine complained"
	_findings["K2"] = {"claim": "stencil reads fail in the opaque pass", "seen": seen, "engine_complained": complained,
		"logs": cell["logs"], "verdict": verdict}


# --- K4: no shader samples stencil; a compositor cannot use the main stencil buffer ---------------------------------------
func _k4() -> void:
	var hint := _cell("k4_stencil_hint")
	_box(hint, Vector3.ZERO, Vector3(1.5, 1.5, 1.5), _shader("""
render_mode unshaded;
uniform usampler2D stencil_tex : hint_stencil_texture;
void fragment() { ALBEDO = vec3(1.0); }
""", 0))
	var hint_image := await _render(hint)
	var hint_seen := _sample(hint, hint_image, {"box": Vector3(0, 0, 0.75)})
	var results := {"claim": "no shader reads stencil values; a compositor cannot copy the main stencil buffer",
		"shader_hint": {"seen": hint_seen, "logs": hint["logs"],
			"compiled": hint_seen["box"] == "white"}}
	for kind in ["post_transparent", "post_opaque"]:
		var cell := _cell("k4_compositor_" + kind)
		_box(cell, Vector3.ZERO, Vector3(1.5, 1.5, 1.5), _writer(Color.GREEN, 1))
		var effect: CompositorEffect = PASS_SCRIPT.new()
		if kind == "post_opaque":
			effect.effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE
		var compositor := Compositor.new()
		compositor.compositor_effects = [effect]
		cell["cam"].compositor = compositor
		var image := await _render(cell)
		results[kind] = {"seen": _sample(cell, image, {"writer": Vector3(0, 0, 0.75), "background": Vector3(2.2, 1.2, 0)}),
			"pass": effect.get("report").duplicate(), "logs": cell["logs"]}
		cell["cam"].compositor = null
		effect.call("free_resources")
	# The docs' exact claim: the stencil copied into a custom texture. The pass draws magenta into a texture of its own where the
	# stencil test passes; the texture is read back from the GPU.
	var own := _cell("k4_compositor_own_texture")
	_box(own, Vector3.ZERO, Vector3(1.5, 1.5, 1.5), _writer(Color.GREEN, 1))
	var rd := RenderingServer.get_rendering_device()
	var texture_format := RDTextureFormat.new()
	texture_format.width = CELL.x
	texture_format.height = CELL.y
	texture_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var target := rd.texture_create(texture_format, RDTextureView.new())
	var own_effect: CompositorEffect = PASS_SCRIPT.new()
	own_effect.set("target", target)
	var own_compositor := Compositor.new()
	own_compositor.compositor_effects = [own_effect]
	own["cam"].compositor = own_compositor
	await _render(own)
	var mask := Image.create_from_data(CELL.x, CELL.y, false, Image.FORMAT_RGBA8, rd.texture_get_data(target, 0))
	mask.save_png(_out_dir.path_join("k4_own_texture_readback.png"))
	results["own_texture"] = {"seen": _sample(own, mask, {"writer": Vector3(0, 0, 0.75), "background": Vector3(2.2, 1.2, 0)}),
		"pass": own_effect.get("report").duplicate(), "logs": own["logs"]}
	own["cam"].compositor = null
	own_effect.call("free_resources")
	rd.free_rid(target)
	var copied: bool = results["own_texture"]["seen"]["writer"] == "magenta" and results["own_texture"]["seen"]["background"] == "black"
	results["compositor_can_stencil_test"] = results["post_transparent"]["seen"]["writer"] == "magenta"
	results["compositor_copies_into_own_texture"] = copied
	if results["shader_hint"]["compiled"]:
		results["verdict"] = "fails: a shader samples stencil"
	elif copied:
		results["verdict"] = "partly: no shader samples stencil, but a compositor copies the main stencil into a texture of its own"
	else:
		results["verdict"] = "holds"
	_findings["K4"] = results


# --- K5: the reference value in a shader -------------------------------------------------------------------------------------
# The writer stamps 7 through BaseMaterial3D.stencil_reference. Each reader draws magenta where its test passes.
func _k5() -> void:
	var variants := {
		"literal_7": "stencil_mode read, compare_equal, 7;",
		"literal_1_control": "stencil_mode read, compare_equal, 1;",
		"const_7": "const int REF = 7;\nstencil_mode read, compare_equal, REF;",
		"define_7": "#define REF 7\nstencil_mode read, compare_equal, REF;",
		"uniform_7": "uniform int REF = 7;\nstencil_mode read, compare_equal, REF;",
	}
	var results := {"claim": "in a shader the stencil reference is a literal in the code"}
	for key in variants:
		var cell := _cell("k5_" + key)
		_quad(cell, Vector3(0, 0, 0), Vector2(4, 3), _writer(Color.GREEN, 7))
		_quad(cell, Vector3(0, 0, 1), Vector2(2, 1.5), _shader("render_mode unshaded;\n%s\nvoid fragment() { ALBEDO = vec3(1.0, 0.0, 1.0); ALPHA = 1.0; }\n" % variants[key], 1))
		var image := await _render(cell)
		results[key] = {"seen": _sample(cell, image, {"reader": Vector3(0, 0, 1)})["reader"], "logs": cell["logs"]}
	# Where a shader copy's #define may go (spec 1.4.1, change 3): before shader_type, and reaching a stencil_mode inside an #include.
	var placements := {
		"define_before_shader_type": "#define FX_STENCIL_REF 7\nshader_type spatial;\nrender_mode unshaded;\nstencil_mode read, compare_equal, FX_STENCIL_REF;\n",
		"define_reaches_include": "shader_type spatial;\n#define FX_STENCIL_REF 7\nrender_mode unshaded;\n#include \"res://game/tools/fx_stencil_probe_ref.gdshaderinc\"\n",
	}
	for key in placements:
		var cell := _cell("k5_" + key)
		_quad(cell, Vector3(0, 0, 0), Vector2(4, 3), _writer(Color.GREEN, 7))
		var shader := Shader.new()
		shader.code = placements[key] + "void fragment() { ALBEDO = vec3(1.0, 0.0, 1.0); ALPHA = 1.0; }\n"
		var material := ShaderMaterial.new()
		material.shader = shader
		material.render_priority = 1
		_quad(cell, Vector3(0, 0, 1), Vector2(2, 1.5), material)
		var image := await _render(cell)
		results[key] = {"seen": _sample(cell, image, {"reader": Vector3(0, 0, 1)})["reader"], "logs": cell["logs"]}
	for owner in ["ShaderMaterial", "Shader", "Material", "VisualShader", "GeometryInstance3D", "BaseMaterial3D"]:
		results["properties_" + owner] = _stencil_properties(owner)
	var literal_ok: bool = results["literal_7"]["seen"] == "magenta" and results["literal_1_control"]["seen"] != "magenta"
	var others := ["const_7", "define_7", "uniform_7"].filter(func(k: String) -> bool: return results[k]["seen"] == "magenta")
	results["base_material_reference_used"] = literal_ok
	results["other_forms_accepted"] = others
	results["verdict"] = ("holds" if others.is_empty() else "partly: also accepted %s" % ", ".join(others)) if literal_ok else "fails"
	_findings["K5"] = results


# --- K6: no read or write masks --------------------------------------------------------------------------------------------
func _k6() -> void:
	var variants := {
		"second_integer": "stencil_mode read, compare_equal, 1, 255;",
		"read_mask_token": "stencil_mode read, compare_equal, read_mask, 1;",
		"write_mask_token": "stencil_mode write, compare_always, write_mask, 1;",
	}
	var results := {"claim": "no stencil read or write masks exist for materials"}
	for key in variants:
		var cell := _cell("k6_" + key)
		_quad(cell, Vector3(0, 0, 0), Vector2(4, 3), _writer(Color.GREEN, 1))
		_quad(cell, Vector3(0, 0, 1), Vector2(2, 1.5), _shader("render_mode unshaded;\n%s\nvoid fragment() { ALBEDO = vec3(1.0, 0.0, 1.0); ALPHA = 1.0; }\n" % variants[key], 1))
		var image := await _render(cell)
		results[key] = {"seen": _sample(cell, image, {"reader": Vector3(0, 0, 1)})["reader"], "logs": cell["logs"]}
	var mask_props := _stencil_properties("BaseMaterial3D").filter(func(p: String) -> bool: return "mask" in p)
	var accepted := variants.keys().filter(func(k: String) -> bool: return results[k]["seen"] == "magenta")
	results["mask_properties_on_base_material"] = mask_props
	# The parser accepts any identifier that begins with a mode name (shader_language.cpp _parse_shader_mode, begins_with), so
	# "read_mask" passes as "read": accepted is not a mask. Masks exist only if a property or a second number is taken.
	results["accepted_by_prefix_only"] = accepted
	results["verdict"] = "holds" if mask_props.is_empty() and results["second_integer"]["seen"] != "magenta" else "fails"
	_findings["K6"] = results


# --- K7: writes happen where the depth test passes (WRITE) or fails (WRITE_DEPTH_FAIL) -------------------------------------
# A writer cube, its right half behind an opaque grey wall. A reader quad in front, no depth test, magenta where the stamp is.
func _k7() -> void:
	var results := {"claim": "WRITE stamps where the depth test passes; WRITE_DEPTH_FAIL where it fails"}
	for flag in ["write", "write_depth_fail"]:
		var cell := _cell("k7_" + flag)
		var flags := BaseMaterial3D.STENCIL_FLAG_WRITE if flag == "write" else BaseMaterial3D.STENCIL_FLAG_WRITE_DEPTH_FAIL
		_box(cell, Vector3.ZERO, Vector3(2, 2, 2), _writer(Color.GREEN, 1, flags))
		_quad(cell, Vector3(2, 0, 1.5), Vector2(4, 4), _unshaded(Color(0.5, 0.5, 0.5)))
		_quad(cell, Vector3(0, 0, 3), Vector2(8, 6), _shader("""
render_mode unshaded, depth_test_disabled;
stencil_mode read, compare_equal, 1;
void fragment() { ALBEDO = vec3(1.0, 0.0, 1.0); ALPHA = 1.0; }
""", 10))
		var image := await _render(cell)
		results[flag] = {"seen": _sample(cell, image, {"visible_half": Vector3(-0.5, 0, 1), "hidden_half": Vector3(0.5, 0, 1)}),
			"logs": cell["logs"]}
	var write_ok: bool = results["write"]["seen"]["visible_half"] == "magenta" and results["write"]["seen"]["hidden_half"] == "grey"
	var fail_ok: bool = results["write_depth_fail"]["seen"]["visible_half"] == "green" \
		and results["write_depth_fail"]["seen"]["hidden_half"] == "magenta"
	results["verdict"] = "holds" if write_ok and fail_ok else "partly" if write_ok or fail_ok else "fails"
	_findings["K7"] = results


# --- Scene helpers ----------------------------------------------------------------------------------------------------------
func _cell(label: String) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = CELL
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	_logger.take()  # what this scene's shaders say from here on is this scene's
	var camera := Camera3D.new()
	camera.position = Vector3(0, 0, 6)
	camera.fov = 40.0
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	camera.environment = environment
	viewport.add_child(camera)
	camera.current = true
	return {"label": label, "vp": viewport, "cam": camera, "logs": []}


func _render(cell: Dictionary) -> Image:
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image: Image = cell["vp"].get_texture().get_image()
	image.save_png(_out_dir.path_join(cell["label"] + ".png"))
	cell["logs"] = _logger.take()
	return image


func _sample(cell: Dictionary, image: Image, points: Dictionary) -> Dictionary:
	var seen := {}
	for key in points:
		var at: Vector2 = cell["cam"].unproject_position(points[key])
		var pixel := image.get_pixelv(Vector2i(clampi(int(at.x), 0, CELL.x - 1), clampi(int(at.y), 0, CELL.y - 1)))
		seen[key] = _name(pixel)
		seen[key + "_rgb"] = [snappedf(pixel.r, 0.01), snappedf(pixel.g, 0.01), snappedf(pixel.b, 0.01)]
	cell["vp"].queue_free()
	return seen


func _name(pixel: Color) -> String:
	var best := ""
	var best_distance := INF
	for key in PALETTE:
		var c: Color = PALETTE[key]
		var distance := Vector3(pixel.r - c.r, pixel.g - c.g, pixel.b - c.b).length()
		if distance < best_distance:
			best_distance = distance
			best = key
	return best if best_distance < 0.35 else "other"


func _stencil_properties(owner: String) -> Array:
	var names := []
	for property in ClassDB.class_get_property_list(owner, true):
		if "stencil" in String(property["name"]).to_lower():
			names.append(property["name"])
	return names


func _box(cell: Dictionary, at: Vector3, size: Vector3, material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	_instance(cell, mesh, at, material)


func _quad(cell: Dictionary, at: Vector3, size: Vector2, material: Material) -> void:
	var mesh := QuadMesh.new()
	mesh.size = size
	_instance(cell, mesh, at, material)


func _instance(cell: Dictionary, mesh: Mesh, at: Vector3, material: Material) -> void:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	node.material_override = material
	cell["vp"].add_child(node)


func _unshaded(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	return material


func _writer(color: Color, reference: int, flags: int = BaseMaterial3D.STENCIL_FLAG_WRITE) -> StandardMaterial3D:
	var material := _unshaded(color)
	material.stencil_mode = BaseMaterial3D.STENCIL_MODE_CUSTOM
	material.stencil_flags = flags
	material.stencil_compare = BaseMaterial3D.STENCIL_COMPARE_ALWAYS
	material.stencil_reference = reference
	return material


func _shader(body: String, priority: int) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = "shader_type spatial;\n" + body
	var material := ShaderMaterial.new()
	material.shader = shader
	material.render_priority = priority
	return material
