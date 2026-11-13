## Builds the ultimates' signature effects (spec vfx-content-pass, group 4b: each ultimate gets its own effect, not a recolour of a
## shared one). This is the vertical slice of three (Meteor, Absolute Zero, Execute). Each is played on every unit its ultimate reaches by the
## ultimate's cue (`FxCueNotify.target_fx`, built by build_vfx_ults.tscn; the ability passes its targets in the cue payload). New files only,
## into presentation/demo/fx/; never overwrites one (`--force` rewrites this set's own files, `--only <name>` just one).
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_vfx_signatures.tscn [-- --force | --only <name>]
extends Node

const OUT: String = "res://presentation/demo/fx/"
const TEX: String = "res://presentation/demo/fx/textures/"
const SHADERS: String = "res://game/fx/shaders/"

const FIRE := Color(1.0, 0.45, 0.14)
const ICE := Color(0.5, 0.9, 1.0)
const BLOOD := Color(0.95, 0.12, 0.14)

var _force: bool = false
var _only: String = ""
var _written := PackedStringArray()
var _kept := PackedStringArray()


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_force = args.has("--force") or args.has("--only")
	if args.has("--only") and args.find("--only") + 1 < args.size():
		_only = args[args.find("--only") + 1]
	var meteor := _save(_meteor_strike())
	var zero := _save(_absolute_zero_strike())
	var execute := _save(_execute_strike())
	_register([meteor, zero, execute])
	print("build_vfx_signatures: wrote %d, kept %d existing" % [_written.size(), _kept.size()])
	for path in _written:
		print("  wrote ", path)
	for path in _kept:
		print("  kept  ", path)
	get_tree().quit()


# --- Meteor: a fireball falls onto each enemy and the ground erupts -----------------------------------------------------------

func _meteor_strike() -> FxDefinition:
	var fall := _fall(5.2, 0.2, 0.45)
	var drift := _slide("position:x", 0.9, 0.0)
	# The rock: a lumpy sphere with glowing cracks, falling diagonally and tumbling.
	var sphere := SphereMesh.new()
	sphere.radius = 0.55
	sphere.height = 1.1
	sphere.radial_segments = 32
	sphere.rings = 16
	var rock_material := ShaderMaterial.new()
	rock_material.shader = load(SHADERS + "material/lava_rock.gdshader")
	var rock := FxMeshLayer.new()
	rock.id = &"rock"
	rock.mesh = sphere
	rock.material = rock_material
	rock.seconds = 0.45
	rock.bindings = [_bind("material_override:shader_parameter/color", &"color"), _bind("material_override:shader_parameter/glow", &"intensity", 1.5)]
	rock.tracks = [fall, drift, _slide("rotation_degrees:x", 0.0, 540.0, 720.0), _slide("rotation_degrees:z", 0.0, 300.0, 720.0)]
	# The heat haze around the rock, travelling with it.
	var halo := _quad("halo", "glow_3d", Vector2(2.2, 2.2), 0.45)
	halo.shader_params = {"falloff": 3.0, "fade_out": 0.0}
	halo.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.2)]
	halo.tracks = [fall, drift]
	# The fire trail: flames left behind in the world by an emitter that moves with the rock.
	var trail := FxParticles3DLayer.new()
	trail.id = &"trail"
	trail.texture = load(TEX + "flame_sheet.png")
	trail.h_frames = 8
	trail.v_frames = 4
	trail.local_coords = false
	trail.amount = 36
	trail.lifetime = 0.42
	trail.explosiveness = 0.0
	trail.speed_min = 0.0
	trail.speed_max = 0.3
	trail.gravity = Vector3(0, 0.8, 0)
	trail.size_min = 0.9
	trail.size_max = 1.3
	trail.color_ramp = _ramp([Color(1, 1, 1, 0.9), Color(1, 1, 1, 0.5), Color(1, 1, 1, 0.0)], [0.0, 0.4, 1.0])
	trail.bindings = [_bind("process_material:color", &"color")]
	trail.tracks = [fall, drift]
	# The impact: the existing explosion, a beat after the rock lands, and a scorch ring on the ground.
	var blast := FxSubFxLayer.new()
	blast.id = &"blast"
	blast.start_delay = 0.42
	blast.effect = load(OUT + "explosion.tres")
	blast.param_map = {"color": "$color", "size": 0.85}
	var ring := _floor_ring("scorch", 0.42, 3.0, 0.6)
	var light := _light(0.42, 3.5, 0.5)
	return _define(&"fx.meteor_strike", "Meteor strike", [rock, halo, trail, blast, ring, light],
		[_param(&"color", FxParam.Kind.COLOR, FIRE, "Fire colour."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Glow brightness.", 0.0, 4.0)],
		"A burning boulder falls onto a unit, tumbling and trailing fire, and the ground erupts.", [&"Fx.Kind.Burst"], &"Base")


# --- Absolute Zero: ice erupts under each enemy and shatters ------------------------------------------------------------------

func _absolute_zero_strike() -> FxDefinition:
	var ring := _floor_ring("frostring", 0.0, 3.2, 0.7)
	var spikes := FxParticles3DLayer.new()
	spikes.id = &"spikes"
	spikes.texture = load(TEX + "shard_sheet.png")
	spikes.h_frames = 4
	spikes.v_frames = 2
	spikes.anim_cycles = 0.0
	spikes.random_frame = true
	spikes.additive = false
	spikes.amount = 8
	spikes.lifetime = 1.6
	spikes.explosiveness = 0.9
	spikes.local_coords = true
	spikes.emission_ring_radius = 0.5
	spikes.emission_offset = Vector3(0.0, 0.1, 0.0)
	spikes.direction = Vector3.UP
	spikes.spread = 8.0
	spikes.speed_min = 5.0
	spikes.speed_max = 7.0
	spikes.damping = 7.0
	spikes.gravity = Vector3.ZERO
	spikes.size_min = 0.9
	spikes.size_max = 1.3
	spikes.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.5, 0.52])
	spikes.bindings = [_bind("process_material:color", &"color")]
	var shell := FxFresnelLayer.new()
	shell.id = &"shell"
	shell.seconds = 1.0
	shell.power = 2.0
	shell.fill = 0.25
	shell.grow = 0.012
	shell.intensity = 1.1
	shell.bindings = [_bind("color", &"color")]
	var shards := FxParticles3DLayer.new()
	shards.id = &"shatter"
	shards.start_delay = 0.8
	shards.texture = load(TEX + "shard_sheet.png")
	shards.h_frames = 4
	shards.v_frames = 2
	shards.anim_cycles = 0.0
	shards.random_frame = true
	shards.additive = false
	shards.amount = 24
	shards.lifetime = 0.8
	shards.emission_offset = Vector3(0.0, 0.7, 0.0)
	shards.spread = 180.0
	shards.speed_min = 3.0
	shards.speed_max = 6.5
	shards.gravity = Vector3(0, -8.0, 0)
	shards.size_min = 0.22
	shards.size_max = 0.4
	shards.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.7, 1.0])
	shards.bindings = [_bind("process_material:color", &"color")]
	var mist := FxParticles3DLayer.new()
	mist.id = &"mist"
	mist.start_delay = 0.75
	mist.min_quality = FxLayer.Quality.MEDIUM
	mist.texture = load(TEX + "smoke_sheet.png")
	mist.h_frames = 4
	mist.v_frames = 4
	mist.amount = 6
	mist.lifetime = 1.5
	mist.explosiveness = 0.6
	mist.emission_offset = Vector3(0.0, 0.3, 0.0)
	mist.spread = 180.0
	mist.speed_min = 0.4
	mist.speed_max = 1.2
	mist.gravity = Vector3(0, 0.2, 0)
	mist.size_min = 1.3
	mist.size_max = 2.0
	mist.soft_distance = 0.5
	mist.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 0.4), Color(1, 1, 1, 0)], [0.0, 0.2, 1.0])
	mist.bindings = [_bind("process_material:color", &"color")]
	var shake := FxShakeLayer.new()
	shake.id = &"shake"
	shake.start_delay = 0.8
	shake.min_quality = FxLayer.Quality.MEDIUM
	shake.seconds = 0.25
	shake.strength_world = 0.06
	return _define(&"fx.absolute_zero_strike", "Absolute Zero strike", [ring, spikes, shell, shards, mist, shake],
		[_param(&"color", FxParam.Kind.COLOR, ICE, "Ice colour.")],
		"Ice spikes erupt under a unit, hold, then shatter into a burst of shards and frost mist.", [&"Fx.Kind.Burst"], &"Base")


# --- Execute: a guillotine blade falls and the screen flares red -----------------------------------------------------------------

func _execute_strike() -> FxDefinition:
	var blade := _quad("blade", "glow_3d", Vector2(0.5, 4.6), 0.18)
	blade.shader_params = {"falloff": 7.0, "fade_out": 0.0}
	blade.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 3.0)]
	blade.tracks = [_fall(4.6, -0.2, 0.18)]
	var cut := _quad("cut", "slash_3d", Vector2(3.6, 3.6), 0.26)
	cut.start_delay = 0.17
	cut.shader_params = {"thickness": 0.2, "angle": 0.0}
	cut.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.4)]
	var sparks := FxParticles3DLayer.new()
	sparks.id = &"sparks"
	sparks.start_delay = 0.17
	sparks.amount = 22
	sparks.lifetime = 0.5
	sparks.emission_offset = Vector3(0.0, 0.2, 0.0)
	sparks.spread = 70.0
	sparks.direction = Vector3.UP
	sparks.speed_min = 2.5
	sparks.speed_max = 6.5
	sparks.gravity = Vector3(0, -9.0, 0)
	sparks.size_min = 0.07
	sparks.size_max = 0.14
	sparks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	sparks.bindings = [_bind("process_material:color", &"color")]
	var flash := FxFresnelLayer.new()
	flash.id = &"flash"
	flash.start_delay = 0.17
	flash.seconds = 0.4
	flash.power = 1.8
	flash.fill = 0.4
	flash.intensity = 1.3
	flash.bindings = [_bind("color", &"color")]
	var vignette := FxSubFxLayer.new()
	vignette.id = &"vignette"
	vignette.start_delay = 0.17
	vignette.effect = load(OUT + "screen_flash.tres")
	vignette.param_map = {"color": "$color", "intensity": 1.2}
	var light := _light(0.17, 4.0, 0.4)
	var shake := FxShakeLayer.new()
	shake.id = &"shake"
	shake.start_delay = 0.17
	shake.min_quality = FxLayer.Quality.MEDIUM
	shake.seconds = 0.2
	shake.strength_world = 0.07
	return _define(&"fx.execute_strike", "Execute strike", [blade, cut, sparks, flash, vignette, light, shake],
		[_param(&"color", FxParam.Kind.COLOR, BLOOD, "Blade and blood colour."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0)],
		"A red guillotine blade drops onto a unit, a cut, a red flash and a heavy hit.", [&"Fx.Kind.Burst"], &"Hit")


# --- Registry ------------------------------------------------------------------------------------------------------------------------

func _register(effects: Array[FxDefinition]) -> void:
	var path := OUT + "fx_registry.tres"
	var registry: FxRegistry = load(path)
	var changed := false
	var missing := PackedStringArray()
	for effect in effects:
		if not registry.definitions.has(effect):
			missing.append(String(effect.id))
			changed = true
	if changed:
		# Additive text patch only (user, 2026-11-09): new entries appended, nothing existing touched, RegistryPatch prints what it added.
		for line in RegistryPatch.add_missing_effects():
			print("  registry: ", line)


# --- Helpers ----------------------------------------------------------------------------------------------------------------------

## A shader quad in the world, camera-facing, lasting `seconds`.
func _quad(layer_id: StringName, shader_name: String, size: Vector2, seconds: float) -> FxShaderQuadLayer:
	var quad := FxShaderQuadLayer.new()
	quad.id = layer_id
	quad.space = FxLayer.Space.WORLD_3D
	quad.shader = load(SHADERS + shader_name + ".gdshader")
	quad.size = size
	quad.duration = seconds
	return quad


## A track dropping the layer's node from `from` to `to` world units above where it was placed over its life, quickening as it falls.
func _fall(from: float, to: float, seconds: float) -> FxCurveTrack:
	var track := FxCurveTrack.new()
	track.property = "position:y"
	track.mode = FxCurveTrack.Mode.ADD
	var curve := Curve.new()
	curve.min_value = minf(from, to) - 1.0
	curve.max_value = maxf(from, to) + 1.0
	curve.add_point(Vector2(0.0, from))
	curve.add_point(Vector2(0.55, lerpf(from, to, 0.7)))
	curve.add_point(Vector2(1.0, to))
	track.curve = curve
	return track


## A track moving a property from `from` to `to` over the layer's life (ADD: relative to where it started).
func _slide(property: String, from: float, to: float, bound: float = 8.0) -> FxCurveTrack:
	var track := FxCurveTrack.new()
	track.property = property
	track.mode = FxCurveTrack.Mode.ADD
	var curve := Curve.new()
	curve.min_value = -bound
	curve.max_value = bound
	curve.add_point(Vector2(0.0, from))
	curve.add_point(Vector2(1.0, to))
	track.curve = curve
	return track


func _floor_ring(layer_id: StringName, delay: float, size: float, seconds: float) -> FxShaderQuadLayer:
	var ring := _quad(layer_id, "burst_3d", Vector2(size, size), seconds)
	ring.socket = &"Base"
	ring.face_camera = false
	ring.start_delay = delay
	ring.shader_params = {"ring_width": 0.07, "start_radius": 0.2, "end_radius": 0.95, "intensity": 1.6}
	ring.bindings = [_bind("material:shader_parameter/color", &"color")]
	var flat := FxCurveTrack.new()
	flat.property = "rotation_degrees:x"
	var curve := Curve.new()
	curve.min_value = -360.0
	curve.max_value = 360.0
	curve.add_point(Vector2(0.0, -90.0))
	curve.add_point(Vector2(1.0, -90.0))
	flat.curve = curve
	ring.tracks = [flat]
	return ring


func _light(delay: float, energy: float, seconds: float) -> FxLightLayer:
	var light := FxLightLayer.new()
	light.id = &"light"
	light.start_delay = delay
	light.min_quality = FxLayer.Quality.MEDIUM
	light.energy = energy
	light.light_range = 6.0
	light.seconds = seconds
	light.bindings = [_bind("light_color", &"color")]
	return light


func _define(effect_id: StringName, title: String, layers: Array, params: Array, note: String, tags: Array, socket: StringName) -> FxDefinition:
	var definition := FxDefinition.new()
	definition.id = effect_id
	definition.display_name = title
	definition.space = FxDefinition.Space.WORLD_3D
	definition.layers.assign(layers)
	definition.params.assign(params)
	definition.description = note
	definition.tags.assign(tags)
	definition.socket = socket
	return definition


func _param(param_name: StringName, kind: FxParam.Kind, default: Variant, note: String, low: float = 0.0, high: float = 0.0) -> FxParam:
	var param := FxParam.new()
	param.name = param_name
	param.kind = kind
	param.default_value = default
	param.min_value = low
	param.max_value = high
	param.description = note
	return param


func _bind(property: String, param: StringName, scale: float = 1.0) -> FxBinding:
	var binding := FxBinding.new()
	binding.property = property
	binding.param = param
	binding.scale = scale
	return binding


func _ramp(colors: Array, offsets: Array) -> Gradient:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array(offsets)
	gradient.colors = PackedColorArray(colors)
	return gradient


func _save(definition: FxDefinition) -> FxDefinition:
	var path := OUT + String(definition.id).trim_prefix("fx.") + ".tres"
	if (_only != "" and _only != String(definition.id).trim_prefix("fx.")) or (FileAccess.file_exists(path) and not _force):
		_kept.append(path)
		return load(path)
	if BuilderSave.save(definition, path) != OK:
		push_error("build_vfx_signatures: cannot write %s" % path)
		return definition
	_written.append(path)
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as FxDefinition
