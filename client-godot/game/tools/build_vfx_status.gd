## Builds the DoT and control group of the content-pass effects (spec vfx-content-pass D5, group 2): the looping status looks
## (skin, burning, frozen, stun stars), the bleed tick, and the ten cue scenes that the status effects name. New files only, into
## presentation/demo/fx/ and presentation/demo/cues/; never overwrites one (`--force` rewrites this set's own files and discards tuning).
## The status effects' cue tags and the cue registry entries are edited by hand (they are existing design files).
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_vfx_status.tscn [-- --force]
extends Node

const OUT: String = "res://presentation/demo/fx/"
const CUES: String = "res://presentation/demo/cues/"
const TEX: String = "res://presentation/demo/fx/textures/"

const POISON := Color(0.55, 0.95, 0.35)
const BLEED := Color(0.78, 0.1, 0.14)
const FIRE := Color(1.0, 0.45, 0.16)
const ICE := Color(0.45, 0.88, 1.0)
const GOLD := Color(1.0, 0.82, 0.25)

var _force: bool = false
## `--only <name>` writes just that file's set (an effect id like stun_stars, or a cue file like status_stun_cue) and keeps every other.
var _only: String = ""
var _written := PackedStringArray()
var _kept := PackedStringArray()


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_force = args.has("--force") or args.has("--only")
	if args.has("--only") and args.find("--only") + 1 < args.size():
		_only = args[args.find("--only") + 1]
	var skin := _save(_status_skin())
	var burning := _save(_burning())
	var bleed_tick := _save(_bleed_tick())
	var frozen := _save(_frozen())
	var stars := _save(_stun_stars())
	_add_to_registry([skin, burning, bleed_tick, frozen, stars])
	var poison_tick := load(OUT + "poison_tick.tres") as FxDefinition
	var fire_hit := load(OUT + "fire_hit.tres") as FxDefinition
	# Persistent cues (a status's `persistent_cue_tags`): loop while it lasts, fade out when it ends.
	_cue("status_poison_cue", skin, {"color": POISON, "power": 1.8, "fill": 0.06, "grow": 0.01, "erosion": 0.45, "scroll": 0.6}, true)
	_cue("status_bleed_cue", skin, {"color": BLEED, "power": 2.0, "fill": 0.05, "grow": 0.008, "erosion": 0.5, "scroll": -0.8}, true)
	_cue("status_entangle_cue", skin, {"color": Color(0.5, 0.62, 0.25), "power": 1.6, "fill": 0.12, "grow": 0.02, "erosion": 0.55, "noise_scale": 7.0, "scroll": 0.0}, true)
	_cue("status_slow_cue", skin, {"color": Color(0.55, 0.5, 1.0), "power": 2.0, "fill": 0.1, "grow": 0.008, "erosion": 0.3, "scroll": -0.3}, true)
	_cue("status_burn_cue", burning, {}, true)
	_cue("status_freeze_cue", frozen, {}, true)
	_cue("status_stun_cue", stars, {}, true)
	# Periodic cues (a DoT's `periodic_cue_tags`): a one-shot on each tick.
	_cue("tick_poison_cue", poison_tick, {}, false)
	_cue("tick_bleed_cue", bleed_tick, {"color": BLEED}, false)
	_cue("tick_burn_cue", fire_hit, {"size": 0.5, "intensity": 0.6}, false)
	print("build_vfx_status: wrote %d, kept %d existing" % [_written.size(), _kept.size()])
	for path in _written:
		print("  wrote ", path)
	for path in _kept:
		print("  kept  ", path)
	get_tree().quit()


# --- Effects ---------------------------------------------------------------------------------------------------------

## A looping shell on the unit's own mesh (spec 3.6): poison ooze, bleeding, entangle and slow are this effect with different
## parameters, since they differ only in colour and shell settings.
func _status_skin() -> FxDefinition:
	var rim := FxFresnelLayer.new()
	rim.id = &"skin"
	rim.loop = true
	rim.loop_period = 1.6
	rim.curve = _curve([[0.0, 0.85], [0.5, 1.0], [1.0, 0.85]])
	rim.bindings = [_bind("color", &"color"), _bind("intensity", &"intensity"), _bind("power", &"power"), _bind("fill", &"fill"),
		_bind("grow", &"grow"), _bind("erosion", &"erosion"), _bind("noise_scale", &"noise_scale"), _bind("scroll", &"scroll")]
	return _define(&"fx.status_skin", "Status skin", [rim],
		[_param(&"color", FxParam.Kind.COLOR, POISON, "Shell colour."),
		_param(&"intensity", FxParam.Kind.FLOAT, 0.9, "Brightness.", 0.0, 4.0),
		_param(&"power", FxParam.Kind.FLOAT, 2.0, "How thin the rim is.", 0.5, 8.0),
		_param(&"fill", FxParam.Kind.FLOAT, 0.08, "How much of the body glows besides the rim.", 0.0, 1.0),
		_param(&"grow", FxParam.Kind.FLOAT, 0.01, "World units the shell is pushed out.", 0.0, 0.2),
		_param(&"erosion", FxParam.Kind.FLOAT, 0.4, "How much of the shell the noise eats.", 0.0, 1.0),
		_param(&"noise_scale", FxParam.Kind.FLOAT, 5.0, "Size of the noise pattern.", 0.5, 20.0),
		_param(&"scroll", FxParam.Kind.FLOAT, 0.5, "Noise speed up the body (negative = down).", -4.0, 4.0)],
		"A looping glowing shell on the unit: ooze, bleeding, vines, sluggishness by colour and shell settings.", [&"Fx.Kind.Aura"], &"Center", false)


## Burning: flames on the top face, embers and a fire skin, for as long as the status lasts.
func _burning() -> FxDefinition:
	var flames := FxParticles3DLayer.new()
	flames.id = &"flames"
	flames.loop = true
	flames.texture = load(TEX + "flame_sheet.png")
	flames.h_frames = 8
	flames.v_frames = 4
	flames.amount = 8
	flames.lifetime = 0.9
	flames.explosiveness = 0.0
	flames.emit_from_mesh = true
	flames.emission_min_normal_y = 0.5
	flames.soft_distance = 0.3
	flames.direction = Vector3.UP
	flames.spread = 14.0
	flames.speed_min = 0.3
	flames.speed_max = 0.7
	flames.gravity = Vector3(0, 0.8, 0)
	flames.size_min = 1.2
	flames.size_max = 1.7
	flames.color_ramp = _ramp([Color(1, 1, 1, 0.0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.0)], [0.0, 0.2, 1.0])
	flames.bindings = [_bind("process_material:color", &"color"), _bind("process_material:scale_min", &"size", 1.2),
		_bind("process_material:scale_max", &"size", 1.7)]
	var embers := FxParticles3DLayer.new()
	embers.id = &"embers"
	embers.loop = true
	embers.min_quality = FxLayer.Quality.MEDIUM
	embers.amount = 8
	embers.lifetime = 1.1
	embers.explosiveness = 0.0
	embers.emit_from_mesh = true
	embers.emission_min_normal_y = -0.2
	embers.direction = Vector3.UP
	embers.spread = 40.0
	embers.speed_min = 0.6
	embers.speed_max = 1.6
	embers.gravity = Vector3(0, 0.4, 0)
	embers.size_min = 0.05
	embers.size_max = 0.1
	embers.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	embers.bindings = [_bind("process_material:color", &"color")]
	var rim := FxFresnelLayer.new()
	rim.id = &"skin"
	rim.loop = true
	rim.loop_period = 1.2
	rim.curve = _curve([[0.0, 0.8], [0.5, 1.0], [1.0, 0.8]])
	rim.power = 2.0
	rim.fill = 0.22
	rim.grow = 0.015
	rim.erosion = 0.3
	rim.scroll = 1.6
	rim.noise_scale = 5.0
	rim.intensity = 1.4
	rim.bindings = [_bind("color", &"color")]
	return _define(&"fx.burning", "Burning", [flames, embers, rim],
		[_param(&"color", FxParam.Kind.COLOR, FIRE, "Fire colour."),
		_param(&"size", FxParam.Kind.FLOAT, 1.0, "Flame size multiplier.", 0.3, 3.0)],
		"A unit on fire: flames licking up from its top, embers and a fire skin.", [&"Fx.Kind.Aura"], &"Center", true)


## One bleed tick: red drops thrown off the unit that fall, and a short splat.
func _bleed_tick() -> FxDefinition:
	var drops := FxParticles3DLayer.new()
	drops.id = &"drops"
	drops.additive = false
	drops.amount = 14
	drops.lifetime = 0.8
	drops.emit_from_mesh = true
	drops.emission_min_normal_y = -0.2
	drops.direction = Vector3.UP
	drops.spread = 110.0
	drops.speed_min = 0.4
	drops.speed_max = 1.4
	drops.gravity = Vector3(0, -7.0, 0)
	drops.size_min = 0.14
	drops.size_max = 0.24
	drops.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.7, 1.0])
	drops.bindings = [_bind("process_material:color", &"color")]
	var splat := FxShaderQuadLayer.new()
	splat.id = &"splat"
	splat.space = FxLayer.Space.WORLD_3D
	splat.shader = load("res://game/fx/shaders/glow_3d.gdshader")
	splat.size = Vector2(1.3, 1.3)
	splat.duration = 0.25
	splat.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.2)]
	return _define(&"fx.bleed_tick", "Bleed tick", [drops, splat],
		[_param(&"color", FxParam.Kind.COLOR, BLEED, "Blood colour."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Splat brightness.", 0.0, 4.0)],
		"Red drops falling off a unit that is bleeding.", [&"Fx.Kind.Hit"], &"Center", true)


## Frozen: an ice shell, crystals growing on the surface and a cold mist at the feet.
func _frozen() -> FxDefinition:
	var rim := FxFresnelLayer.new()
	rim.id = &"shell"
	rim.loop = true
	rim.loop_period = 2.4
	rim.curve = _curve([[0.0, 0.9], [0.5, 1.0], [1.0, 0.9]])
	rim.power = 2.0
	rim.fill = 0.14
	rim.grow = 0.012
	rim.intensity = 0.8
	rim.bindings = [_bind("color", &"color")]
	var crystals := FxParticles3DLayer.new()
	crystals.id = &"crystals"
	crystals.loop = true
	crystals.texture = load(TEX + "shard_sheet.png")
	crystals.h_frames = 4
	crystals.v_frames = 2
	crystals.anim_cycles = 0.0
	crystals.random_frame = true
	crystals.additive = false
	crystals.amount = 18
	crystals.lifetime = 2.2
	crystals.explosiveness = 0.0
	crystals.emit_from_mesh = true
	crystals.speed_min = 0.0
	crystals.speed_max = 0.05
	crystals.gravity = Vector3.ZERO
	crystals.size_min = 0.4
	crystals.size_max = 0.65
	crystals.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.15, 0.8, 1.0])
	crystals.bindings = [_bind("process_material:color", &"color")]
	var mist := FxParticles3DLayer.new()
	mist.id = &"mist"
	mist.loop = true
	mist.min_quality = FxLayer.Quality.MEDIUM
	mist.socket = &"Base"
	mist.texture = load(TEX + "smoke_sheet.png")
	mist.h_frames = 4
	mist.v_frames = 4
	mist.amount = 4
	mist.lifetime = 2.2
	mist.explosiveness = 0.0
	mist.emission_radius = 0.4
	mist.spread = 180.0
	mist.speed_min = 0.1
	mist.speed_max = 0.3
	mist.gravity = Vector3(0, 0.15, 0)
	mist.size_min = 1.0
	mist.size_max = 1.5
	mist.soft_distance = 0.5
	mist.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 0.35), Color(1, 1, 1, 0)], [0.0, 0.3, 1.0])
	mist.bindings = [_bind("process_material:color", &"color")]
	return _define(&"fx.frozen", "Frozen", [rim, crystals, mist],
		[_param(&"color", FxParam.Kind.COLOR, ICE, "Ice colour.")],
		"A frozen unit: an ice shell, crystals on its surface and a cold mist at its feet.", [&"Fx.Kind.Aura"], &"Center", true)


## Stun, Persona style: three solid yellow stars circling the head on a slightly tilted ring, each chased by a white trail. A star is one
## small layer on a spinning holder (its own starting angle); its trail is a second layer on the same spin that leaves fading white
## points behind it in the world, so the points line up into an arc as the star moves on.
func _stun_stars() -> FxDefinition:
	var layers: Array = []
	var radius := 0.5
	var height := 0.45
	for index in 3:
		var phase := 120.0 * index
		var spin := FxCurveTrack.new()
		spin.property = "rotation_degrees:y"
		spin.curve = _curve([[0.0, phase], [1.0, phase + 360.0]], 0.0, 1080.0)
		var tilt := FxCurveTrack.new()
		tilt.property = "rotation_degrees:x"
		tilt.curve = _curve([[0.0, 14.0], [1.0, 14.0]], 0.0, 360.0)
		var star := FxParticles3DLayer.new()
		star.id = StringName("star%d" % index)
		star.loop = true
		star.loop_period = 1.5
		star.local_coords = true
		star.texture = load(TEX + "star_sheet.png")
		star.additive = false
		star.amount = 2
		star.lifetime = 2.0
		star.explosiveness = 0.0
		star.emission_offset = Vector3(radius, height, 0.0)
		star.speed_min = 0.0
		star.speed_max = 0.0
		star.gravity = Vector3.ZERO
		star.size_min = 0.34
		star.size_max = 0.34
		star.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.06, 0.94, 1.0])
		star.bindings = [_bind("process_material:color", &"color")]
		star.tracks = [spin, tilt]
		layers.append(star)
		var trail := FxParticles3DLayer.new()
		trail.id = StringName("trail%d" % index)
		trail.loop = true
		trail.loop_period = 1.5
		trail.local_coords = false  # the points stay where the star left them, so they form an arc behind it
		trail.amount = 24
		trail.lifetime = 0.34
		trail.explosiveness = 0.0
		trail.emission_offset = Vector3(radius, height, 0.0)
		trail.speed_min = 0.0
		trail.speed_max = 0.0
		trail.gravity = Vector3.ZERO
		trail.size_min = 0.2
		trail.size_max = 0.2
		trail.size_curve = _curve([[0.0, 1.0], [1.0, 0.0]])
		trail.color = Color(1, 1, 1, 1)
		trail.color_ramp = _ramp([Color(1, 1, 1, 0.95), Color(1, 1, 1, 0.0)], [0.0, 1.0])
		trail.bindings = [_bind("process_material:color", &"trail_color")]
		trail.tracks = [spin, tilt]
		layers.append(trail)
	return _define(&"fx.stun_stars", "Stun stars", layers,
		[_param(&"color", FxParam.Kind.COLOR, Color.WHITE, "Tint of the stars (white keeps the sprite's own yellow)."),
		_param(&"trail_color", FxParam.Kind.COLOR, Color.WHITE, "Colour of the chaser trail.")],
		"Stars circling above a stunned unit, each chased by a white trail.", [&"Fx.Kind.Aura"], &"Top", true)


# --- Cue scenes --------------------------------------------------------------------------------------------------------

## A cue scene that plays `fx` with literal parameters. Persistent = a status's looping look (ends with the status), else a one-shot.
func _cue(file: String, fx: FxDefinition, literals: Dictionary, persistent: bool) -> void:
	var path := CUES + file + ".tscn"
	if (_only != "" and _only != file) or (FileAccess.file_exists(path) and not _force):
		_kept.append(path)
		return
	var cue := FxCueNotify.new()
	cue.name = file.to_pascal_case()
	cue.fx = fx
	cue.auto_destroy = not persistent
	cue.stop_fade = 0.4 if persistent else 0.25
	var bindings: Array[FxCueBinding] = []
	for param in literals:
		var binding := FxCueBinding.new()
		binding.param = StringName(param)
		binding.source = FxCueBinding.Source.LITERAL
		binding.value = literals[param]
		bindings.append(binding)
	cue.bindings = bindings
	var scene := PackedScene.new()
	scene.pack(cue)
	if ResourceSaver.save(scene, path) == OK:
		_written.append(path)


# --- Helpers ---------------------------------------------------------------------------------------------------------------

func _define(effect_id: StringName, title: String, layers: Array, params: Array, note: String, tags: Array, socket: StringName,
		biased: bool) -> FxDefinition:
	if biased:
		for layer in layers:
			if layer is FxParticles3DLayer:
				layer.bindings.append(_bind("draw_pass_1:material:shader_parameter/depth_bias", &"depth_bias"))
			elif layer is FxShaderQuadLayer:
				layer.bindings.append(_bind("material:shader_parameter/depth_bias", &"depth_bias"))
		params.append(_param(&"depth_bias", FxParam.Kind.FLOAT, 0.7, "Filled with the unit's radius unless the caller passes one.", 0.0, 4.0))
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
	if ResourceSaver.save(definition, path) != OK:
		push_error("build_vfx_status: cannot write %s" % path)
		return definition
	_written.append(path)
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as FxDefinition


func _add_to_registry(effects: Array[FxDefinition]) -> void:
	var path := OUT + "fx_registry.tres"
	var registry: FxRegistry = load(path) if FileAccess.file_exists(path) else FxRegistry.new()
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
