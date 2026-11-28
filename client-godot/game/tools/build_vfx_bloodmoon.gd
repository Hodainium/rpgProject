## Spec second-pack 2.6: the Blood Moon ultimates' cast cues (vfx-content-pass's rule: every ultimate plays the shared flourish on its
## caster with its own colour, ray count and spin, and its own signature effect on each unit it reaches). Three signatures with their own
## structure: Night Feast (Vlad), Dawnbreak (the Vampire Hunter), Moonfall Frenzy (the Werewolf), Crimson Letting (the Bloodletter). New files only, into
## presentation/demo/fx/ and presentation/demo/cues/; never overwrites one (`--force` rewrites this set's own files). The fx registry
## The Bloodletter's look effect (`fx.blood_glow`, 2.6: a red floor glow and red orbs in one effect) is built here too. The fx registry
## gets the new effects through RegistryPatch (additive); the cue registry entries and the abilities' `cast_cue_tags` are edited by hand.
##   godot --headless --path client-godot --quit-after 900 res://game/tools/build_vfx_bloodmoon.tscn [-- --force | --only <name>]
extends "res://game/tools/build_vfx_signatures2.gd"

const CUES: String = "res://presentation/demo/cues/"
const ULTS_BUILDER: String = "res://game/tools/build_vfx_ults.gd"

## Cue.Fx.Ult.<name> -> [flourish colour, rays, spin, intensity, signature file, stagger between targets].
const LOOKS: Dictionary = {
	"Dawnbreak": [Color(1.0, 0.9, 0.7), 20.0, 0.04, 1.2, "dawnbreak_strike", 0.0],
	"Moonfallfrenzy": [Color(0.78, 0.8, 1.0), 9.0, 0.22, 1.1, "moonfall_strike", 0.1],
	"Crimsonletting": [Color(0.85, 0.03, 0.08), 14.0, -0.08, 1.1, "crimsonletting_strike", 0.12],
	"Nightfeast": [Color(0.6, 0.0, 0.08), 12.0, -0.14, 1.2, "nightfeast_strike", 0.08],
}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_force = args.has("--force") or args.has("--only")
	if args.has("--only") and args.find("--only") + 1 < args.size():
		_only = args[args.find("--only") + 1]  # one file's name (an effect's or a cue's), the rest kept
	var made: Array[FxDefinition] = []
	for build in [_dawnbreak, _moonfall, _crimsonletting, _nightfeast]:
		made.append(_save(build.call()))
	made.append(_save(_blood_glow()))
	_register(made)
	var cues: Node = load(ULTS_BUILDER).new()
	cues.set("_force", _force)
	cues.set("_only", _only)
	var flourish: FxDefinition = load(OUT + "ult_flourish.tres")
	for ult in LOOKS:
		var look: Array = LOOKS[ult]
		cues.call("_cue", "cue_ult_" + String(ult).to_lower(), flourish,
			{"color": look[0], "ray_count": look[1], "spin": look[2], "intensity": look[3]}, [look[4], look[5], {"color": look[0]}])
	_written.append_array(cues.get("_written"))
	_kept.append_array(cues.get("_kept"))
	cues.free()
	print("build_vfx_bloodmoon: wrote %d, kept %d existing" % [_written.size(), _kept.size()])
	for path in _written:
		print("  wrote ", path)
	for path in _kept:
		print("  kept  ", path)
	get_tree().quit()


## Dawnbreak: a silver bolt streaks into the target, and a dawn of rays rises behind it from the floor up.
func _dawnbreak() -> FxDefinition:
	var shaft := CylinderMesh.new()
	shaft.top_radius = 0.035
	shaft.bottom_radius = 0.035
	shaft.height = 1.6
	var bolt := _mesh_layer("bolt", shaft, _emissive(Color(0.92, 0.95, 1.0)), 0.18, "")
	bolt.tracks = [_slide("position:x", -6.0, 0.0), _slide("rotation_degrees:z", 90.0, 90.0, 360.0)]
	var streak := _quad("streak", "glow_3d", Vector2(3.2, 0.22), 0.22)
	streak.shader_params = {"falloff": 5.0, "fade_out": 0.7}
	streak.bindings = [_bind("material:shader_parameter/intensity", &"intensity", 2.0)]
	var dawn := _quad("dawn", "rays_3d", Vector2(6.0, 6.0), 0.9)
	dawn.start_delay = 0.16
	# Centred on the impact; the rays fade out over their last 0.35 units above the floor (0.45 under the impact), so they never cut into it (user, 2026-11-27).
	dawn.shader_params = {"ray_count": 18.0, "spin": 0.02, "fade_out": 0.6, "floor_below": 0.45, "floor_fade": 0.35}
	dawn.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.4)]
	var glints := _particles("glints", {"start_delay": 0.16, "amount": 26, "lifetime": 0.7, "emission_radius": 0.35, "direction": Vector3.UP,
		"spread": 35.0, "speed_min": 2.0, "speed_max": 4.5, "damping": 2.0, "size_min": 0.05, "size_max": 0.1})
	glints.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	return _define(&"fx.dawnbreak_strike", "Dawnbreak strike", [bolt, streak, dawn, glints, _flat_ring("sunrise", 0.16, 3.6, 0.6, true),
		_rim("flash", 0.16, 0.3, 0.35, 0.0, 0.0, 0.0), _light(0.16, 5.0, 0.6), _shake(0.16, 0.2, 0.07)],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.9, 0.7), "Dawn colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0)],
		"A silver bolt streaks into the target, and a dawn of rays rises behind it.", &"Hit")


## Moonfall Frenzy: a pale moon flares above the target and three parallel claw rakes tear down across it, side by side.
func _moonfall() -> FxDefinition:
	var moon := _quad("moon", "glow_3d", Vector2(1.6, 1.6), 0.7)
	moon.socket = &"Top"
	moon.shader_params = {"color": Color(0.85, 0.87, 1.0), "falloff": 3.0, "fade_out": 0.5}
	moon.bindings = [_bind("material:shader_parameter/intensity", &"intensity", 1.6)]
	var layers: Array = [moon]
	for index in 3:
		var rake := _quad("rake%d" % index, "slash_3d", Vector2(2.6, 2.6), 0.3)
		rake.start_delay = 0.1 + 0.04 * index
		rake.shader_params = {"angle": -70.0, "thickness": 0.11}
		var side := -0.45 + 0.45 * index  # three parallel marks side by side (a fixed track: layers have no position field)
		rake.tracks = [_slide("position:x", side, side)]
		rake.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.4)]
		layers.append(rake)
	var tufts := _particles("tufts", {"start_delay": 0.15, "amount": 22, "lifetime": 0.55, "emission_radius": 0.45, "spread": 180.0,
		"speed_min": 2.0, "speed_max": 5.0, "gravity": Vector3(0, -7.0, 0), "size_min": 0.06, "size_max": 0.12})
	tufts.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	layers.append_array([tufts, _shake(0.12, 0.3, 0.09)])
	return _define(&"fx.moonfall_strike", "Moonfall Frenzy strike", layers,
		[_param(&"color", FxParam.Kind.COLOR, Color(0.78, 0.8, 1.0), "Claw colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0)],
		"A pale moon flares above the target and three claw rakes tear down across it.", &"Hit")


## Crimson Letting: blood spurts up out of the target and rains down around it, over a dark red pool that spreads on the floor.
func _crimsonletting() -> FxDefinition:
	var spurt := _particles("spurt", {"amount": 40, "lifetime": 0.9, "explosiveness": 0.7, "emission_radius": 0.3, "direction": Vector3.UP,
		"spread": 28.0, "speed_min": 4.0, "speed_max": 7.0, "gravity": Vector3(0, -14.0, 0), "size_min": 0.07, "size_max": 0.14, "additive": false})
	spurt.color_ramp = _ramp([Color(1, 1, 1, 1), Color(0.6, 0.6, 0.6, 0)], [0.0, 1.0])
	var pool := _flat_quad("pool", "glow_3d", 0.05, 3.0, 1.0)
	pool.shader_params = {"falloff": 2.5, "fade_out": 0.5}
	pool.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.2)]
	pool.tracks.append(_scale_curve([[0.0, 0.3], [0.4, 1.0], [1.0, 1.1]]))
	var pulse := _quad("pulse", "glow_3d", Vector2(2.0, 2.0), 0.3)
	pulse.shader_params = {"falloff": 4.0, "fade_out": 0.6}
	pulse.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.0)]
	return _define(&"fx.crimsonletting_strike", "Crimson Letting strike", [pulse, spurt, pool, _flat_ring("ripple", 0.1, 3.4, 0.6, true),
		_rim("flash", 0.0, 0.35, 0.4, 0.0, 0.0, 0.0), _shake(0.0, 0.2, 0.06)],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.85, 0.03, 0.08), "Blood colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0)],
		"Blood spurts up out of the target and rains down over a dark red pool spreading on the floor.", &"Center")


## Night Feast: two fangs bite down into the target, and a dark red mist is torn out of it and drawn upward.
func _nightfeast() -> FxDefinition:
	var upper := _quad("fang_upper", "slash_3d", Vector2(2.4, 2.4), 0.2)
	upper.shader_params = {"angle": 180.0, "thickness": 0.45}
	upper.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.2)]
	var lower := _quad("fang_lower", "slash_3d", Vector2(2.4, 2.4), 0.2)
	lower.start_delay = 0.04
	lower.shader_params = {"angle": 0.0, "thickness": 0.45}
	lower.bindings = upper.bindings
	var mist := _particles("mist", {"start_delay": 0.12, "texture": load(TEX + "smoke_sheet.png"), "h_frames": 4, "v_frames": 4, "additive": false,
		"amount": 14, "lifetime": 1.0, "emission_radius": 0.45, "direction": Vector3.UP, "spread": 25.0, "speed_min": 1.2, "speed_max": 2.4,
		"size_min": 0.5, "size_max": 0.9})
	mist.color_ramp = _ramp([Color(1, 1, 1, 0.8), Color(1, 1, 1, 0)], [0.0, 1.0])
	var drops := _particles("drops", {"start_delay": 0.1, "amount": 24, "lifetime": 0.6, "emission_radius": 0.3, "direction": Vector3.UP,
		"spread": 40.0, "speed_min": 2.5, "speed_max": 5.0, "gravity": Vector3(0, 2.0, 0), "size_min": 0.05, "size_max": 0.1})
	drops.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	return _define(&"fx.nightfeast_strike", "Night Feast strike", [upper, lower, mist, drops, _rim("flash", 0.06, 0.35, 0.35, 0.0, 0.0, 0.0),
		_shake(0.06, 0.22, 0.08)],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.6, 0.0, 0.08), "Bite and mist colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0)],
		"Two fangs bite down into the target, and a dark red mist is torn out of it and drawn upward.", &"Hit")


## The Bloodletter's floor effect (spec second-pack 2.6, the previewed look): the golden glow's floor glow and the wisp motes' orbs in one
## looping effect, the glow on `color` and the orbs on their own `mote_color`. Copies of the two effects' layers, so either stays tunable alone.
func _blood_glow() -> FxDefinition:
	var glow: FxDefinition = load(OUT + "golden_glow.tres")
	var motes: FxDefinition = load(OUT + "wisp_motes.tres")
	var layers: Array = []
	for layer in glow.layers:
		layers.append(layer.duplicate(true))
	for layer in motes.layers:
		var copy: FxLayer = layer.duplicate(true)
		copy.id = StringName("orbs_" + String(layer.id))
		for binding in copy.bindings:
			if binding.param == &"color":
				binding.param = &"mote_color"
		layers.append(copy)
	var definition := FxDefinition.new()
	definition.id = &"fx.blood_glow"
	definition.display_name = "Blood glow"
	definition.space = glow.space
	definition.socket = glow.socket
	definition.layers.assign(layers)
	definition.params.assign([_param(&"color", FxParam.Kind.COLOR, Color(0.85, 0.02, 0.06), "Floor glow colour."),
		_param(&"mote_color", FxParam.Kind.COLOR, Color(0.9, 0.05, 0.1), "Orb colour.")])
	definition.tags.assign([&"Fx.Kind.Aura"])
	definition.description = "A red glow on the floor and red orbs drifting around the unit (the Bloodletter's look)."
	return definition
