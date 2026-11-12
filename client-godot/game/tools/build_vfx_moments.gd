## Builds the last group of the content-pass effects (spec vfx-content-pass D5: battle moments): a unit's death, Broken (its look while it
## lasts, and the recovery), a boss phase shift, One More, the small pulse of a triggered passive, plus the cue scenes, the message rules
## (`moment_fx_rules.tres`: message becomes cue parameters, as in Lyra), the tag cues (`FxTagCue`: State.Broken, State.Downed, State.Dead) and
## the run-event flashes. New files only, into presentation/demo/fx/ and presentation/demo/cues/; never overwrites one (`--force` rewrites this
## set's own files, `--only <name>` just one). The cue registry entries are edited by hand (an existing design file).
##   godot --headless --path client-godot --quit-after 900 res://game/tools/build_vfx_moments.tscn [-- --force | --only <name>]
extends Node

const OUT: String = "res://presentation/demo/fx/"
const CUES: String = "res://presentation/demo/cues/"
const TEX: String = "res://presentation/demo/fx/textures/"
const SHADERS: String = "res://game/fx/shaders/"
const FONT: String = "res://presentation/demo/ui/fonts/"

## The pulse a triggered passive gives its unit, by the event that triggered it: cue suffix -> [event tag, colour].
const PROCS: Array = [
	["Crit", "Event.Damage.Dealt.Critical", Color(1.0, 0.82, 0.3)], ["Weakness", "Event.Damage.Dealt.Weakness", Color(0.7, 0.85, 1.0)],
	["Fire", "Event.Damage.Dealt.Fire", Color(1.0, 0.5, 0.2)], ["Ice", "Event.Damage.Dealt.Ice", Color(0.5, 0.9, 1.0)],
	["Break", "Event.Damage.Dealt.Break", Color(1.0, 1.0, 1.0)], ["Physical", "Event.Damage.Dealt.Physical", Color(0.9, 0.9, 0.95)],
	["Taken", "Event.Damage.Taken", Color(0.9, 0.35, 0.3)], ["Kill", "Event.Unit.Killed", Color(0.7, 0.4, 0.9)],
	["Ult", "Event.Ability.Used.Ultimate", Color(1.0, 0.95, 0.8)],
]

var _force: bool = false
var _only: String = ""
var _written := PackedStringArray()
var _kept := PackedStringArray()


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_force = args.has("--force") or args.has("--only")
	if args.has("--only") and args.find("--only") + 1 < args.size():
		_only = args[args.find("--only") + 1]
	var death := _save(_death_fade())
	var broken := _save(_broken_state())
	var recover := _save(_recover_flash())
	var phase := _save(_phase_shift())
	var one_more := _save(_one_more())
	var proc := _save(_proc_pulse())
	var absorb := _save(_drain_absorb())
	var skin := load(OUT + "status_skin.tres") as FxDefinition
	_cue("cue_death", death, {}, false)
	_cue("cue_state_broken", broken, {}, true)
	_cue("cue_recovered", recover, {}, false)
	_cue("cue_state_downed", skin, {"color": Color(0.8, 0.15, 0.2), "power": 1.8, "fill": 0.1, "grow": 0.01, "erosion": 0.5, "scroll": -0.9}, true)
	_cue("cue_phase_shift", phase, {}, false)
	_cue("cue_one_more", one_more, {}, false)
	for entry in PROCS:
		_cue("cue_proc_" + String(entry[0]).to_lower(), proc, {"color": entry[2]}, false)
	# A drained hit (the target heals instead of taking damage): the element it absorbed, by damage type.
	_cue("cue_drain_fire", absorb, {"color": Color(1.0, 0.45, 0.14)}, false)
	_cue("cue_drain_ice", absorb, {"color": Color(0.5, 0.9, 1.0)}, false)
	_cue("cue_drain_physical", absorb, {"color": Color(0.93, 0.93, 0.96)}, false)
	_save_rules()
	_save_tag_cues()
	_register([death, broken, recover, phase, one_more, proc, absorb])
	print("build_vfx_moments: wrote %d, kept %d existing" % [_written.size(), _kept.size()])
	for path in _written:
		print("  wrote ", path)
	for path in _kept:
		print("  kept  ", path)
	get_tree().quit()


# --- Effects ---------------------------------------------------------------------------------------------------------

## A unit falls: pale wisps and souls rise off it while its skin dissolves away.
func _death_fade() -> FxDefinition:
	var wisps := _particles("wisps", {"texture": load(TEX + "smoke_sheet.png"), "h_frames": 4, "v_frames": 4, "additive": false, "amount": 7, "lifetime": 1.5,
		"explosiveness": 0.4, "emission_radius": 0.4, "direction": Vector3.UP, "spread": 20.0, "speed_min": 0.5, "speed_max": 1.2, "gravity": Vector3(0, 0.3, 0),
		"size_min": 1.0, "size_max": 1.6, "soft_distance": 0.4})
	wisps.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)], [0.0, 0.2, 1.0])
	var souls := _particles("souls", {"amount": 24, "lifetime": 1.6, "explosiveness": 0.2, "emit_from_mesh": true, "direction": Vector3.UP, "spread": 15.0, "speed_min": 0.8,
		"speed_max": 2.4, "gravity": Vector3(0, 0.6, 0), "size_min": 0.07, "size_max": 0.15})
	souls.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.2, 1.0])
	return _define(&"fx.death_fade", "Death fade", [wisps, souls, _rim("dissolve", 0.0, 1.0, 0.3, 0.0, 0.5, 1.2)],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.8, 0.85, 1.0), "Soul colour.")], "Pale wisps and souls rise off a fallen unit while its skin dissolves.", &"Center")


## Broken: a cracked, shuddering shell and shards circling slowly, for as long as the unit is Broken.
func _broken_state() -> FxDefinition:
	var shell := _rim("shell", 0.0, 1.0, 0.1, 0.012, 0.65, 0.0)
	shell.loop = true
	shell.loop_period = 1.6
	shell.noise_scale = 9.0
	shell.power = 1.6
	shell.curve = _curve([[0.0, 0.8], [0.5, 1.0], [1.0, 0.8]])
	var spin := FxCurveTrack.new()
	spin.property = "rotation_degrees:y"
	spin.curve = _curve([[0.0, 0.0], [1.0, -360.0]], -360.0, 360.0)
	var shards := _particles("shards", {"loop": true, "loop_period": 3.0, "local_coords": true, "texture": load(TEX + "shard_sheet.png"), "h_frames": 4, "v_frames": 2,
		"anim_cycles": 0.0, "random_frame": true, "additive": false, "amount": 5, "lifetime": 3.0, "explosiveness": 0.0, "emission_ring_radius": 0.65,
		"emission_offset": Vector3(0, 0.1, 0), "gravity": Vector3.ZERO, "size_min": 0.28, "size_max": 0.38})
	shards.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.1, 0.9, 1.0])
	shards.tracks = [spin]
	return _define(&"fx.broken_state", "Broken", [shell, shards], [_param(&"color", FxParam.Kind.COLOR, Color(0.75, 0.92, 1.0), "Crack and shard colour.")],
		"A cracked, shuddering shell and shards circling slowly, while a unit is Broken.", &"Center")


## Recovery: a hex shield snaps back on for a moment with a ring and sparks.
func _recover_flash() -> FxDefinition:
	var material := ShaderMaterial.new()
	material.shader = load(SHADERS + "material/hex_shield.gdshader")
	var dome := FxMeshLayer.new()
	dome.id = &"dome"
	var sphere := SphereMesh.new()
	sphere.radius = 0.9
	sphere.height = 1.8
	dome.mesh = sphere
	dome.material = material
	dome.seconds = 0.6
	dome.bindings = [_bind("material_override:shader_parameter/color", &"color")]
	var presence := FxCurveTrack.new()
	presence.property = "material_override:shader_parameter/strength"
	presence.curve = _curve([[0.0, 0.0], [0.25, 1.0], [1.0, 0.0]])
	dome.tracks = [_scale_curve([[0.0, 1.3], [0.3, 1.0], [1.0, 1.05]]), presence]
	var sparks := _particles("sparks", {"amount": 22, "lifetime": 0.6, "emit_from_mesh": true, "spread": 180.0, "speed_min": 1.0, "speed_max": 3.0, "damping": 2.0,
		"size_min": 0.06, "size_max": 0.12})
	sparks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	return _define(&"fx.recover_flash", "Recovery", [dome, _ring("ring", 0.0, 2.6, 0.45, true), sparks],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.7, 0.9, 1.0), "Shield colour.")], "A hex shield snaps back on for a moment, with a ring and sparks.", &"Center")


## A boss changes phase: three huge rings, red rays, a screen flash and a hard shake.
func _phase_shift() -> FxDefinition:
	var layers: Array = []
	for index in 3:
		var ring := _flat_ring("surge%d" % index, 0.15 * index, 6.5 + 1.4 * index, 0.8)
		ring.shader_params = {"ring_width": 0.1, "start_radius": 0.1, "end_radius": 0.95, "intensity": 1.8}
		layers.append(ring)
	var rays := _quad("rays", "rays_3d", Vector2(7.0, 7.0), 0.9)
	rays.shader_params = {"ray_count": 18.0, "spin": 0.05, "fade_out": 0.6}
	rays.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.2)]
	layers.append(rays)
	layers.append(_sub("flash", 0.05, "screen_flash", {"color": "$color", "intensity": 0.9}))
	layers.append(_rim("roar", 0.0, 0.9, 0.35, 0.02, 0.3, 1.5))
	layers.append(_shake(0.0, 0.55, 0.13))
	layers.append(_light(0.0, 5.0, 0.8))
	return _define(&"fx.phase_shift", "Phase shift", layers,
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.25, 0.3), "Roar colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Ray brightness.", 0.0, 4.0)],
		"A boss changes phase: three huge rings, red rays, a screen flash and a hard shake.", &"Base")


## One More: "ONE MORE!" pops over the unit with a burst of rays and sparks.
func _one_more() -> FxDefinition:
	var text := FxTextLayer.new()
	text.id = &"text"
	text.text = "ONE MORE!"
	text.font_size = 64  # the same size as a crit's number
	text.outline_size = 15
	text.color = Color(1.0, 0.22, 0.3)
	text.outline_color = Color(1.0, 1.0, 1.0)
	text.height = 0.5
	text.rise = 0.4
	text.scatter = 0.0
	text.scatter_y = 0.0
	text.seconds = 1.2
	text.pop_scale = 2.6
	text.pop_share = 0.14
	var font_path := FONT + "ChakraPetch-Bold.ttf"
	if ResourceLoader.exists(font_path):
		text.font = load(font_path)
	var rays := _quad("rays", "rays_3d", Vector2(4.4, 4.4), 0.55)
	rays.shader_params = {"ray_count": 16.0, "spin": 0.15, "fade_out": 0.7}
	rays.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.2)]
	var sparks := _particles("sparks", {"amount": 30, "lifetime": 0.7, "explosiveness": 1.0, "spread": 180.0, "speed_min": 2.5, "speed_max": 6.0, "damping": 1.5,
		"size_min": 0.07, "size_max": 0.14})
	sparks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	return _define(&"fx.one_more", "One More", [rays, text, sparks],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.45, 0.35), "Ray and spark colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Ray brightness.", 0.0, 4.0)],
		"ONE MORE! pops over the unit with a burst of rays and sparks.", &"Top", false)


## The small pulse of a triggered passive: a ring, a few motes and a flash, in the colour of what triggered it.
func _proc_pulse() -> FxDefinition:
	var motes := _particles("motes", {"amount": 12, "lifetime": 0.6, "explosiveness": 0.9, "spread": 180.0, "speed_min": 0.8, "speed_max": 2.2, "damping": 1.5,
		"size_min": 0.06, "size_max": 0.12})
	motes.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	return _define(&"fx.proc_pulse", "Passive proc", [_ring("ring", 0.0, 1.9, 0.35, true), motes, _rim("flash", 0.0, 0.25, 0.2, 0.0, 0.0, 0.0)],
		[_param(&"color", FxParam.Kind.COLOR, Color(1, 1, 1), "The triggering event's colour.")], "A small pulse on a unit whose passive triggered.", &"Center")


## A drained hit: the element streams into the unit, a ring closes in, and "ABSORB" floats up. The unit heals instead of taking damage.
func _drain_absorb() -> FxDefinition:
	var pull := _particles("pull", {"amount": 36, "lifetime": 0.7, "explosiveness": 0.15, "emission_radius": 1.6, "radial_accel": -13.0, "gravity": Vector3.ZERO,
		"size_min": 0.08, "size_max": 0.17})
	pull.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.9)], [0.0, 0.3, 1.0])
	var closing := _ring("closing", 0.0, 3.6, 0.5, true)
	closing.shader_params = {"ring_width": 0.08, "start_radius": 0.95, "end_radius": 0.15, "intensity": 1.5}
	var pulse := _quad("pulse", "glow_3d", Vector2(2.2, 2.2), 0.45)
	pulse.start_delay = 0.3
	pulse.shader_params = {"falloff": 3.0, "fade_out": 0.7}
	pulse.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.5)]
	var label := FxTextLayer.new()
	label.id = &"label"
	label.text = "ABSORB"
	label.font_size = 40
	label.outline_size = 9
	label.outline_color = Color(0.05, 0.05, 0.08)
	label.height = 0.45
	label.rise = 0.35
	label.scatter = 0.0
	label.scatter_y = 0.0
	label.seconds = 1.0
	label.bindings = [_bind("modulate", &"color")]
	var font_path := FONT + "ChakraPetch-Bold.ttf"
	if ResourceLoader.exists(font_path):
		label.font = load(font_path)
	return _define(&"fx.drain_absorb", "Drain absorb", [pull, closing, pulse, _rim("glow", 0.2, 0.7, 0.25, 0.015, 0.0, 0.0), label],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.45, 0.14), "The absorbed element's colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Pulse brightness.", 0.0, 4.0)],
		"The element streams into a unit that absorbs it, a ring closes in, and ABSORB floats up.", &"Center")


# --- Rules and tag cues ----------------------------------------------------------------------------------------------------------

## Message -> cue rules (Lyra's way) and the run events' screen flashes.
func _save_rules() -> void:
	var path := OUT + "moment_fx_rules.tres"
	if (_only != "" and _only != "moment_fx_rules") or (FileAccess.file_exists(path) and not _force):
		_kept.append(path)
		return
	var rules := FxRuleSet.new()
	rules.rules.append(_cue_rule(GameplayMessageRouter.BATTLE_PHASE, &"Cue.Fx.PhaseShift", [], FxListener.AnchorRule.TARGET_UNIT))
	rules.rules.append(_cue_rule(GameplayMessageRouter.BATTLE_ONE_MORE, &"Cue.Fx.OneMore", [], FxListener.AnchorRule.TARGET_UNIT))
	for entry in PROCS:
		rules.rules.append(_cue_rule(GameplayMessageRouter.BATTLE_TRIGGER, StringName("Cue.Fx.Proc." + entry[0]), [StringName(entry[1])], FxListener.AnchorRule.TARGET_UNIT))
	# A drained hit: the target absorbs the element (by damage type).
	for entry in [["Damage.Type.Fire", &"Cue.Fx.Drain.Fire"], ["Damage.Type.Ice", &"Cue.Fx.Drain.Ice"], ["Damage.Type.Physical", &"Cue.Fx.Drain.Physical"]]:
		rules.rules.append(_cue_rule(GameplayMessageRouter.BATTLE_DRAINED, entry[1], [StringName(entry[0])], FxListener.AnchorRule.TARGET_UNIT))
	# A status roll that missed: "RESIST" over the unit, in the damage number's own effect.
	var resist := FxListener.new()
	resist.channel = GameplayMessageRouter.BATTLE_RESISTED
	resist.effect = load(OUT + "damage_number.tres")
	resist.anchor_rule = FxListener.AnchorRule.TARGET_UNIT
	resist.params = {"text": "RESIST", "color": Color(0.75, 0.75, 0.82), "font_size": 64}
	rules.rules.append(resist)
	# Run events: a flash over the screen (the run's screens are 2D, so there is no unit to put an effect on).
	for entry in [[GameplayMessageRouter.RUN_LEVEL_UP, Color(1.0, 0.85, 0.3), 1.2], [GameplayMessageRouter.RUN_SKILL_LEARNED, Color(0.7, 0.5, 1.0), 0.9],
			[GameplayMessageRouter.RUN_CHEST_OPENED, Color(1.0, 0.8, 0.35), 0.8], [GameplayMessageRouter.RUN_KEY_FOUND, Color(1.0, 0.95, 0.7), 0.5],
			[GameplayMessageRouter.RUN_FLOOR_ENTERED, Color(1.0, 1.0, 1.0), 0.3]]:
		var flash := FxListener.new()
		flash.channel = entry[0]
		flash.effect = load(OUT + "screen_flash.tres")
		flash.anchor_rule = FxListener.AnchorRule.SCREEN
		flash.params = {"color": entry[1], "intensity": entry[2]}
		rules.rules.append(flash)
	if BuilderSave.save(rules, path) == OK:
		_written.append(path)


func _cue_rule(channel: StringName, cue: StringName, require: Array, anchor: FxListener.AnchorRule) -> FxListener:
	var rule := FxListener.new()
	rule.channel = channel
	rule.cue = cue
	rule.anchor_rule = anchor
	rule.require_tags.assign(require)
	return rule


## The tag cues live in the registry (FxRegistry.tag_cues).
func _save_tag_cues() -> void:
	var path := OUT + "fx_registry.tres"
	var registry: FxRegistry = load(path)
	var wanted := [[&"State.Broken", &"Cue.Fx.Break", &"Cue.Fx.State.Broken", &"Cue.Fx.Recovered"], [&"State.Downed", &"", &"Cue.Fx.State.Downed", &""],
		[&"State.Dead", &"Cue.Fx.Death", &"", &""]]
	var missing := PackedStringArray()
	for entry in wanted:
		var present := false
		for existing in registry.tag_cues:
			if existing is FxTagCue and existing.tag == entry[0]:
				present = true
		if not present:
			missing.append("%s (added %s, present %s, removed %s)" % [entry[0], entry[1], entry[2], entry[3]])
	if not missing.is_empty():
		# The registry is a design file: a builder never rewrites it. These tag cues are added by hand (an Edit the owner approves).
		print("  REGISTRY NOT CHANGED (the file is the owner's). Add tag cues by hand: %s" % ", ".join(missing))


# --- Cue scenes and registry ------------------------------------------------------------------------------------------------------

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
	var rules := load(OUT + "moment_fx_rules.tres")
	if rules != null and not registry.rule_sets.has(rules):
		missing.append("rule set moment_fx_rules.tres")
		changed = true
	if changed:
		# Additive text patch only (user, 2026-11-09): new entries appended, nothing existing touched, RegistryPatch prints what it added.
		for line in RegistryPatch.add_missing_effects():
			print("  registry: ", line)


# --- Helpers ---------------------------------------------------------------------------------------------------------------------

func _particles(layer_id: StringName, props: Dictionary) -> FxParticles3DLayer:
	var layer := FxParticles3DLayer.new()
	layer.id = layer_id
	layer.amount = 20
	layer.lifetime = 0.8
	layer.speed_min = 0.0
	layer.speed_max = 0.0
	layer.gravity = Vector3.ZERO
	for key in props:
		layer.set(key, props[key])
	layer.bindings = [_bind("process_material:color", &"color")]
	return layer


func _quad(layer_id: StringName, shader_name: String, size: Vector2, seconds: float) -> FxShaderQuadLayer:
	var quad := FxShaderQuadLayer.new()
	quad.id = layer_id
	quad.space = FxLayer.Space.WORLD_3D
	quad.shader = load(SHADERS + shader_name + ".gdshader")
	quad.size = size
	quad.duration = seconds
	return quad


func _ring(layer_id: StringName, delay: float, size: float, seconds: float, bound: bool) -> FxShaderQuadLayer:
	var ring := _quad(layer_id, "burst_3d", Vector2(size, size), seconds)
	ring.start_delay = delay
	ring.shader_params = {"ring_width": 0.07, "start_radius": 0.15, "end_radius": 0.95, "intensity": 1.6}
	if bound:
		ring.bindings = [_bind("material:shader_parameter/color", &"color")]
	return ring


func _flat_ring(layer_id: StringName, delay: float, size: float, seconds: float) -> FxShaderQuadLayer:
	var ring := _quad(layer_id, "burst_3d", Vector2(size, size), seconds)
	ring.socket = &"Base"
	ring.face_camera = false
	ring.start_delay = delay
	ring.shader_params = {"ring_width": 0.07, "start_radius": 0.2, "end_radius": 0.95, "intensity": 1.6}
	ring.bindings = [_bind("material:shader_parameter/color", &"color")]
	ring.tracks = [_slide("rotation_degrees:x", -90.0, -90.0, 360.0)]
	return ring


func _rim(layer_id: StringName, delay: float, seconds: float, fill: float, grow: float, erosion: float, scroll: float) -> FxFresnelLayer:
	var rim := FxFresnelLayer.new()
	rim.id = layer_id
	rim.start_delay = delay
	rim.seconds = seconds
	rim.power = 2.0
	rim.fill = fill
	rim.grow = grow
	rim.erosion = erosion
	rim.scroll = scroll
	rim.noise_scale = 5.0
	rim.intensity = 1.3
	rim.bindings = [_bind("color", &"color")]
	return rim


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


func _shake(delay: float, seconds: float, strength: float) -> FxShakeLayer:
	var shake := FxShakeLayer.new()
	shake.id = StringName("shake%d" % int(delay * 100.0))
	shake.start_delay = delay
	shake.min_quality = FxLayer.Quality.MEDIUM
	shake.seconds = seconds
	shake.strength_world = strength
	return shake


func _sub(layer_id: StringName, delay: float, effect_file: String, param_map: Dictionary) -> FxSubFxLayer:
	var sub := FxSubFxLayer.new()
	sub.id = layer_id
	sub.start_delay = delay
	sub.effect = load(OUT + effect_file + ".tres")
	sub.param_map = param_map
	return sub


func _curve(points: Array, low: float = 0.0, high: float = 1.0) -> Curve:
	var curve := Curve.new()
	curve.min_value = low
	curve.max_value = high
	for point in points:
		curve.add_point(Vector2(point[0], point[1]))
	return curve


func _slide(property: String, from: float, to: float, bound: float = 8.0) -> FxCurveTrack:
	var track := FxCurveTrack.new()
	track.property = property
	track.mode = FxCurveTrack.Mode.ADD
	track.curve = _curve([[0.0, from], [1.0, to]], -bound, bound)
	return track


func _scale_curve(points: Array) -> FxCurveTrack:
	var track := FxCurveTrack.new()
	track.property = "scale"
	track.mode = FxCurveTrack.Mode.MULTIPLY
	track.curve = _curve(points, 0.0, 8.0)
	return track


func _define(effect_id: StringName, title: String, layers: Array, params: Array, note: String, socket: StringName, _biased: bool = true) -> FxDefinition:
	var definition := FxDefinition.new()
	definition.id = effect_id
	definition.display_name = title
	definition.space = FxDefinition.Space.WORLD_3D
	definition.layers.assign(layers)
	definition.params.assign(params)
	definition.description = note
	definition.tags.assign([&"Fx.Kind.Burst"])
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
		push_error("build_vfx_moments: cannot write %s" % path)
		return definition
	_written.append(path)
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as FxDefinition
