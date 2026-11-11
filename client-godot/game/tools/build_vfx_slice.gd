## Builds the vertical slice of the content-pass effects (spec vfx-content-pass 3.1, D10): the damage number, the fire hit,
## the ice hit, an explosion and a poison tick, plus the battle rule set that plays them. Writes new files into
## presentation/demo/fx/ only and never overwrites one (like build_fx_set); `--force` rewrites this set's own files and
## discards tuning. The flipbook sheets come from build_fx_textures.tscn.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_vfx_slice.tscn [-- --force]
extends Node

const OUT: String = "res://presentation/demo/fx/"
const TEX: String = "res://presentation/demo/fx/textures/"
const SHADERS: String = "res://game/fx/shaders/"
const FONT: String = "res://presentation/demo/ui/fonts/"

# The colour language (spec vfx-content-pass D9).
const PHYSICAL := Color(0.93, 0.93, 0.96)
const FIRE := Color(1.0, 0.45, 0.16)
const ICE := Color(0.45, 0.88, 1.0)
const HEAL := Color(0.45, 1.0, 0.55)
const POISON := Color(0.55, 0.95, 0.35)
const BLEED := Color(0.9, 0.18, 0.2)
const GOLD := Color(1.0, 0.82, 0.25)

var _force: bool = false
var _written := PackedStringArray()
var _kept := PackedStringArray()


func _ready() -> void:
	_force = OS.get_cmdline_user_args().has("--force")
	var definitions: Array[FxDefinition] = [_damage_number(), _fire_hit(), _ice_hit(), _explosion(), _poison_tick()]
	var saved: Array[FxDefinition] = []
	for definition in definitions:
		saved.append(_save_definition(definition))
	_add_to_registry(saved)
	_save_rules(saved)
	print("build_vfx_slice: wrote %d, kept %d existing" % [_written.size(), _kept.size()])
	for path in _written:
		print("  wrote ", path)
	for path in _kept:
		print("  kept  ", path)
	get_tree().quit()


# --- Effects ---------------------------------------------------------------------------------------------------------

## The floating number (spec 2.5): the text, its colour and outline, and an optional tag line above ("Crit!").
func _damage_number() -> FxDefinition:
	var text := FxTextLayer.new()
	text.id = &"number"
	text.bindings = [_bind("text", &"text"), _bind("modulate", &"color"), _bind("outline_modulate", &"outline_color"),
		_bind("outline_size", &"outline_size"), _bind("font_size", &"font_size")]
	var font_path := FONT + "ChakraPetch-Bold.ttf"
	if ResourceLoader.exists(font_path):
		text.font = load(font_path)
	return _define(&"fx.damage_number", "Damage number", FxDefinition.Space.WORLD_3D, [text],
		[_param(&"text", FxParam.Kind.STRING, "0", 0, 0, "The number (or any short text)."),
		_param(&"color", FxParam.Kind.COLOR, PHYSICAL, 0, 0, "Fill colour: the element."),
		_param(&"outline_color", FxParam.Kind.COLOR, Color(0.05, 0.05, 0.08), 0, 0, "Outline colour; a crit uses an accent."),
		_param(&"outline_size", FxParam.Kind.INT, 12, 0, 64, "Outline thickness in pixels; bold for a crit."),
		_param(&"font_size", FxParam.Kind.INT, 64, 16, 200, "Text size in pixels; a crit is bigger, a resisted hit smaller."),
		_param(&"label", FxParam.Kind.STRING, "", 0, 0, "A small line above the number (Crit!, Weak!, Break). Empty = none."),
		_param(&"label_color", FxParam.Kind.COLOR, GOLD, 0, 0, "Colour of that line.")],
		"A number that pops in, rises and fades away, Honkai style.", [&"Fx.Kind.Hit"], &"Top", false)


## Fire: a flame flipbook, embers, a glow and a light. Colour tints it (orange, or green for a different fire).
func _fire_hit() -> FxDefinition:
	var flames := FxParticles3DLayer.new()
	flames.id = &"flames"
	flames.texture = load(TEX + "flame_sheet.png")
	flames.h_frames = 8
	flames.v_frames = 4
	flames.amount = 12
	flames.emit_from_mesh = true
	flames.emission_min_normal_y = 0.5
	flames.soft_distance = 0.3
	flames.lifetime = 0.75
	flames.explosiveness = 0.35
	flames.direction = Vector3.UP
	flames.spread = 22.0
	flames.speed_min = 0.3
	flames.speed_max = 0.9
	flames.gravity = Vector3(0, 1.2, 0)
	flames.emission_radius = 0.22
	flames.size_min = 1.4
	flames.size_max = 2.0
	flames.color_ramp = _ramp([Color(1, 1, 1, 0.0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.0)], [0.0, 0.18, 1.0])
	flames.bindings = [_bind("process_material:color", &"color"), _bind("process_material:scale_min", &"size", 1.4),
		_bind("process_material:scale_max", &"size", 2.0)]
	var embers := FxParticles3DLayer.new()
	embers.id = &"embers"
	embers.min_quality = FxLayer.Quality.MEDIUM
	embers.amount = 16
	embers.emit_from_mesh = true
	embers.emission_min_normal_y = -0.2
	embers.lifetime = 0.9
	embers.direction = Vector3.UP
	embers.spread = 70.0
	embers.speed_min = 1.5
	embers.speed_max = 4.0
	embers.gravity = Vector3(0, -1.5, 0)
	embers.damping = 1.0
	embers.size_min = 0.06
	embers.size_max = 0.13
	embers.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	embers.bindings = [_bind("process_material:color", &"color")]
	var glow := _quad("glow", "glow_3d", true)
	glow.size = Vector2(2.4, 2.4)
	glow.duration = 0.3
	glow.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.6)]
	var light := _light(2.4, 4.0, 0.5)
	var rim := _rim(0.7, 2.0, 0.3, 0.02, 0.3, 1.6)  # a flickering fire skin on the unit
	return _define(&"fx.fire_hit", "Fire hit", FxDefinition.Space.WORLD_3D, [flames, embers, glow, light, rim],
		[_param(&"color", FxParam.Kind.COLOR, FIRE, 0, 0, "Fire colour (orange; set green or blue for another fire)."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Glow brightness."),
		_param(&"size", FxParam.Kind.FLOAT, 1.0, 0.3, 3.0, "Flame size multiplier.")],
		"Flames and embers on a unit hit by fire.", [&"Fx.Kind.Hit"], &"Hit")


## Ice: crystal shards flying out, frost mist and a ring. Its own effect: shards and a ring, which fire does not have.
func _ice_hit() -> FxDefinition:
	var shards := FxParticles3DLayer.new()
	shards.id = &"shards"
	shards.texture = load(TEX + "shard_sheet.png")
	shards.h_frames = 4
	shards.v_frames = 2
	shards.anim_cycles = 0.0
	shards.random_frame = true
	shards.additive = false
	shards.amount = 10
	shards.lifetime = 0.8
	shards.direction = Vector3.UP
	shards.spread = 120.0
	shards.speed_min = 2.5
	shards.speed_max = 5.5
	shards.gravity = Vector3(0, -6.0, 0)
	shards.damping = 1.5
	shards.size_min = 0.4
	shards.size_max = 0.7
	shards.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.7, 1.0])
	shards.bindings = [_bind("process_material:color", &"color")]
	var mist := FxParticles3DLayer.new()
	mist.id = &"mist"
	mist.texture = load(TEX + "smoke_sheet.png")
	mist.h_frames = 4
	mist.v_frames = 4
	mist.amount = 5
	mist.soft_distance = 0.5
	mist.lifetime = 1.0
	mist.explosiveness = 0.5
	mist.spread = 180.0
	mist.speed_min = 0.3
	mist.speed_max = 0.9
	mist.gravity = Vector3(0, 0.3, 0)
	mist.size_min = 1.2
	mist.size_max = 1.9
	mist.color_ramp = _ramp([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0.0)], [0.0, 0.2, 1.0])
	mist.bindings = [_bind("process_material:color", &"color")]
	var ring := _quad("ring", "burst_3d", true)
	ring.size = Vector2(2.6, 2.6)
	ring.duration = 0.4
	ring.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.4)]
	var light := _light(1.8, 3.5, 0.3)
	var rim := _rim(0.7, 2.5, 0.18, 0.012)  # a frost shell
	return _define(&"fx.ice_hit", "Ice hit", FxDefinition.Space.WORLD_3D, [shards, mist, ring, light, rim],
		[_param(&"color", FxParam.Kind.COLOR, ICE, 0, 0, "Ice colour."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Ring brightness.")],
		"Crystal shards, frost mist and a ring on a unit hit by ice.", [&"Fx.Kind.Hit"], &"Hit")


## A big explosion for ults and bosses: fireball, smoke, sparks, a shockwave, a light and a shake.
func _explosion() -> FxDefinition:
	var ball := FxParticles3DLayer.new()
	ball.id = &"fireball"
	ball.texture = load(TEX + "fireball_sheet.png")
	ball.h_frames = 8
	ball.v_frames = 4
	ball.amount = 1
	ball.lifetime = 0.8
	ball.speed_min = 0.0
	ball.speed_max = 0.0
	ball.gravity = Vector3.ZERO
	ball.size_min = 3.4
	ball.size_max = 3.4
	ball.bindings = [_bind("process_material:color", &"color"), _bind("process_material:scale_min", &"size", 3.4),
		_bind("process_material:scale_max", &"size", 3.4)]
	var smoke := FxParticles3DLayer.new()
	smoke.id = &"smoke"
	smoke.texture = load(TEX + "smoke_sheet.png")
	smoke.h_frames = 4
	smoke.v_frames = 4
	smoke.additive = false
	smoke.min_quality = FxLayer.Quality.MEDIUM
	smoke.amount = 9
	smoke.soft_distance = 0.5
	smoke.lifetime = 1.5
	smoke.explosiveness = 0.6
	smoke.spread = 180.0
	smoke.speed_min = 1.0
	smoke.speed_max = 2.6
	smoke.damping = 1.2
	smoke.gravity = Vector3(0, 0.6, 0)
	smoke.size_min = 1.6
	smoke.size_max = 2.5
	smoke.color = Color(0.22, 0.2, 0.2)
	smoke.color_ramp = _ramp([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.85), Color(1, 1, 1, 0.0)], [0.0, 0.15, 1.0])
	smoke.bindings = [_bind("process_material:scale_min", &"size", 1.6), _bind("process_material:scale_max", &"size", 2.5)]
	var sparks := FxParticles3DLayer.new()
	sparks.id = &"sparks"
	sparks.amount = 30
	sparks.lifetime = 0.8
	sparks.spread = 180.0
	sparks.speed_min = 4.0
	sparks.speed_max = 9.0
	sparks.gravity = Vector3(0, -9.0, 0)
	sparks.damping = 0.8
	sparks.size_min = 0.1
	sparks.size_max = 0.22
	sparks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	sparks.bindings = [_bind("process_material:color", &"color")]
	var wave := _quad("shockwave", "burst_3d", true)
	wave.socket = &"Base"
	wave.size = Vector2(4.2, 4.2)
	wave.duration = 0.45
	wave.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 0.7)]
	var light := _light(5.0, 7.0, 0.5)
	var shake := FxShakeLayer.new()
	shake.id = &"shake"
	shake.min_quality = FxLayer.Quality.MEDIUM
	shake.seconds = 0.35
	shake.strength_world = 0.12
	return _define(&"fx.explosion", "Explosion", FxDefinition.Space.WORLD_3D, [ball, smoke, sparks, wave, light, shake],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.55, 0.2), 0, 0, "Fireball and spark colour."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Shockwave brightness."),
		_param(&"size", FxParam.Kind.FLOAT, 1.0, 0.3, 3.0, "Size multiplier of the fireball and smoke.")],
		"A fireball with smoke, sparks, a shockwave, a light and a shake.", [&"Fx.Kind.Burst"], &"Center")


## A poison tick: green bubbles rising off the unit. Its own effect (slow rising bubbles, no burst), reused for any gas or ooze by colour.
func _poison_tick() -> FxDefinition:
	var bubbles := FxParticles3DLayer.new()
	bubbles.id = &"bubbles"
	bubbles.texture = load(TEX + "bubble_sheet.png")
	bubbles.h_frames = 4
	bubbles.v_frames = 1
	bubbles.anim_cycles = 0.0
	bubbles.random_frame = true
	bubbles.amount = 14
	bubbles.emit_from_mesh = true
	bubbles.emission_min_normal_y = -0.2
	bubbles.soft_distance = 0.25
	bubbles.lifetime = 1.3
	bubbles.explosiveness = 0.2
	bubbles.direction = Vector3.UP
	bubbles.spread = 25.0
	bubbles.speed_min = 0.8
	bubbles.speed_max = 1.6
	bubbles.gravity = Vector3(0, 0.8, 0)
	bubbles.emission_radius = 0.5
	bubbles.size_min = 0.35
	bubbles.size_max = 0.6
	bubbles.color_ramp = _ramp([Color(1, 1, 1, 0.0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.0)], [0.0, 0.2, 1.0])
	bubbles.bindings = [_bind("process_material:color", &"color")]
	var haze := _quad("haze", "glow_3d", true)
	haze.size = Vector2(1.6, 1.6)
	haze.duration = 0.8
	haze.shader_params = {"falloff": 3.0, "fade_out": 0.8}
	haze.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 0.8)]
	var rim := _rim(1.0, 1.8, 0.06, 0.01, 0.45, 0.6)  # an ooze sheen
	return _define(&"fx.poison_tick", "Poison tick", FxDefinition.Space.WORLD_3D, [bubbles, haze, rim],
		[_param(&"color", FxParam.Kind.COLOR, POISON, 0, 0, "Bubble colour."),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Haze brightness.")],
		"Bubbles rising off a unit that is poisoned.", [&"Fx.Kind.Aura"], &"Center")


# --- The rule set (spec 2.2) -----------------------------------------------------------------------------------------

func _save_rules(effects: Array[FxDefinition]) -> void:
	var path := OUT + "battle_fx_rules.tres"
	if FileAccess.file_exists(path) and not _force:
		_kept.append(path)
		return
	var number: FxDefinition = effects[0]
	var rules := FxRuleSet.new()
	# Row hits: the number. The element colours and the modifiers are parameters chosen by the hit's tags, in this order.
	var hit_number := _rule(GameplayMessageRouter.BATTLE_DAMAGE, number, {})
	hit_number.text_param = &"text"
	hit_number.tag_params = {
		"Damage.Type.Physical": {"color": PHYSICAL},
		"Damage.Type.Fire": {"color": FIRE},
		"Damage.Type.Ice": {"color": ICE},
		"Hit.Resisted": {"font_size": 64, "color": Color(0.7, 0.7, 0.75)},
		"Hit.Weakness": {"label": "Weak!", "label_color": Color(1.0, 1.0, 1.0), "font_size": 64},
		"Hit.Break": {"label": "Break", "label_color": Color(1.0, 1.0, 1.0), "font_size": 76},
		"Hit.Critical": {"label": "Crit!", "label_color": GOLD, "font_size": 64, "outline_size": 15, "outline_color": Color(1.0, 0.95, 0.6)},
	}
	hit_number.tag_order = [&"Hit.Resisted", &"Hit.Weakness", &"Hit.Break", &"Hit.Critical"]
	rules.rules.append(hit_number)
	# HP that is not a row hit: a heal, then a DoT tick (the colour is the status).
	var heal := _rule(GameplayMessageRouter.BATTLE_HP_CHANGED, number, {"color": HEAL, "font_size": 64})
	heal.require_verb = &"Verb.Heal"
	heal.text_param = &"text"
	heal.text_prefix = "+"
	rules.rules.append(heal)
	var tick := _rule(GameplayMessageRouter.BATTLE_HP_CHANGED, number, {"color": PHYSICAL, "font_size": 64})
	tick.require_verb = &"Verb.Damage"
	tick.text_param = &"text"
	tick.tag_params = {
		"Status.Debuff.Poison": {"color": POISON},
		"Status.Debuff.Bleed": {"color": BLEED},
		"Status.Debuff.Burn": {"color": FIRE},
	}
	rules.rules.append(tick)
	# Per-type hit effects. (A DoT's tick and look are cues on its status effect, spec vfx-content-pass D7.)
	var fire := _rule(GameplayMessageRouter.BATTLE_DAMAGE, effects[1], {})
	fire.require_tags = [&"Damage.Type.Fire"]
	rules.rules.append(fire)
	var ice := _rule(GameplayMessageRouter.BATTLE_DAMAGE, effects[2], {})
	ice.require_tags = [&"Damage.Type.Ice"]
	rules.rules.append(ice)
	if BuilderSave.save(rules, path) == OK:
		_written.append(path)


func _rule(channel: StringName, effect: FxDefinition, params: Dictionary) -> FxListener:
	var rule := FxListener.new()
	rule.channel = channel
	rule.effect = effect
	rule.params = params
	rule.anchor_rule = FxListener.AnchorRule.TARGET_UNIT
	return rule


# --- Helpers (as in build_fx_set) -----------------------------------------------------------------------------------

## A fresnel rim glow on the unit's own mesh (spec vfx-content-pass 3.6), tinted by the effect's colour.
func _rim(seconds: float, power: float, fill: float = 0.0, grow: float = 0.0, erosion: float = 0.0, scroll: float = 0.0) -> FxFresnelLayer:
	var rim := FxFresnelLayer.new()
	rim.id = &"rim"
	rim.seconds = seconds
	rim.power = power
	rim.intensity = 1.6
	rim.fill = fill
	rim.grow = grow
	rim.erosion = erosion
	rim.scroll = scroll
	rim.noise_scale = 5.0
	rim.bindings = [_bind("color", &"color")]
	return rim


func _light(energy: float, light_range: float, seconds: float) -> FxLightLayer:
	var light := FxLightLayer.new()
	light.id = &"light"
	light.min_quality = FxLayer.Quality.MEDIUM
	light.energy = energy
	light.light_range = light_range
	light.seconds = seconds
	light.bindings = [_bind("light_color", &"color")]
	return light


func _define(effect_id: StringName, title: String, space: FxDefinition.Space, layers: Array, params: Array, note: String, tags: Array,
		socket: StringName = &"Center", biased: bool = true) -> FxDefinition:
	# Every particle and quad layer gets the depth-bias binding (spec 3.6): the play fills it with the unit's radius, so the unit's own
	# mesh does not cut the effect; the parameter's default is the fallback for an anchor that has no radius.
	if biased:
		for layer in layers:
			if layer is FxParticles3DLayer:
				layer.bindings.append(_bind("draw_pass_1:material:shader_parameter/depth_bias", &"depth_bias"))
			elif layer is FxShaderQuadLayer:
				layer.bindings.append(_bind("material:shader_parameter/depth_bias", &"depth_bias"))
		params.append(_param(&"depth_bias", FxParam.Kind.FLOAT, 0.7, 0.0, 4.0,
			"World units the depth test sees the effect closer to the camera. Filled with the unit's radius unless the caller passes one."))
	var definition := FxDefinition.new()
	definition.id = effect_id
	definition.display_name = title
	definition.space = space
	definition.layers.assign(layers)
	definition.params.assign(params)
	definition.description = note
	definition.tags.assign(tags)
	definition.socket = socket
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


func _ramp(colors: Array, offsets: Array) -> Gradient:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array(offsets)
	gradient.colors = PackedColorArray(colors)
	return gradient


func _quad(layer_id: StringName, shader_name: String, in_3d: bool) -> FxShaderQuadLayer:
	var quad := FxShaderQuadLayer.new()
	quad.id = layer_id
	quad.shader = load(SHADERS + shader_name + ".gdshader")
	if in_3d:
		quad.space = FxLayer.Space.WORLD_3D
	return quad


func _save_definition(definition: FxDefinition) -> FxDefinition:
	var path := OUT + String(definition.id).trim_prefix("fx.") + ".tres"
	if FileAccess.file_exists(path) and not _force:
		_kept.append(path)
		return load(path)
	if BuilderSave.save(definition, path) != OK:
		push_error("build_vfx_slice: cannot write %s" % path)
		return definition
	_written.append(path)
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as FxDefinition


## Adds the new effects to the existing registry (keeps everything already listed, including tuned entries).
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
