## The pack reveal's alternative big-reveal effects (playtest 2026-11-18: the user asked for shorter rays and a few alternatives to
## pick from in the pack reveal demo, game/dev/pack_reveal_demo.tscn; the user picked these two, the others were removed). Creates new files in presentation/demo/fx/ only and never
## overwrites one (`--force` rewrites this builder's own files, which discards tuning), then adds the new files to the registry
## through RegistryPatch (the approved additive patch). The existing fx.legendary_rays is left as it is.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_pack_reveal_fx.tscn [-- --force]
extends "res://game/tools/build_fx_set.gd"


func _ready() -> void:
	_force = OS.get_cmdline_user_args().has("--force")
	for definition in [_reveal_rays(), _reveal_halo()]:
		_save_definition(definition)
	var added := RegistryPatch.add_missing_effects()
	print("build_pack_reveal_fx: wrote %d, kept %d existing; registry: %s" % [_written.size(), _kept.size(), added])
	for path in _written:
		print("  wrote ", path)
	for path in _kept:
		print("  kept  ", path)
	get_tree().quit()


func _color_params(default: Color, note: String) -> Array:
	return [_param(&"color", FxParam.Kind.COLOR, default, 0, 0, note),
		_param(&"intensity", FxParam.Kind.FLOAT, 1.0, 0.0, 4.0, "Brightness.")]


func _motes(amount: int, lifetime: float, speed_min: float, speed_max: float) -> FxParticles2DLayer:
	var motes := FxParticles2DLayer.new()
	motes.id = &"motes"
	motes.min_quality = FxLayer.Quality.MEDIUM
	motes.amount = amount
	motes.lifetime = lifetime
	motes.speed_min = speed_min
	motes.speed_max = speed_max
	motes.gravity = Vector3(0, 40, 0)
	motes.size_min = 0.1
	motes.size_max = 0.32
	motes.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	motes.bindings = [_bind("process_material:color", &"color")]
	return motes


## The Legendary rays, shorter (1.3 s instead of 2.2 s) and spinning a little faster, without a screen flash of their own (the
## choreography decides the screen flash, so a Mythic flashes once).
func _reveal_rays() -> FxDefinition:
	var rays := _quad("rays", "rays", false)
	rays.size = Vector2(1000, 1000)
	rays.duration = 1.3
	rays.shader_params = {"spin": 0.18, "fade_out": 0.45}
	rays.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity")]
	# UI space, anchored on the card's control: drawn over the whole screen, never clipped by the stage's own viewport.
	return _define(&"fx.reveal_rays", "Reveal rays (short)", FxDefinition.Space.UI, [rays, _motes(40, 1.2, 120.0, 360.0)],
		_color_params(Color(1.0, 0.7, 0.2), "Colour of the rays (the card's rarity)."),
		"A big card reveal: short spinning rays and motes, no screen flash.", [&"Fx.Kind.Burst"])


## A glow hugging the card that swells and fades, with sparkles rising off it: a calmer reveal that stays on the card.
func _reveal_halo() -> FxDefinition:
	var glow := _quad("glow", "glow_aura", false)
	glow.duration = 1.4
	# Playtest fix: the quad reaches far past the glow (exp(-0.04 * 200) ~ 0), so its edge never shows as a box.
	glow.grow = 200.0
	glow.shader_params = {"corner": 18.0, "falloff": 0.04, "inner_glow": 0.35, "pulse_speed": 2.5, "pulse_amount": 0.25,
		"fade_in": 0.12, "fade_out": 0.5}
	glow.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.8)]
	var sparkles := FxParticles2DLayer.new()
	sparkles.id = &"sparkles"
	sparkles.min_quality = FxLayer.Quality.MEDIUM
	sparkles.amount = 42
	sparkles.lifetime = 1.3
	sparkles.explosiveness = 0.5
	sparkles.fit_to_anchor = true
	sparkles.direction = Vector3(0, -1, 0)
	sparkles.spread = 30.0
	sparkles.speed_min = 60.0
	sparkles.speed_max = 170.0
	sparkles.gravity = Vector3(0, -40, 0)
	sparkles.size_min = 0.12
	sparkles.size_max = 0.32
	sparkles.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.25, 1.0])
	sparkles.bindings = [_bind("process_material:color", &"color")]
	return _define(&"fx.reveal_halo", "Reveal halo", FxDefinition.Space.UI, [glow, sparkles],
		_color_params(Color(1.0, 0.7, 0.2), "Colour of the halo (the card's rarity)."),
		"A big card reveal: a halo swells around the card and sparkles rise from it. Anchor it on the card's control.",
		[&"Fx.Kind.Burst"])
