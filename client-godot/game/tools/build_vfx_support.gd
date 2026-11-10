## Builds the buff, debuff and support group of the content-pass effects (spec vfx-content-pass D5, group 3): the stat arrows (a looping
## look for a stat buff or debuff, and a one-shot on apply), the revive and cleanse effects, the caster's cast ring, the cue scenes the
## status effects name, and the support rule set (heal glow, revive, cast rings by ability role). New files only, into
## presentation/demo/fx/ and presentation/demo/cues/; never overwrites one (`--force` rewrites this set's own files, `--only <name>` just
## one). The status effects' cue tags and the cue registry entries are edited by hand (existing design files).
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_vfx_support.tscn [-- --force | --only <name>]
extends Node

const OUT: String = "res://presentation/demo/fx/"
const CUES: String = "res://presentation/demo/cues/"
const TEX: String = "res://presentation/demo/fx/textures/"
const SHADERS: String = "res://game/fx/shaders/"

const UP := Vector3(0, 1.1, 0)
const DOWN := Vector3(0, -1.1, 0)
const DOWN_START := Vector3(0, 0.5, 0)
const HEAL := Color(0.45, 1.0, 0.55)
const GOLD := Color(1.0, 0.85, 0.35)
const WHITE_GOLD := Color(1.0, 0.95, 0.7)
const PURPLE := Color(0.7, 0.4, 0.9)

## The persistent looks: tag suffix (Cue.Fx.<suffix>) -> [effect, literal parameters]. Arrows are stat-coloured; the special buffs wear a
## coloured shell (fx.status_skin).
const LOOKS: Array = [
	["Buff.AttackUp", "stat_arrows", {"color": Color(1.0, 0.35, 0.2)}],
	["Buff.DefenseUp", "stat_arrows", {"color": Color(0.3, 0.6, 1.0)}],
	["Buff.Haste", "stat_arrows", {"color": Color(1.0, 0.9, 0.3)}],
	["Buff.Regen", "stat_arrows", {"color": Color(0.4, 1.0, 0.5)}],
	["Buff.Ward", "status_skin", {"color": Color(1.0, 0.9, 0.5), "power": 3.0, "fill": 0.12, "grow": 0.03, "erosion": 0.0, "scroll": 0.0}],
	["Buff.Taunt", "status_skin", {"color": Color(1.0, 0.3, 0.25), "power": 2.0, "fill": 0.08, "grow": 0.015, "erosion": 0.3, "scroll": 1.0}],
	["Buff.Fury", "status_skin", {"color": Color(1.0, 0.55, 0.15), "power": 2.0, "fill": 0.1, "grow": 0.012, "erosion": 0.3, "scroll": 1.2}],
	["Buff.Enrage", "status_skin", {"color": Color(1.0, 0.15, 0.1), "intensity": 1.3, "power": 1.8, "fill": 0.14, "grow": 0.02, "erosion": 0.35, "scroll": 1.6}],
	["Buff.Finale", "status_skin", {"color": Color(1.0, 0.85, 0.3), "power": 2.0, "fill": 0.12, "grow": 0.012, "erosion": 0.25, "scroll": 0.8}],
	["Buff.Fracture", "status_skin", {"color": Color(0.65, 0.4, 1.0), "power": 2.0, "fill": 0.1, "grow": 0.01, "erosion": 0.4, "scroll": 0.5}],
	["Buff.Malady", "status_skin", {"color": Color(0.7, 0.8, 0.25), "power": 2.0, "fill": 0.1, "grow": 0.01, "erosion": 0.45, "scroll": -0.4}],
	["Buff.Combustion", "status_skin", {"color": Color(1.0, 0.5, 0.15), "power": 1.8, "fill": 0.2, "grow": 0.015, "erosion": 0.3, "scroll": 1.8}],
	["Debuff.AttackDown", "stat_arrows", {"color": Color(0.85, 0.2, 0.2), "drift": DOWN, "start": DOWN_START, "angle": 180.0}],
	["Debuff.DefenseDown", "stat_arrows", {"color": Color(0.3, 0.45, 0.9), "drift": DOWN, "start": DOWN_START, "angle": 180.0}],
	["Debuff.Weaken", "stat_arrows", {"color": Color(0.65, 0.4, 0.85), "drift": DOWN, "start": DOWN_START, "angle": 180.0}],
	["Debuff.Vulnerable", "stat_arrows", {"color": Color(1.0, 0.6, 0.2), "drift": DOWN, "start": DOWN_START, "angle": 180.0}],
	["Debuff.Exhausted", "stat_arrows", {"color": Color(0.6, 0.55, 0.65), "drift": DOWN, "start": DOWN_START, "angle": 180.0}],
	["Debuff.Exposed", "stat_arrows", {"color": Color(1.0, 0.4, 0.7), "drift": DOWN, "start": DOWN_START, "angle": 180.0}],
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
	var arrows := _save(_stat_arrows())
	var apply := _save(_stat_apply())
	var revive := _save(_revive_rise())
	var cleanse := _save(_cleanse_sparkle())
	var ring := _save(_cast_ring())
	var skin := load(OUT + "status_skin.tres") as FxDefinition
	var by_name := {"stat_arrows": arrows, "status_skin": skin}
	for look in LOOKS:
		_cue(_cue_file(look[0]), by_name[look[1]], look[2], true)
	_cue(_cue_file("Apply.Buff"), apply, {"color": WHITE_GOLD}, false)
	_cue(_cue_file("Apply.Debuff"), apply, {"color": PURPLE, "drift": DOWN, "start": DOWN_START, "angle": 180.0}, false)
	_cue(_cue_file("Cleanse"), cleanse, {}, false)
	# Lyra's way (a message becomes cue parameters, the cue plays): the per-type hit effects are cues that battle_fx_rules.tres executes from the
	# damage message, and a revive is a cue on the revive effects (heals use the existing Cue.Fx.Heal).
	_cue("cue_hit_fire", load(OUT + "fire_hit.tres"), {}, false)
	_cue("cue_hit_ice", load(OUT + "ice_hit.tres"), {}, false)
	_cue("cue_hit_physical", load(OUT + "slash_hit.tres"), {}, false)
	_cue("cue_revive", revive, {}, false)
	_save_rules(revive, ring)
	_register([arrows, apply, revive, cleanse, ring], [load(OUT + "battle_fx_rules.tres"), load(OUT + "support_fx_rules.tres")])
	print("build_vfx_support: wrote %d, kept %d existing" % [_written.size(), _kept.size()])
	for path in _written:
		print("  wrote ", path)
	for path in _kept:
		print("  kept  ", path)
	get_tree().quit()


static func _cue_file(suffix: String) -> String:
	return "cue_" + suffix.to_snake_case().replace(".", "_")


# --- Effects ---------------------------------------------------------------------------------------------------------

## Chevrons rising (a buff) or sinking (a debuff) around the unit, for as long as the status lasts. Direction and colour are parameters,
## so every stat buff and debuff is this one effect.
func _stat_arrows() -> FxDefinition:
	var arrows := _arrow_layer(true)
	return _define(&"fx.stat_arrows", "Stat arrows", [arrows],
		_arrow_params(), "Chevrons rising or sinking around a unit with a stat buff or debuff.", [&"Fx.Kind.Aura"], &"Center", true)


## The same chevrons as one burst, with a flash, when the stat change lands.
func _stat_apply() -> FxDefinition:
	var arrows := _arrow_layer(false)
	var glow := FxShaderQuadLayer.new()
	glow.id = &"glow"
	glow.space = FxLayer.Space.WORLD_3D
	glow.shader = load(SHADERS + "glow_3d.gdshader")
	glow.size = Vector2(2.0, 2.0)
	glow.duration = 0.35
	glow.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.4)]
	var rim := _rim(0.45)
	var params := _arrow_params()
	params.append(_param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Flash brightness.", 0.0, 4.0))
	return _define(&"fx.stat_apply", "Stat apply", [arrows, glow, rim], params,
		"A burst of chevrons and a flash when a stat buff or debuff lands.", [&"Fx.Kind.Burst"], &"Center", true)


func _arrow_layer(looping: bool) -> FxParticles3DLayer:
	var arrows := FxParticles3DLayer.new()
	arrows.id = &"arrows"
	arrows.loop = looping
	arrows.texture = load(TEX + "arrow_sheet.png")
	arrows.additive = false
	arrows.amount = 6 if looping else 8
	arrows.lifetime = 1.3 if looping else 0.8
	arrows.explosiveness = 0.0 if looping else 0.9
	arrows.emit_from_mesh = true
	arrows.emission_min_normal_y = -0.2
	arrows.speed_min = 0.0
	arrows.speed_max = 0.0
	arrows.size_min = 0.42
	arrows.size_max = 0.48
	arrows.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.2, 0.75, 1.0])
	arrows.bindings = [_bind("process_material:color", &"color"), _bind("process_material:gravity", &"drift"),
		_bind("process_material:emission_shape_offset", &"start"), _bind("process_material:angle_min", &"angle"),
		_bind("process_material:angle_max", &"angle")]
	return arrows


func _arrow_params() -> Array:
	return [_param(&"color", FxParam.Kind.COLOR, Color(1, 1, 1), "The stat's colour."),
		_param(&"drift", FxParam.Kind.VECTOR3, UP, "Which way the chevrons move: up for a buff, down for a debuff."),
		_param(&"start", FxParam.Kind.VECTOR3, Vector3.ZERO, "Where they start, relative to the unit (a debuff starts above)."),
		_param(&"angle", FxParam.Kind.FLOAT, 0.0, "Turns the chevrons over (180 for a debuff).", 0.0, 360.0)]


## Revive: a column of light, motes rising and a ring on the floor.
func _revive_rise() -> FxDefinition:
	var beam := FxShaderQuadLayer.new()
	beam.id = &"beam"
	beam.space = FxLayer.Space.WORLD_3D
	beam.shader = load(SHADERS + "glow_3d.gdshader")
	beam.size = Vector2(1.3, 3.6)
	beam.duration = 1.1
	beam.shader_params = {"falloff": 5.0, "fade_out": 0.7}
	beam.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.4)]
	var motes := FxParticles3DLayer.new()
	motes.id = &"motes"
	motes.amount = 30
	motes.lifetime = 1.3
	motes.explosiveness = 0.2
	motes.emission_radius = 0.4
	motes.direction = Vector3.UP
	motes.spread = 25.0
	motes.speed_min = 0.8
	motes.speed_max = 2.0
	motes.gravity = Vector3(0, 0.6, 0)
	motes.size_min = 0.1
	motes.size_max = 0.2
	motes.soft_distance = 0.3
	motes.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.2, 1.0])
	motes.bindings = [_bind("process_material:color", &"color")]
	var ring := _floor_ring("ring", 0.0)
	ring.size = Vector2(2.4, 2.4)
	ring.loop = false
	ring.duration = 0.7
	ring.bindings = [_bind("material:shader_parameter/color", &"color")]
	var light := FxLightLayer.new()
	light.id = &"light"
	light.min_quality = FxLayer.Quality.MEDIUM
	light.energy = 3.0
	light.light_range = 5.0
	light.seconds = 0.9
	light.bindings = [_bind("light_color", &"color")]
	return _define(&"fx.revive_rise", "Revive", [beam, motes, ring, light],
		[_param(&"color", FxParam.Kind.COLOR, WHITE_GOLD, "Light colour."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Beam brightness.", 0.0, 4.0)],
		"A column of light with rising motes and a ring on the floor: a unit brought back.", [&"Fx.Kind.Heal"], &"Base", true)


## Cleanse and dispel: sparkles thrown outward, a ring and a white flash on the unit.
func _cleanse_sparkle() -> FxDefinition:
	var sparkles := FxParticles3DLayer.new()
	sparkles.id = &"sparkles"
	sparkles.amount = 26
	sparkles.lifetime = 0.7
	sparkles.emit_from_mesh = true
	sparkles.spread = 180.0
	sparkles.speed_min = 1.2
	sparkles.speed_max = 3.0
	sparkles.damping = 2.0
	sparkles.gravity = Vector3.ZERO
	sparkles.size_min = 0.1
	sparkles.size_max = 0.18
	sparkles.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	sparkles.bindings = [_bind("process_material:color", &"color")]
	var ring := FxShaderQuadLayer.new()
	ring.id = &"ring"
	ring.space = FxLayer.Space.WORLD_3D
	ring.shader = load(SHADERS + "burst_3d.gdshader")
	ring.size = Vector2(2.6, 2.6)
	ring.duration = 0.4
	ring.bindings = [_bind("material:shader_parameter/color", &"color")]
	var rim := _rim(0.5)
	return _define(&"fx.cleanse_sparkle", "Cleanse", [sparkles, ring, rim],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.97, 0.85), "Sparkle colour.")],
		"Sparkles thrown off a unit that was cleansed or dispelled.", [&"Fx.Kind.Burst"], &"Center", true)


## The caster's flourish: a ripple on the floor and a flash on the unit, coloured by what the ability does.
func _cast_ring() -> FxDefinition:
	var ring := _floor_ring("ring", 0.0)
	ring.size = Vector2(2.2, 2.2)
	ring.loop = false
	ring.duration = 0.6
	ring.bindings = [_bind("material:shader_parameter/color", &"color")]
	var echo := _floor_ring("echo", 0.18)
	echo.size = Vector2(2.2, 2.2)
	echo.loop = false
	echo.duration = 0.6
	echo.bindings = [_bind("material:shader_parameter/color", &"color")]
	var rim := _rim(0.45)
	return _define(&"fx.cast_ring", "Cast ring", [ring, echo, rim],
		[_param(&"color", FxParam.Kind.COLOR, GOLD, "Colour of the ring and the flash (the ability's role).")],
		"Two ripples on the floor and a flash on the caster.", [&"Fx.Kind.Burst"], &"Base", true)


## A ring lying flat on the floor (the quad turned to face up).
func _floor_ring(layer_id: StringName, delay: float) -> FxShaderQuadLayer:
	var ring := FxShaderQuadLayer.new()
	ring.id = layer_id
	ring.space = FxLayer.Space.WORLD_3D
	ring.socket = &"Base"
	ring.shader = load(SHADERS + "burst_3d.gdshader")
	ring.face_camera = false
	ring.start_delay = delay
	ring.shader_params = {"ring_width": 0.07, "start_radius": 0.2, "end_radius": 0.95, "intensity": 1.4}
	var flat := FxCurveTrack.new()
	flat.property = "rotation_degrees:x"
	flat.curve = _curve([[0.0, -90.0], [1.0, -90.0]], -360.0, 360.0)
	ring.tracks = [flat]
	return ring


func _rim(seconds: float) -> FxFresnelLayer:
	var rim := FxFresnelLayer.new()
	rim.id = &"flash"
	rim.seconds = seconds
	rim.power = 2.0
	rim.fill = 0.25
	rim.intensity = 1.2
	rim.bindings = [_bind("color", &"color")]
	return rim


# --- Rules (spec 2.2) ---------------------------------------------------------------------------------------------------

## A caster's ability role colours a ring on the floor under it, and a physical hit executes its slash cue (the message becomes the cue's
## payload, as in Lyra). Heals and revives are cues on their effects, not rules.
func _save_rules(revive: FxDefinition, ring: FxDefinition) -> void:
	var path := OUT + "support_fx_rules.tres"
	if (_only != "" and _only != "support_fx_rules") or (FileAccess.file_exists(path) and not _force):
		_kept.append(path)
		return
	var rules := FxRuleSet.new()
	for role in [["Ability.Role.Heal", HEAL], ["Ability.Role.Buff", GOLD], ["Ability.Role.Debuff", PURPLE],
			["Ability.Role.Revive", WHITE_GOLD], ["Ability.Role.Cleanse", Color(1, 1, 1)]]:
		var cast := _rule(GameplayMessageRouter.BATTLE_ABILITY_USED, ring, {"color": role[1]}, FxListener.AnchorRule.INSTIGATOR_UNIT)
		cast.require_tags = [StringName(role[0])]
		# An ultimate carries its own cast cue (BattleAbility.cast_cue_tags), so the default ring leaves it alone.
		cast.exclude_tags = [&"Ability.Type.Ultimate"]
		rules.rules.append(cast)
	# Physical hits cut (the generic spark is gone; fire and ice have their own hit effects in battle_fx_rules).
	var slash := _rule(GameplayMessageRouter.BATTLE_DAMAGE, null, {}, FxListener.AnchorRule.TARGET_UNIT)
	slash.cue = &"Cue.Fx.Hit.Physical"
	slash.require_tags = [&"Damage.Type.Physical"]
	rules.rules.append(slash)
	if ResourceSaver.save(rules, path) == OK:
		_written.append(path)


func _rule(channel: StringName, effect: FxDefinition, params: Dictionary, anchor: FxListener.AnchorRule) -> FxListener:
	var rule := FxListener.new()
	rule.channel = channel
	rule.effect = effect
	rule.params = params
	rule.anchor_rule = anchor
	return rule


# --- Cue scenes --------------------------------------------------------------------------------------------------------------

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
		push_error("build_vfx_support: cannot write %s" % path)
		return definition
	_written.append(path)
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as FxDefinition


## Adds the new effects and the two rule sets to the registry (keeps everything already listed).
func _register(effects: Array[FxDefinition], rule_sets: Array) -> void:
	var path := OUT + "fx_registry.tres"
	var registry: FxRegistry = load(path)
	var changed := false
	var missing := PackedStringArray()
	for effect in effects:
		if not registry.definitions.has(effect):
			missing.append(String(effect.id))
			changed = true
	for rules in rule_sets:
		if rules != null and not registry.rule_sets.has(rules):
			missing.append(String(rules.resource_path.get_file()))
			changed = true
	if changed:
		# Additive text patch only (user, 2026-11-09): new entries appended, nothing existing touched, RegistryPatch prints what it added.
		for line in RegistryPatch.add_missing_effects():
			print("  registry: ", line)
