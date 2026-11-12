## Builds the ultimates group of the content-pass effects (spec vfx-content-pass D5, group 4): the ultimate flourish (one effect on the
## caster, with a cue scene per ultimate that sets its own colour, ray count and spin), the slash hit for physical damage, and the
## support rule for it. New files only, into presentation/demo/fx/ and presentation/demo/cues/; never overwrites one (`--force` rewrites
## this set's own files, `--only <name>` just one). The ability scenes' `cast_cue_tags` and the cue registry entries are edited by hand.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_vfx_ults.tscn [-- --force | --only <name>]
extends Node

const OUT: String = "res://presentation/demo/fx/"
const CUES: String = "res://presentation/demo/cues/"
const SHADERS: String = "res://game/fx/shaders/"

## Cue.Fx.Ult.<name> -> {colour, rays, spin, intensity}. The structure is shared (rays, rings, a pillar, a flash, a light, a shake); the
## look of each ultimate is these four numbers, to be tuned one by one.
const ULTS: Dictionary = {
	"Absolutezero": [Color(0.5, 0.9, 1.0), 10.0, 0.05, 1.0], "Bastion": [Color(0.4, 0.7, 1.0), 8.0, 0.04, 1.0],
	"Blackmass": [Color(0.55, 0.3, 0.9), 12.0, -0.10, 1.0], "Cleave": [Color(1.0, 0.45, 0.35), 6.0, 0.20, 1.0],
	"Combustion": [Color(1.0, 0.5, 0.15), 14.0, 0.08, 1.0], "Crucible": [Color(1.0, 0.45, 0.1), 16.0, 0.08, 1.2],
	"Deathray": [Color(0.7, 0.4, 1.0), 4.0, 0.02, 1.0], "Execute": [Color(0.9, 0.1, 0.15), 6.0, 0.12, 1.1],
	"Finale": [Color(1.0, 0.85, 0.35), 20.0, 0.06, 1.3], "Judgement": [Color(1.0, 0.92, 0.55), 24.0, 0.03, 1.2],
	"Liquidate": [Color(0.4, 0.9, 0.5), 10.0, 0.10, 1.0], "Meteor": [Color(1.0, 0.4, 0.1), 8.0, 0.05, 1.4],
	"Oblivion": [Color(0.45, 0.25, 0.7), 14.0, -0.06, 1.0], "Ossuary": [Color(0.9, 0.88, 0.75), 12.0, 0.05, 1.0],
	"Overheat": [Color(1.0, 0.3, 0.1), 18.0, 0.30, 1.2], "Pandemic": [Color(0.6, 0.9, 0.25), 12.0, 0.07, 1.0],
	"Quake": [Color(0.85, 0.6, 0.35), 8.0, 0.0, 1.1], "Rainofarrows": [Color(0.8, 1.0, 0.85), 16.0, 0.12, 1.0],
	"Resurrection": [Color(1.0, 0.95, 0.7), 22.0, 0.04, 1.3], "Sanctuary": [Color(0.5, 1.0, 0.65), 12.0, 0.05, 1.1],
	"Shatterchorus": [Color(0.7, 0.95, 1.0), 18.0, 0.15, 1.1], "Supernova": [Color(1.0, 0.65, 0.2), 26.0, 0.09, 1.5],
	"Systole": [Color(1.0, 0.25, 0.3), 10.0, 0.10, 1.0], "Twinbeat": [Color(1.0, 0.5, 0.8), 8.0, 0.18, 1.0],
}

## Ultimates with their own signature effect: Cue.Fx.Ult.<name> -> [effect file, stagger seconds between targets, literal parameters].
const SIGNATURES: Dictionary = {
	"Meteor": ["meteor_strike", 0.14, {"color": Color(1.0, 0.45, 0.14), "intensity": 1.0}],
	"Absolutezero": ["absolute_zero_strike", 0.1, {"color": Color(0.5, 0.9, 1.0)}],
	"Execute": ["execute_strike", 0.0, {"color": Color(0.95, 0.12, 0.14), "intensity": 1.0}],
}

## The other ultimates' signature effects (build_vfx_signatures2.tscn): Cue.Fx.Ult.<name> -> [effect file, stagger between targets]; the cue
## passes its own colour. All-enemies and all-allies ultimates stagger their targets a little; single-target and self ones do not.
const MORE_SIGNATURES: Dictionary = {
	"Supernova": ["supernova_strike", 0.12], "Overheat": ["overheat_strike", 0.12], "Crucible": ["crucible_strike", 0.12], "Pandemic": ["pandemic_strike", 0.12],
	"Blackmass": ["blackmass_strike", 0.0], "Deathray": ["deathray_strike", 0.0], "Cleave": ["cleave_strike", 0.1], "Judgement": ["judgement_strike", 0.0],
	"Liquidate": ["liquidate_strike", 0.0], "Oblivion": ["oblivion_strike", 0.12], "Ossuary": ["ossuary_strike", 0.12], "Quake": ["quake_strike", 0.0],
	"Rainofarrows": ["rainofarrows_strike", 0.12], "Shatterchorus": ["shatterchorus_strike", 0.1], "Systole": ["systole_strike", 0.12],
	"Twinbeat": ["twinbeat_strike", 0.0], "Bastion": ["bastion_strike", 0.08], "Combustion": ["combustion_strike", 0.0], "Finale": ["finale_strike", 0.08],
	"Resurrection": ["resurrection_strike", 0.0], "Sanctuary": ["sanctuary_strike", 0.08],
}

var _force: bool = false
var _only: String = ""
var _written := PackedStringArray()
var _kept := PackedStringArray()


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_force = args.has("--force") or args.has("--only")
	if args.has("--only") and args.find("--only") + 1 < args.size():
		_only = args[args.find("--only") + 1]
	var flourish := _save(_ult_flourish())
	var slash := _save(_slash_hit())
	for ult in ULTS:
		var look: Array = ULTS[ult]
		_cue("cue_ult_" + String(ult).to_lower(), flourish, {"color": look[0], "ray_count": look[1], "spin": look[2], "intensity": look[3]},
			SIGNATURES.get(ult, [MORE_SIGNATURES[ult][0], MORE_SIGNATURES[ult][1], {"color": look[0]}] if MORE_SIGNATURES.has(ult) else []))
	_register([flourish, slash])
	print("build_vfx_ults: wrote %d, kept %d existing" % [_written.size(), _kept.size()])
	for path in _written:
		print("  wrote ", path)
	for path in _kept:
		print("  kept  ", path)
	get_tree().quit()


# --- Effects ---------------------------------------------------------------------------------------------------------

## The ultimate's cast: god rays behind the caster, two ripples on the floor, a pillar of light, a flash on the unit, a light and a shake.
## Each ultimate is this effect with its own colour, ray count and spin.
func _ult_flourish() -> FxDefinition:
	var rays := FxShaderQuadLayer.new()
	rays.id = &"rays"
	rays.space = FxLayer.Space.WORLD_3D
	rays.shader = load(SHADERS + "rays_3d.gdshader")
	rays.size = Vector2(4.6, 4.6)
	rays.duration = 0.8
	rays.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.2),
		_bind("material:shader_parameter/ray_count", &"ray_count"), _bind("material:shader_parameter/spin", &"spin")]
	var pillar := FxShaderQuadLayer.new()
	pillar.id = &"pillar"
	pillar.space = FxLayer.Space.WORLD_3D
	pillar.shader = load(SHADERS + "glow_3d.gdshader")
	pillar.size = Vector2(1.4, 5.0)
	pillar.duration = 0.9
	pillar.shader_params = {"falloff": 5.0, "fade_out": 0.6}
	pillar.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.6)]
	var ring := _floor_ring("ring", 0.0)
	var echo := _floor_ring("echo", 0.22)
	var flash := FxFresnelLayer.new()
	flash.id = &"flash"
	flash.seconds = 0.9
	flash.power = 1.8
	flash.fill = 0.35
	flash.intensity = 1.3
	flash.bindings = [_bind("color", &"color")]
	var sparks := FxParticles3DLayer.new()
	sparks.id = &"sparks"
	sparks.amount = 36
	sparks.lifetime = 1.0
	sparks.explosiveness = 0.3
	sparks.emission_radius = 0.5
	sparks.direction = Vector3.UP
	sparks.spread = 30.0
	sparks.speed_min = 1.5
	sparks.speed_max = 4.0
	sparks.gravity = Vector3(0, -1.0, 0)
	sparks.size_min = 0.08
	sparks.size_max = 0.16
	sparks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	sparks.bindings = [_bind("process_material:color", &"color")]
	var light := FxLightLayer.new()
	light.id = &"light"
	light.min_quality = FxLayer.Quality.MEDIUM
	light.energy = 4.0
	light.light_range = 6.0
	light.seconds = 0.9
	light.bindings = [_bind("light_color", &"color")]
	var shake := FxShakeLayer.new()
	shake.id = &"shake"
	shake.min_quality = FxLayer.Quality.MEDIUM
	shake.seconds = 0.3
	shake.strength_world = 0.08
	return _define(&"fx.ult_flourish", "Ultimate flourish", [rays, pillar, ring, echo, flash, sparks, light, shake],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.85, 0.4), "The ultimate's colour."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0),
		_param(&"ray_count", FxParam.Kind.FLOAT, 14.0, "Number of god rays.", 2.0, 40.0),
		_param(&"spin", FxParam.Kind.FLOAT, 0.08, "Turns per second of the rays (negative the other way).", -1.0, 1.0)],
		"An ultimate's cast: rays, ripples, a pillar of light, a flash, a light and a shake.", [&"Fx.Kind.Burst"], &"Center", true)


## A physical hit: a crescent cut across the target, a few sparks and a flash. Replaces the generic spark physical hits used to have.
func _slash_hit() -> FxDefinition:
	var cut := FxShaderQuadLayer.new()
	cut.id = &"cut"
	cut.space = FxLayer.Space.WORLD_3D
	cut.shader = load(SHADERS + "slash_3d.gdshader")
	cut.size = Vector2(2.8, 2.8)
	cut.duration = 0.32
	cut.shader_params = {"thickness": 0.28}
	cut.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.0),
		_bind("material:shader_parameter/angle", &"angle")]
	var sparks := FxParticles3DLayer.new()
	sparks.id = &"sparks"
	sparks.amount = 14
	sparks.lifetime = 0.35
	sparks.spread = 70.0
	sparks.direction = Vector3.UP
	sparks.speed_min = 2.0
	sparks.speed_max = 5.0
	sparks.gravity = Vector3(0, -7.0, 0)
	sparks.size_min = 0.06
	sparks.size_max = 0.12
	sparks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	sparks.bindings = [_bind("process_material:color", &"color")]
	var flash := FxFresnelLayer.new()
	flash.id = &"flash"
	flash.seconds = 0.18
	flash.power = 2.0
	flash.fill = 0.15
	flash.intensity = 1.0
	flash.bindings = [_bind("color", &"color")]
	return _define(&"fx.slash_hit", "Slash hit", [cut, sparks, flash],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.96, 0.85), "Colour of the cut."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0),
		_param(&"angle", FxParam.Kind.FLOAT, -25.0, "Degrees the cut is turned.", -180.0, 180.0)],
		"A crescent cut with sparks on a unit hit by physical damage.", [&"Fx.Kind.Hit"], &"Hit", true)


func _floor_ring(layer_id: StringName, delay: float) -> FxShaderQuadLayer:
	var ring := FxShaderQuadLayer.new()
	ring.id = layer_id
	ring.space = FxLayer.Space.WORLD_3D
	ring.socket = &"Base"
	ring.shader = load(SHADERS + "burst_3d.gdshader")
	ring.face_camera = false
	ring.start_delay = delay
	ring.size = Vector2(3.4, 3.4)
	ring.duration = 0.7
	ring.shader_params = {"ring_width": 0.07, "start_radius": 0.2, "end_radius": 0.95, "intensity": 1.6}
	ring.bindings = [_bind("material:shader_parameter/color", &"color")]
	var flat := FxCurveTrack.new()
	flat.property = "rotation_degrees:x"
	flat.curve = _curve([[0.0, -90.0], [1.0, -90.0]], -360.0, 360.0)
	ring.tracks = [flat]
	return ring


# --- Cue scenes and registry -----------------------------------------------------------------------------------------------

func _cue(file: String, fx: FxDefinition, literals: Dictionary, signature: Array = []) -> void:
	var path := CUES + file + ".tscn"
	if (_only != "" and _only != file) or (FileAccess.file_exists(path) and not _force):
		_kept.append(path)
		return
	var cue := FxCueNotify.new()
	cue.name = file.to_pascal_case()
	cue.fx = fx
	cue.auto_destroy = true
	cue.stop_fade = 0.25
	var bindings: Array[FxCueBinding] = []
	for param in literals:
		var binding := FxCueBinding.new()
		binding.param = StringName(param)
		binding.source = FxCueBinding.Source.LITERAL
		binding.value = literals[param]
		bindings.append(binding)
	cue.bindings = bindings
	if not signature.is_empty():
		cue.target_fx = load(OUT + signature[0] + ".tres")
		cue.target_stagger = signature[1]
		var target_bindings: Array[FxCueBinding] = []
		for param in signature[2]:
			var binding := FxCueBinding.new()
			binding.param = StringName(param)
			binding.source = FxCueBinding.Source.LITERAL
			binding.value = signature[2][param]
			target_bindings.append(binding)
		cue.target_bindings = target_bindings
	var scene := PackedScene.new()
	scene.pack(cue)
	if BuilderSave.save(scene, path) == OK:
		_written.append(path)


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


# --- Helpers ---------------------------------------------------------------------------------------------------------------

func _define(effect_id: StringName, title: String, layers: Array, params: Array, note: String, tags: Array, socket: StringName,
		_biased: bool) -> FxDefinition:
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


func _curve(points: Array, low: float = 0.0, high: float = 1.0) -> Curve:
	var curve := Curve.new()
	curve.min_value = low
	curve.max_value = high
	for point in points:
		curve.add_point(Vector2(point[0], point[1]))
	return curve


func _save(definition: FxDefinition) -> FxDefinition:
	var path := OUT + String(definition.id).trim_prefix("fx.") + ".tres"
	if (_only != "" and _only != String(definition.id).trim_prefix("fx.")) or (FileAccess.file_exists(path) and not _force):
		_kept.append(path)
		return load(path)
	if BuilderSave.save(definition, path) != OK:
		push_error("build_vfx_ults: cannot write %s" % path)
		return definition
	_written.append(path)
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as FxDefinition
