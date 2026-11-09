## Builds the proof set of effects (spec vfx-framework 1, item 6) with ResourceSaver: the card and UI effects, the combat
## effects, the four cue scenes and the registry. Writes into presentation/demo/fx/ and presentation/demo/cues/ only and
## never overwrites an existing file (like build_demo and build_animation_sets); `--force` rewrites this set's own files,
## which discards tuning, so use it only on files you have not touched. Run once with the user's go-ahead; afterwards the
## files are theirs to tune in the inspector. Shaders are the framework's library in game/fx/shaders/.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_fx_set.tscn [-- --force | --registry-only]
extends Node

const OUT: String = "res://presentation/demo/fx/"
const CUES: String = "res://presentation/demo/cues/"
const SHADERS: String = "res://game/fx/shaders/"
const GOLD := Color(1.0, 0.78, 0.25)

var _force: bool = false
## Rewrites only fx_registry.tres, pointing it at the effect files as they are (tuning kept).
var _registry_only: bool = false
var _written := PackedStringArray()
var _kept := PackedStringArray()


func _ready() -> void:
	_force = OS.get_cmdline_user_args().has("--force")
	_registry_only = OS.get_cmdline_user_args().has("--registry-only")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CUES))
	var screen_flash := _save_definition(_screen_flash())
	var definitions: Array[FxDefinition] = [
		_card_glow(), _card_hover(), _card_flip_flash(), _card_dust(), _pack_burst(), _legendary_rays(screen_flash),
		_screen_shake(), screen_flash, _hit_spark(), _heal_glow(), _break_shatter(), _status_aura()]
	var registry := FxRegistry.new()
	for definition in definitions:
		registry.definitions.append(_save_definition(definition))
	var registry_path := OUT + "fx_registry.tres"
	if _force or _registry_only or not FileAccess.file_exists(registry_path):
		ResourceSaver.save(registry, registry_path)
		_written.append(registry_path)
	else:
		_kept.append(registry_path + " (exists: add any new effect to it by hand)")
	_save_cue("hit_spark_cue", "fx.hit_spark", Vector3(0, 0.45, 0), true, 0.25)
	_save_cue("heal_cue", "fx.heal_glow", Vector3(0, 0.1, 0), true, 0.25)
	_save_cue("break_cue", "fx.break_shatter", Vector3(0, 0.4, 0), true, 0.25)
	_save_cue("status_aura_cue", "fx.status_aura", Vector3(0, 0.2, 0), false, 0.4)
	print("build_fx_set: wrote %d, kept %d existing" % [_written.size(), _kept.size()])
	for path in _written:
		print("  wrote ", path)
	for path in _kept:
		print("  kept  ", path)
	get_tree().quit()


# --- Card and UI effects ---------------------------------------------------------------------------------------------

## A looping rarity aura: a pulsing glow around the card and sparkles drifting up from it.
func _card_glow() -> FxDefinition:
	var glow := _quad("glow", "glow_aura", false)
	glow.loop = true
	glow.loop_period = 4.0
	glow.grow = 44.0
	glow.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity"),
		_bind("material:shader_parameter/pulse_speed", &"pulse")]
	var sparkles := FxParticles2DLayer.new()
	sparkles.id = &"sparkles"
	sparkles.loop = true
	sparkles.min_quality = FxLayer.Quality.MEDIUM
	sparkles.amount = 14
	sparkles.lifetime = 1.8
	sparkles.explosiveness = 0.0
	sparkles.fit_to_anchor = true
	sparkles.direction = Vector3(0, -1, 0)
	sparkles.spread = 25.0
	sparkles.speed_min = 12.0
	sparkles.speed_max = 40.0
	sparkles.gravity = Vector3(0, -10, 0)
	sparkles.size_min = 0.1
	sparkles.size_max = 0.28
	sparkles.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.3, 1.0])
	sparkles.bindings = [_bind("process_material:color", &"color")]
	return _define(&"fx.card_glow", "Card glow", FxDefinition.Space.UI, [glow, sparkles],
		[_param(&"color", FxParam.Kind.COLOR, GOLD, 0, 0, "Rarity colour of the aura."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Brightness of the glow."),
		_param(&"pulse", FxParam.Kind.FLOAT, 1.5, 0.0, 6.0, "Pulses per second.")],
		"Looping rarity aura for a card (start it on hover, a reveal or the collection). Stop it with a fade.", [&"Fx.Kind.Aura"])


## Hover feedback: a bright outline and a soft glow, looping while the pointer is on the card.
func _card_hover() -> FxDefinition:
	var outline := _quad("outline", "outline", false)
	outline.loop = true
	outline.loop_period = 3.0
	outline.grow = 10.0
	outline.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity")]
	var glow := _quad("glow", "glow_aura", false)
	glow.loop = true
	glow.loop_period = 3.0
	glow.grow = 26.0
	glow.shader_params = {"intensity": 0.5, "falloff": 0.14}
	glow.bindings = [_bind("material:shader_parameter/color", &"color")]
	return _define(&"fx.card_hover", "Card hover", FxDefinition.Space.UI, [outline, glow],
		[_param(&"color", FxParam.Kind.COLOR, Color(1, 0.95, 0.7), 0, 0, "Outline and glow colour."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Brightness of the outline.")],
		"Outline and soft glow while the pointer is over a card.", [&"Fx.Kind.Aura"])


## A card turns face up: a shockwave ring from its middle and a small scale punch. Set the card's pivot to its centre.
func _card_flip_flash() -> FxDefinition:
	var burst := _quad("burst", "radial_burst", false)
	burst.size = Vector2(560, 560)
	burst.duration = 0.55
	burst.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity")]
	var punch := FxTweenLayer.new()
	punch.id = &"punch"
	punch.seconds = 0.3
	punch.tracks = [_track("scale", _curve([[0.0, 1.0], [0.4, 1.1], [1.0, 1.0]], 0.0, 1.5), FxCurveTrack.Mode.MULTIPLY)]
	return _define(&"fx.card_flip_flash", "Card flip flash", FxDefinition.Space.UI, [burst, punch],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.92, 0.7), 0, 0, "Flash colour (the card's rarity)."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Brightness.")],
		"The flash when a card flips face up.", [&"Fx.Kind.Burst"])


## A card dissolves into dust: grey-blue motes rise from it while it fades. The caller removes the card afterwards.
func _card_dust() -> FxDefinition:
	var dust := FxParticles2DLayer.new()
	dust.id = &"dust"
	dust.amount = 48
	dust.lifetime = 1.1
	dust.explosiveness = 0.25
	dust.fit_to_anchor = true
	dust.direction = Vector3(0, -1, 0)
	dust.spread = 40.0
	dust.speed_min = 20.0
	dust.speed_max = 90.0
	dust.gravity = Vector3(0, -30, 0)
	dust.size_min = 0.08
	dust.size_max = 0.3
	dust.additive = false
	dust.color_ramp = _ramp([Color(1, 1, 1, 0.9), Color(1, 1, 1, 0)], [0.0, 1.0])
	dust.bindings = [_bind("process_material:color", &"color")]
	var fade := FxTweenLayer.new()
	fade.id = &"fade"
	fade.seconds = 1.0
	fade.tracks = [_track("modulate", _curve([[0.0, 1.0], [1.0, 0.0]]), FxCurveTrack.Mode.MULTIPLY)]
	return _define(&"fx.card_dust", "Card dust", FxDefinition.Space.UI, [dust, fade],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.75, 0.8, 0.95), 0, 0, "Colour of the dust.")],
		"A card turns to dust (the dust action). The card fades; remove it when the effect ends.", [&"Fx.Kind.Burst"])


## The pack bursts open: 3D sparks, glow and light on the pack, a 2D shockwave, and a shake. For a hybrid stage.
func _pack_burst() -> FxDefinition:
	var sparks := FxParticles3DLayer.new()
	sparks.id = &"sparks"
	sparks.amount = 70
	sparks.lifetime = 1.1
	sparks.speed_min = 3.0
	sparks.speed_max = 8.0
	sparks.gravity = Vector3(0, -3, 0)
	sparks.size_min = 0.05
	sparks.size_max = 0.16
	sparks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0.8), Color(1, 1, 1, 0)], [0.0, 0.5, 1.0])
	sparks.bindings = [_bind("process_material:color", &"color"), _bind("amount", &"count")]
	var glow := _quad("glow", "glow_3d", true)
	glow.size = Vector2(3.4, 3.4)
	glow.duration = 0.7
	glow.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.5)]
	var light := FxLightLayer.new()
	light.id = &"light"
	light.energy = 4.0
	light.light_range = 8.0
	light.seconds = 0.6
	light.bindings = [_bind("light_color", &"color")]
	var ring := _quad("ring", "radial_burst", false)
	ring.size = Vector2(900, 900)
	ring.duration = 0.9
	ring.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity")]
	var shake := FxShakeLayer.new()
	shake.id = &"shake"
	shake.seconds = 0.45
	shake.strength_px = 0.0
	shake.strength_world = 0.0
	shake.bindings = [_bind("strength_px", &"shake", 16.0), _bind("strength_world", &"shake", 0.1)]
	return _define(&"fx.pack_burst", "Pack burst", FxDefinition.Space.HYBRID, [sparks, glow, light, ring, shake],
		[_param(&"color", FxParam.Kind.COLOR, GOLD, 0, 0, "Colour of the burst."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Brightness."),
		_param(&"count", FxParam.Kind.INT, 70, 10, 200, "Number of sparks."),
		_param(&"shake", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Shake strength (0 = none).")],
		"A pack bursts open on a hybrid stage (3D sparks, glow and light, 2D shockwave, shake).", [&"Fx.Kind.Burst"])


## The big reveal for a Legendary: rays, a burst of motes and a screen flash.
func _legendary_rays(screen_flash: FxDefinition) -> FxDefinition:
	var rays := _quad("rays", "rays", false)
	rays.size = Vector2(1000, 1000)
	rays.duration = 2.2
	rays.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity")]
	var motes := FxParticles2DLayer.new()
	motes.id = &"motes"
	motes.min_quality = FxLayer.Quality.MEDIUM
	motes.amount = 50
	motes.lifetime = 1.6
	motes.speed_min = 120.0
	motes.speed_max = 380.0
	motes.gravity = Vector3(0, 40, 0)
	motes.size_min = 0.1
	motes.size_max = 0.34
	motes.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	motes.bindings = [_bind("process_material:color", &"color")]
	var flash := FxSubFxLayer.new()
	flash.id = &"flash"
	flash.effect = screen_flash
	flash.param_map = {"color": "$color", "intensity": 0.8}
	return _define(&"fx.legendary_rays", "Legendary rays", FxDefinition.Space.HYBRID, [rays, motes, flash],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.7, 0.2), 0, 0, "Colour of the rays."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Brightness.")],
		"Rays, motes and a screen flash for a Legendary reveal.", [&"Fx.Kind.Burst"])


func _screen_shake() -> FxDefinition:
	var shake := FxShakeLayer.new()
	shake.id = &"shake"
	shake.seconds = 0.4
	shake.strength_px = 0.0
	shake.strength_world = 0.0
	shake.bindings = [_bind("strength_px", &"strength", 12.0), _bind("strength_world", &"strength", 0.1)]
	return _define(&"fx.screen_shake", "Screen shake", FxDefinition.Space.SCREEN, [shake],
		[_param(&"strength", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "1 = a firm shake.")],
		"Shakes the window and the 3D camera.", [&"Fx.Kind.Shake"])


func _screen_flash() -> FxDefinition:
	var flash := _quad("flash", "vignette_flash", false)
	flash.duration = 0.6
	flash.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity")]
	return _define(&"fx.screen_flash", "Screen flash", FxDefinition.Space.SCREEN, [flash],
		[_param(&"color", FxParam.Kind.COLOR, Color.WHITE, 0, 0, "Colour of the flash."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Brightness.")],
		"The edges of the screen flare and fade.", [&"Fx.Kind.Flash"])


# --- Combat effects ---------------------------------------------------------------------------------------------------

func _hit_spark() -> FxDefinition:
	var sparks := FxParticles3DLayer.new()
	sparks.id = &"sparks"
	sparks.amount = 20
	sparks.lifetime = 0.4
	sparks.speed_min = 2.5
	sparks.speed_max = 6.0
	sparks.gravity = Vector3(0, -6, 0)
	sparks.size_min = 0.14
	sparks.size_max = 0.3
	sparks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	sparks.bindings = [_bind("process_material:color", &"color")]
	var glow := _quad("glow", "glow_3d", true)
	glow.size = Vector2(1.8, 1.8)
	glow.duration = 0.25
	glow.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.4)]
	var light := FxLightLayer.new()
	light.id = &"light"
	light.min_quality = FxLayer.Quality.MEDIUM
	light.energy = 2.2
	light.light_range = 3.5
	light.seconds = 0.18
	light.bindings = [_bind("light_color", &"color")]
	var flash := FxMeshFlashLayer.new()
	flash.id = &"flash"
	flash.seconds = 0.16
	flash.bindings = [_bind("color", &"color"), _bind("intensity", &"intensity", 0.6)]
	return _define(&"fx.hit_spark", "Hit spark", FxDefinition.Space.WORLD_3D, [sparks, glow, light, flash],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.85, 0.5), 0, 0, "Colour of the sparks (the damage type)."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Brightness.")],
		"Sparks, a flash and a light on a unit that was hit.", [&"Fx.Kind.Hit"])


func _heal_glow() -> FxDefinition:
	var motes := FxParticles3DLayer.new()
	motes.id = &"motes"
	motes.amount = 22
	motes.lifetime = 1.0
	motes.explosiveness = 0.3
	motes.direction = Vector3.UP
	motes.spread = 40.0
	motes.speed_min = 0.8
	motes.speed_max = 1.8
	motes.gravity = Vector3(0, 0.8, 0)
	motes.emission_radius = 0.4
	motes.size_min = 0.16
	motes.size_max = 0.32
	motes.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.3, 1.0])
	motes.bindings = [_bind("process_material:color", &"color")]
	var glow := _quad("glow", "glow_3d", true)
	glow.size = Vector2(2.2, 2.2)
	glow.duration = 1.0
	glow.shader_params = {"falloff": 3.0, "fade_out": 0.7}
	glow.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity")]
	var light := FxLightLayer.new()
	light.id = &"light"
	light.min_quality = FxLayer.Quality.MEDIUM
	light.energy = 1.5
	light.light_range = 4.0
	light.seconds = 0.9
	light.bindings = [_bind("light_color", &"color")]
	return _define(&"fx.heal_glow", "Heal glow", FxDefinition.Space.WORLD_3D, [motes, glow, light],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.45, 1.0, 0.55), 0, 0, "Colour of the heal."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Brightness.")],
		"Green motes rise around a unit that was healed.", [&"Fx.Kind.Heal"])


func _break_shatter() -> FxDefinition:
	var ring := _quad("ring", "burst_3d", true)
	ring.size = Vector2(3.4, 3.4)
	ring.duration = 0.5
	ring.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.0)]
	var shards := FxParticles3DLayer.new()
	shards.id = &"shards"
	shards.amount = 28
	shards.lifetime = 0.7
	shards.speed_min = 3.0
	shards.speed_max = 7.0
	shards.gravity = Vector3(0, -9, 0)
	shards.size_min = 0.12
	shards.size_max = 0.26
	shards.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	shards.bindings = [_bind("process_material:color", &"color")]
	var shake := FxShakeLayer.new()
	shake.id = &"shake"
	shake.min_quality = FxLayer.Quality.MEDIUM
	shake.seconds = 0.3
	shake.strength_world = 0.06
	var flash := FxMeshFlashLayer.new()
	flash.id = &"flash"
	flash.seconds = 0.25
	flash.bindings = [_bind("color", &"color")]
	return _define(&"fx.break_shatter", "Break shatter", FxDefinition.Space.WORLD_3D, [ring, shards, shake, flash],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.8, 0.95, 1.0), 0, 0, "Colour of the shards."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Brightness.")],
		"A shockwave ring, shards and a little camera shake when a unit's toughness breaks.", [&"Fx.Kind.Break"])


## A looping status aura: motes rising round the unit and a slow glow. Persistent cues stop it with a fade.
func _status_aura() -> FxDefinition:
	var motes := FxParticles3DLayer.new()
	motes.id = &"motes"
	motes.loop = true
	motes.amount = 16
	motes.lifetime = 1.2
	motes.explosiveness = 0.0
	motes.direction = Vector3.UP
	motes.spread = 30.0
	motes.speed_min = 0.4
	motes.speed_max = 1.0
	motes.gravity = Vector3.ZERO
	motes.emission_radius = 0.45
	motes.size_min = 0.14
	motes.size_max = 0.28
	motes.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.3, 1.0])
	motes.bindings = [_bind("process_material:color", &"color")]
	var glow := _quad("glow", "glow_3d", true)
	glow.loop = true
	glow.loop_period = 2.0
	glow.size = Vector2(1.8, 1.8)
	glow.shader_params = {"fade_out": 0.0, "pulse_speed": 0.5, "pulse_amount": 0.3}
	glow.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity")]
	return _define(&"fx.status_aura", "Status aura", FxDefinition.Space.WORLD_3D, [motes, glow],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.45, 0.2), 0, 0, "Colour of the status."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.4, 0.0, 4.0, "Brightness.")],
		"A looping aura for a status effect on a unit.", [&"Fx.Kind.Aura"])


# --- Helpers ---------------------------------------------------------------------------------------------------------

func _define(effect_id: StringName, title: String, space: FxDefinition.Space, layers: Array, params: Array, note: String, tags: Array) -> FxDefinition:
	var definition := FxDefinition.new()
	definition.id = effect_id
	definition.display_name = title
	definition.space = space
	definition.layers.assign(layers)
	definition.params.assign(params)
	definition.description = note
	definition.tags.assign(tags)
	return definition


func _param(param_name: StringName, kind: FxParam.Kind, default: Variant, low: float, high: float, note: String) -> FxParam:
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


func _track(property: String, curve: Curve, mode: FxCurveTrack.Mode) -> FxCurveTrack:
	var track := FxCurveTrack.new()
	track.property = property
	track.curve = curve
	track.mode = mode
	return track


func _curve(points: Array, low: float = 0.0, high: float = 1.0) -> Curve:
	var curve := Curve.new()
	curve.min_value = low
	curve.max_value = high
	for point in points:
		curve.add_point(Vector2(point[0], point[1]))
	return curve


func _ramp(colors: Array, offsets: Array) -> Gradient:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array(offsets)
	gradient.colors = PackedColorArray(colors)
	return gradient


## A shader quad with a library shader. `in_3d` makes it a camera-facing quad in the world instead of a UI rectangle.
func _quad(layer_id: StringName, shader_name: String, in_3d: bool) -> FxShaderQuadLayer:
	var quad := FxShaderQuadLayer.new()
	quad.id = layer_id
	quad.shader = load(SHADERS + shader_name + ".gdshader")
	if in_3d:
		quad.space = FxLayer.Space.WORLD_3D
	return quad


func _save_definition(definition: FxDefinition) -> FxDefinition:
	if definition.resource_path != "" and not definition.resource_path.contains("::"):
		return definition  # already saved (the screen flash is saved first: the legendary reveal plays it)
	var path := OUT + String(definition.id).trim_prefix("fx.") + ".tres"
	if FileAccess.file_exists(path) and (not _force or _registry_only):
		_kept.append(path)
		return load(path)
	var error := ResourceSaver.save(definition, path)
	if error != OK:
		push_error("build_fx_set: cannot write %s (%s)" % [path, error_string(error)])
		return definition
	_written.append(path)
	# The registry and the cue scenes must point at the file, not hold a copy: load the saved resource (a fresh one,
	# bound to its path) and use that one.
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as FxDefinition


func _save_cue(file: String, effect_id: String, offset: Vector3, one_shot: bool, fade: float) -> void:
	var path := CUES + file + ".tscn"
	if FileAccess.file_exists(path) and not _force:
		_kept.append(path)
		return
	var cue := FxCueNotify.new()
	cue.name = file.to_pascal_case()
	cue.fx = load(OUT + effect_id.trim_prefix("fx.") + ".tres")
	cue.offset = offset
	cue.auto_destroy = one_shot
	cue.stop_fade = fade
	var scene := PackedScene.new()
	scene.pack(cue)
	if ResourceSaver.save(scene, path) == OK:
		_written.append(path)
	cue.free()
