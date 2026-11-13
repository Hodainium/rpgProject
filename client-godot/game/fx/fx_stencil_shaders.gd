## Shader copies for the stencil experiment (spec vfx-stencil 3.4). A shader material cannot take the stencil reference as a setting
## (K5: it is a compile-time literal), so an effect drawn over P1 and over P2 needs two compiled versions of its shader, each in two
## passes: OWN (only its unit's pixels, no depth test) and OTHER (everywhere else, the normal depth test). A copy is made in memory,
## never written to a file: a few #define lines in front of the original code. The stencil lines live once, in #ifdef blocks of
## fx_stencil_depth.gdshaderinc, so without the defines every shader is exactly today's.
## `mode` is the dev switch (console `fx stencil on|off`): stencil, the default, or off (every effect one pass with the plain depth
## test, for debugging and for a renderer without stencil). Presentation only.
class_name FxStencilShaders
extends RefCounted

enum Pass { OWN, OTHER }

const OFF: StringName = &"off"
## The include that carries the stencil lines; a shader without it has none, so it never goes two-pass.
const INCLUDE := "fx_stencil_depth.gdshaderinc"
## Shader-sampled textures the engine fills; a second pass never copies them.
const ENGINE_UNIFORMS: Array[StringName] = [&"fx_scene_depth"]
const STENCIL: StringName = &"stencil"

## The default (user, 2026-11-11: stencil is kept, on by default).
const DEFAULT_MODE: StringName = STENCIL

## The switch: dev only (console `fx stencil on|off`, the Stencil page, tests); no player Setting.
static var mode: StringName = DEFAULT_MODE
## Dev only: a word put in a comment line in front of every copy (environment RPG_FX_SALT), so its code is new to the driver's and
## Godot's shader caches and a measurement sees a player's first launch (a cold cache). Empty in normal runs: no line is added.
static var dev_salt: String = OS.get_environment("RPG_FX_SALT")
## How many copies were made since the last clear(), and the time spent building the copy objects (ms). Building is cheap: the
## renderer compiles a copy the first time it draws it, which this cannot see (the stage measures it as first_frames_ms).
static var made: int = 0
static var build_ms: float = 0.0

## Shader -> {"value|pass": copy}, and Shader -> the code its copies were made from. Keyed by the Shader itself (held, so an
## instance id is never reused under it); a shader whose code changed (an edit, a hot reload) gets fresh copies.
static var _cache: Dictionary = {}
static var _source: Dictionary = {}
## Shader (an original or a copy) -> [code, its uniform names a second pass copies] (read once per code:
## get_shader_uniform_list goes through the RenderingServer and allocates).
static var _names: Dictionary = {}
static var _include_line: RegEx
static var _supports: Dictionary = {}  # Shader -> [its code, whether it includes the stencil lines]


static func enabled() -> bool:
	return mode == STENCIL


## The copy of `shader` for stencil `value` and `pass`, cached. `value` must be a unit value (StencilIds.UNIT_FIRST..UNIT_LAST).
static func variant(shader: Shader, value: int, pass_kind: int) -> Shader:
	if _source.get(shader) != shader.code:
		_cache[shader] = {}
		_source[shader] = shader.code
		_names.erase(shader)
	var copies: Dictionary = _cache[shader]
	var key := "%d|%d" % [value, pass_kind]
	var cached: Variant = copies.get(key)
	if cached != null:
		return cached
	var started := Time.get_ticks_usec()
	var copy := Shader.new()
	copy.code = defines(value, pass_kind) + shader.code
	copies[key] = copy
	made += 1
	build_ms += (Time.get_ticks_usec() - started) / 1000.0
	return copy


## True when `shader` can draw over a unit: it includes the stencil lines (fx_stencil_depth.gdshaderinc). Any other shader would draw
## its whole effect in both passes, twice as bright, with no stencil test.
static func supports(shader: Shader) -> bool:
	if shader == null:
		return false
	var cached: Variant = _supports.get(shader)
	if cached != null and cached[0] == shader.code:
		return cached[1]  # (an edited shader, a hot reload, is checked again)
	if _include_line == null:
		_include_line = RegEx.create_from_string(r'(?m)^\s*#include\s+"[^"]*' + INCLUDE.replace(".", "\\.") + '"')
	var found := _include_line.search(shader.code) != null  # the #include line itself, not a comment naming the file
	_supports[shader] = [shader.code, found]
	return found


## The lines put in front of a shader's code (the probe showed defines before shader_type reach an #include).
static func defines(value: int, pass_kind: int) -> String:
	var lines := ("// salt %s\n" % dev_salt) if dev_salt != "" else ""
	lines += "#define FX_STENCIL_REF %d\n#define FX_STENCIL_COMPARE %s\n" % [value,
		"compare_equal" if pass_kind == Pass.OWN else "compare_not_equal"]
	if pass_kind == Pass.OWN:
		lines += "#define FX_STENCIL_OWN\n"
	return lines


## The uniforms of `shader` a second pass mirrors (all but `skip`), read once per shader code.
static func uniform_names(shader: Shader) -> Array[StringName]:
	var cached: Variant = _names.get(shader)
	if cached != null and cached[0] == shader.code:
		return cached[1]
	var names: Array[StringName] = []
	for uniform in shader.get_shader_uniform_list():
		var key := StringName(uniform["name"])
		if not key in ENGINE_UNIFORMS:
			names.append(key)
	_names[shader] = [shader.code, names]  # with the code it was read from: an edited shader re-reads
	return names


static func cached_count() -> int:
	var count := 0
	for copies in _cache.values():
		count += (copies as Dictionary).size()
	return count


## Drops every copy and counter. FxManager calls it at shutdown so no shader is leaked.
static func clear() -> void:
	_cache.clear()
	_source.clear()
	_names.clear()
	_prepared.clear()
	_in_flight.clear()
	_supports.clear()
	prepare_log.clear()
	made = 0
	build_ms = 0.0


# --- Prepare (spec vfx-stencil 3.4): at boot, at run start and at battle start ---------------------------------------------------

## How long the last prepare took (ms, the frames it drew included) and how many copies it drew, for `fx stencil dump`.
static var last_prepare_ms: float = 0.0
static var last_prepare_copies: int = 0
## Every prepare's (when, copies drawn, ms) this session, oldest first, for `fx stencil dump` and the frame log.
static var prepare_log: Array[String] = []
## The copies already drawn once this session (the renderer keeps their pipelines): a later prepare skips them.
static var _prepared: Dictionary = {}
## The copies a running prepare is drawing now: another prepare (boot still going when the run starts) skips them too.
static var _in_flight: Dictionary = {}


## The shaders the effects in `definitions` draw over their unit with (each layer's stencil_shader()), once each.
static func over_unit_shaders(definitions: Array) -> Array[Shader]:
	var shaders: Array[Shader] = []
	for definition in definitions:
		if definition == null:
			continue
		for layer in (definition as FxDefinition).layers:
			var shader := layer.stencil_shader() if layer != null else null
			if shader != null and not shader in shaders:
				shaders.append(shader)
	return shaders


## Has the renderer compile the copies of `shaders` for `values` (both passes) now, so no battle frame does: each copy is drawn once,
## a speck in front of `camera` for two frames (a particle shader through a one-particle emitter, the way particles draw it), then
## removed. `per_frame` > 0 spreads the work: that many copies a batch, one batch after another, so no single frame stalls (the
## boot prepare on the main menu); 0 draws them all in one batch. Copies already drawn, or being drawn by another prepare, are
## skipped. `label` names the caller in `prepare_log`. Returns the number of copies drawn. Does nothing when stencil is off,
## headless, or with no camera.
static func prepare(camera: Camera3D, shaders: Array[Shader], values: Array, per_frame: int = 0, label: String = "battle") -> int:
	if not enabled() or camera == null or not camera.is_inside_tree() or DisplayServer.get_name() == "headless":
		return 0
	var started := Time.get_ticks_usec()
	var todo: Array = []  # [shader, copy]
	for shader in shaders:
		for value in values:
			if not StencilIds.is_unit(int(value)):
				continue
			for pass_kind in [Pass.OWN, Pass.OTHER]:
				var copy := variant(shader, int(value), pass_kind)
				if not _prepared.has(copy) and not _in_flight.has(copy):
					_in_flight[copy] = true
					todo.append([shader, copy])
	var batch_size: int = todo.size() if per_frame <= 0 else per_frame
	var count := 0
	var tree := camera.get_tree()
	var at := 0
	while at < todo.size():
		if not is_instance_valid(camera) or not camera.is_inside_tree():
			break  # the camera's scene closed: what is left is drawn by the next prepare
		var holder := Node3D.new()
		holder.name = "FxStencilPrepare"
		camera.add_child(holder)
		holder.position = Vector3(0, 0, -maxf(camera.near * 4.0, 0.2))
		holder.scale = Vector3.ONE * 0.001
		var batch := todo.slice(at, at + batch_size)
		for item in batch:
			var material := ShaderMaterial.new()
			material.shader = item[1]
			holder.add_child(_speck(item[0], material))
		for frame in 2:
			await tree.process_frame
		await RenderingServer.frame_post_draw
		if not is_instance_valid(holder) or not is_instance_valid(camera) or not camera.is_inside_tree():
			break  # gone during these frames: this batch does not count as drawn
		holder.queue_free()
		for item in batch:
			_prepared[item[1]] = true
		count += batch.size()
		at += batch_size
	for item in todo:
		_in_flight.erase(item[1])
	last_prepare_ms = (Time.get_ticks_usec() - started) / 1000.0
	last_prepare_copies = count
	prepare_log.append("%s: %d copies drawn in %.0f ms" % [label, count, last_prepare_ms])
	return count


static func _speck(shader: Shader, material: ShaderMaterial) -> Node3D:
	if shader == FxParticles3DLayer.PARTICLE_SHADER:
		var particles := GPUParticles3D.new()
		particles.amount = 1
		particles.lifetime = 1.0
		particles.process_material = ParticleProcessMaterial.new()
		var quad := QuadMesh.new()
		quad.material = material
		particles.draw_pass_1 = quad
		particles.emitting = true
		return particles
	var speck := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	speck.mesh = mesh
	speck.material_override = material
	speck.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return speck
