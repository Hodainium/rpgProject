## Shader copies for the stencil experiment (spec vfx-stencil 3.4). A shader material cannot take the stencil reference as a setting
## (K5: it is a compile-time literal), so an effect drawn over P1 and over P2 needs two compiled versions of its shader, each in two
## passes: OWN (only its unit's pixels, no depth test) and OTHER (everywhere else, the normal depth test). A copy is made in memory,
## never written to a file: a few #define lines in front of the original code. The stencil lines live once, in #ifdef blocks of
## fx_depth_bias.gdshaderinc, so without the defines every shader is exactly today's.
## `mode` is the A/B switch of the experiment (spec 1.5): bias (today's look, the default) or stencil. Presentation only.
class_name FxStencilShaders
extends RefCounted

enum Pass { OWN, OTHER }

const BIAS: StringName = &"bias"
## The include that carries the stencil lines; a shader without it has none, so it never goes two-pass.
const INCLUDE := "fx_depth_bias.gdshaderinc"
## Shader-sampled textures the engine fills; a second pass never copies them.
const ENGINE_UNIFORMS: Array[StringName] = [&"fx_scene_depth"]
const STENCIL: StringName = &"stencil"

## The default (user, 2026-11-11: stencil is kept, on by default).
const DEFAULT_MODE: StringName = STENCIL

## The switch: dev only (console `fx stencil on|off`, the Stencil page, tests); no player Setting.
static var mode: StringName = DEFAULT_MODE
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


## True when `shader` can draw over a unit: it includes the stencil lines (fx_depth_bias.gdshaderinc). Any other shader would draw
## its whole effect in both passes, twice as bright, with no stencil test.
static func supports(shader: Shader) -> bool:
	if shader == null:
		return false
	if _include_line == null:
		_include_line = RegEx.create_from_string(r'(?m)^\s*#include\s+"[^"]*' + INCLUDE.replace(".", "\\.") + '"')
	return _include_line.search(shader.code) != null  # the #include line itself, not a comment naming the file


## The lines put in front of a shader's code (the probe showed defines before shader_type reach an #include).
static func defines(value: int, pass_kind: int) -> String:
	var lines := "#define FX_STENCIL_REF %d\n#define FX_STENCIL_COMPARE %s\n" % [value,
		"compare_equal" if pass_kind == Pass.OWN else "compare_not_equal"]
	if pass_kind == Pass.OWN:
		lines += "#define FX_STENCIL_OWN\n"
	return lines


## Makes the copies of every shader for every value and both passes. Returns the number made. (The renderer compiles a copy the
## first time it draws; step 2's prepare() behind the loading screen also draws them once.)
static func prepare_values(shaders: Array, values: Array) -> int:
	var before := made
	for shader in shaders:
		for value in values:
			for pass_kind in [Pass.OWN, Pass.OTHER]:
				variant(shader, int(value), pass_kind)
	return made - before


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
	made = 0
	build_ms = 0.0


# --- Prepare at battle start (spec vfx-stencil 3.4, the user's choice: the positions in that battle) --------------------------

## How long the last prepare took (ms, the frames it drew included) and how many copies it drew, for `fx stencil dump`.
static var last_prepare_ms: float = 0.0
static var last_prepare_copies: int = 0


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
## removed. Returns the number of copies drawn. Does nothing when stencil is off, headless, or with no camera.
static func prepare(camera: Camera3D, shaders: Array[Shader], values: Array) -> int:
	if not enabled() or camera == null or not camera.is_inside_tree() or DisplayServer.get_name() == "headless":
		return 0
	var started := Time.get_ticks_usec()
	var holder := Node3D.new()
	holder.name = "FxStencilPrepare"
	camera.add_child(holder)
	holder.position = Vector3(0, 0, -maxf(camera.near * 4.0, 0.2))
	holder.scale = Vector3.ONE * 0.001
	var count := 0
	for shader in shaders:
		for value in values:
			if not StencilIds.is_unit(int(value)):
				continue
			for pass_kind in [Pass.OWN, Pass.OTHER]:
				var material := ShaderMaterial.new()
				material.shader = variant(shader, int(value), pass_kind)
				holder.add_child(_speck(shader, material))
				count += 1
	for frame in 2:
		await camera.get_tree().process_frame
	await RenderingServer.frame_post_draw
	holder.queue_free()
	last_prepare_ms = (Time.get_ticks_usec() - started) / 1000.0
	last_prepare_copies = count
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
