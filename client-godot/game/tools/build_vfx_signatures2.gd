## Builds the other 21 ultimates' signature effects (spec vfx-content-pass, group 4b): each ultimate is its own effect with its own structure,
## not a recolour of a shared one. Played on every unit the ultimate reaches by the ultimate's cue (`FxCueNotify.target_fx`, set by
## build_vfx_ults.tscn). New files only, into presentation/demo/fx/; never overwrites one (`--force` rewrites this set's own files,
## `--only <name>` just one).
##   godot --headless --path client-godot --quit-after 900 res://game/tools/build_vfx_signatures2.tscn [-- --force | --only <name>]
extends Node

const OUT: String = "res://presentation/demo/fx/"
const TEX: String = "res://presentation/demo/fx/textures/"
const SHADERS: String = "res://game/fx/shaders/"

var _force: bool = false
var _only: String = ""
var _written := PackedStringArray()
var _kept := PackedStringArray()


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_force = args.has("--force") or args.has("--only")
	if args.has("--only") and args.find("--only") + 1 < args.size():
		_only = args[args.find("--only") + 1]
	var made: Array[FxDefinition] = []
	for build in [_supernova, _overheat, _crucible, _pandemic, _blackmass, _deathray, _cleave, _judgement, _liquidate, _oblivion, _ossuary,
			_quake, _rainofarrows, _shatterchorus, _systole, _twinbeat, _bastion, _combustion, _finale, _resurrection, _sanctuary]:
		made.append(_save(build.call()))
	_register(made)
	print("build_vfx_signatures2: wrote %d, kept %d existing" % [_written.size(), _kept.size()])
	for path in _written:
		print("  wrote ", path)
	for path in _kept:
		print("  kept  ", path)
	get_tree().quit()


# =====================================================================================================================================
# Fire
# =====================================================================================================================================

## Supernova: a white-hot star swells at the target and blows out in a shockwave, rays and sparks.
func _supernova() -> FxDefinition:
	var star := _mesh_layer("star", _sphere(0.5), _emissive(Color(1.0, 0.85, 0.5)), 0.6, "material_override:albedo_color")
	star.tracks = [_scale_curve([[0.0, 0.2], [0.35, 2.0], [1.0, 3.2]]), _alpha_curve("material_override:albedo_color", [[0.0, 1.0], [0.5, 0.85], [1.0, 0.0]])]
	var rays := _quad("rays", "rays_3d", Vector2(5.0, 5.0), 0.6)
	rays.shader_params = {"ray_count": 26.0, "spin": 0.1, "fade_out": 0.6}
	rays.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 0.9)]
	var wave := _ring("wave", 0.08, 5.0, 0.55, true)
	var sparks := _particles("sparks", {"amount": 44, "lifetime": 0.8, "spread": 180.0, "speed_min": 4.0, "speed_max": 9.5, "damping": 1.5,
		"size_min": 0.08, "size_max": 0.16, "gravity": Vector3.ZERO})
	sparks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	var flash := _sub("flash", 0.1, "screen_flash", {"color": "$color", "intensity": 0.8})
	return _define(&"fx.supernova_strike", "Supernova strike", [star, rays, wave, sparks, flash, _light(0.0, 6.0, 0.7), _shake(0.1, 0.35, 0.1)],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.65, 0.2), "Star colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Ray brightness.", 0.0, 4.0)],
		"A white-hot star swells at the target and blows out in a shockwave, rays and sparks.", &"Center")


## Overheat: pillars of flame erupt under the target.
func _overheat() -> FxDefinition:
	var pillars := _particles("pillars", {"texture": load(TEX + "flame_sheet.png"), "h_frames": 8, "v_frames": 4, "amount": 30, "lifetime": 1.1,
		"explosiveness": 0.25, "emission_ring_radius": 0.55, "direction": Vector3.UP, "spread": 5.0, "speed_min": 4.0, "speed_max": 6.5, "damping": 1.2,
		"gravity": Vector3(0, 1.0, 0), "size_min": 1.7, "size_max": 2.5, "soft_distance": 0.3})
	pillars.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.15, 1.0])
	var embers := _particles("embers", {"amount": 28, "lifetime": 1.2, "emission_ring_radius": 0.7, "direction": Vector3.UP, "spread": 25.0, "speed_min": 3.0,
		"speed_max": 7.0, "gravity": Vector3(0, -1.0, 0), "size_min": 0.06, "size_max": 0.13})
	embers.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	var glow := _flat_ring("heat", 0.0, 3.6, 0.9, false)
	var skin := _rim("skin", 0.0, 0.9, 0.3, 0.02, 0.3, 1.8)
	return _define(&"fx.overheat_strike", "Overheat strike", [glow, pillars, embers, skin, _light(0.0, 4.0, 0.9), _shake(0.1, 0.4, 0.07)],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.3, 0.1), "Flame colour.")],
		"Pillars of flame erupt from the ground under the target.", &"Base")


## Crucible: a pool of molten rock spreads under the target and geysers spit lava.
func _crucible() -> FxDefinition:
	var pool_material := ShaderMaterial.new()
	pool_material.shader = load(SHADERS + "material/lava_rock.gdshader")
	pool_material.set_shader_parameter("bump", 0.02)
	pool_material.set_shader_parameter("crack_cover", 0.5)
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0
	cylinder.bottom_radius = 1.0
	cylinder.height = 0.06
	var pool := FxMeshLayer.new()
	pool.id = &"pool"
	pool.mesh = cylinder
	pool.material = pool_material
	pool.seconds = 1.5
	pool.bindings = [_bind("material_override:shader_parameter/color", &"color"), _bind("material_override:shader_parameter/glow", &"intensity", 1.8)]
	pool.tracks = [_scale_curve([[0.0, 0.1], [0.25, 1.0], [0.85, 1.0], [1.0, 0.1]])]
	var geysers := _particles("geysers", {"texture": load(TEX + "bubble_sheet.png"), "h_frames": 4, "v_frames": 1, "anim_cycles": 0.0, "random_frame": true,
		"amount": 30, "lifetime": 1.0, "explosiveness": 0.0, "emission_radius": 0.7, "direction": Vector3.UP, "spread": 12.0, "speed_min": 4.0, "speed_max": 7.5,
		"gravity": Vector3(0, -10.0, 0), "size_min": 0.25, "size_max": 0.5})
	geysers.start_delay = 0.2
	geysers.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.7, 1.0])
	var spit := _particles("spit", {"amount": 40, "lifetime": 0.9, "emission_radius": 0.6, "direction": Vector3.UP, "spread": 30.0, "speed_min": 3.0, "speed_max": 8.0,
		"gravity": Vector3(0, -12.0, 0), "size_min": 0.07, "size_max": 0.14})
	spit.start_delay = 0.2
	spit.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	return _define(&"fx.crucible_strike", "Crucible strike", [pool, geysers, spit, _flat_ring("heat", 0.0, 2.8, 0.6, false), _light(0.0, 3.0, 1.2)],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.45, 0.1), "Lava colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Glow brightness.", 0.0, 4.0)],
		"A pool of molten rock spreads under the target and geysers spit lava.", &"Base")


## Pandemic: a sick green cloud rolls over the target with fiery flecks.
func _pandemic() -> FxDefinition:
	var cloud := _particles("cloud", {"texture": load(TEX + "smoke_sheet.png"), "h_frames": 4, "v_frames": 4, "additive": false, "amount": 14, "lifetime": 1.8,
		"explosiveness": 0.35, "emission_radius": 0.7, "spread": 180.0, "speed_min": 0.3, "speed_max": 1.0, "gravity": Vector3(0, 0.2, 0), "size_min": 1.6, "size_max": 2.8,
		"soft_distance": 0.5})
	cloud.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 0.75), Color(1, 1, 1, 0)], [0.0, 0.2, 1.0])
	var flecks := _particles("flecks", {"amount": 26, "lifetime": 1.2, "emission_radius": 0.8, "spread": 180.0, "speed_min": 0.6, "speed_max": 1.8,
		"gravity": Vector3(0, 0.3, 0), "size_min": 0.06, "size_max": 0.12})
	flecks.color = Color(1.0, 0.5, 0.15)
	flecks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	flecks.bindings = []
	var sheen := _rim("sheen", 0.0, 1.4, 0.2, 0.012, 0.4, 0.8)
	return _define(&"fx.pandemic_strike", "Pandemic strike", [cloud, flecks, sheen, _ring("wave", 0.0, 3.4, 0.8, true)],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.6, 0.9, 0.25), "Plague colour.")],
		"A sick green cloud rolls over the target, flecked with fire, and its skin turns to ooze.", &"Center")


# =====================================================================================================================================
# Ice and void
# =====================================================================================================================================

## Black Mass: a black sphere forms above the target and pulls everything in, then collapses and bursts.
func _blackmass() -> FxDefinition:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.02, 0.0, 0.04)
	material.rim_enabled = true
	material.rim = 1.0
	material.rim_tint = 0.2
	material.emission_enabled = true
	material.emission = Color(0.4, 0.15, 0.7)
	material.emission_energy_multiplier = 0.4
	var sphere := _mesh_layer("sphere", _sphere(0.5), material, 1.0, "")
	sphere.tracks = [_slide("position:y", 1.3, 1.3), _scale_curve([[0.0, 0.1], [0.3, 1.0], [0.72, 1.15], [0.95, 0.05], [1.0, 0.0]])]
	var pull := _particles("pull", {"amount": 44, "lifetime": 0.8, "explosiveness": 0.0, "emission_sphere": 1.8, "emission_offset": Vector3(0, 1.3, 0),
		"radial_accel": -16.0, "gravity": Vector3.ZERO, "size_min": 0.08, "size_max": 0.18})
	pull.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.8)], [0.0, 0.3, 1.0])
	var pop := _particles("pop", {"start_delay": 0.95, "amount": 34, "lifetime": 0.7, "emission_offset": Vector3(0, 1.3, 0), "spread": 180.0, "speed_min": 3.0,
		"speed_max": 8.0, "damping": 2.0, "gravity": Vector3.ZERO, "size_min": 0.1, "size_max": 0.2})
	pop.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	var wave := _ring("wave", 0.95, 3.6, 0.5, true)
	wave.socket = &"Hit"
	var flash := _rim("flash", 0.95, 0.5, 0.35, 0.0, 0.0, 0.0)
	return _define(&"fx.blackmass_strike", "Black Mass strike", [sphere, pull, pop, wave, flash, _shake(0.95, 0.25, 0.08)],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.55, 0.3, 0.9), "Void colour.")],
		"A black sphere forms above the target and pulls everything in, then collapses and bursts.", &"Center")


## Death Ray: a thick beam of violet light drops from the sky onto the target.
func _deathray() -> FxDefinition:
	var beam := _quad("beam", "beam_3d", Vector2(1.8, 9.0), 0.95)
	beam.shader_params = {"core_color": Color(1, 1, 1, 1), "sharpness": 9.0, "ripple": 0.12}
	beam.tracks = [_slide("position:y", 4.0, 4.0)]
	beam.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.2)]
	var flare := _quad("flare", "glow_3d", Vector2(3.0, 3.0), 0.7)
	flare.shader_params = {"falloff": 4.0, "fade_out": 0.7}
	flare.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.0)]
	var impact := _flat_ring("impact", 0.08, 3.4, 0.6, true)
	var sparks := _particles("sparks", {"amount": 40, "lifetime": 0.9, "emission_radius": 0.3, "direction": Vector3.UP, "spread": 50.0, "speed_min": 3.0, "speed_max": 8.0,
		"gravity": Vector3(0, -6.0, 0), "size_min": 0.07, "size_max": 0.15})
	sparks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	return _define(&"fx.deathray_strike", "Death Ray strike", [beam, flare, impact, sparks, _light(0.0, 5.0, 0.8), _shake(0.05, 0.6, 0.06)],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.7, 0.4, 1.0), "Beam colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0)],
		"A thick beam of light drops from the sky onto the target, with a white-hot core and a ring where it lands.", &"Base")


# =====================================================================================================================================
# Physical
# =====================================================================================================================================

## Cleave: a huge X of two slashes tears across the target.
func _cleave() -> FxDefinition:
	var first := _quad("slash_a", "slash_3d", Vector2(4.8, 4.8), 0.32)
	first.shader_params = {"angle": 38.0, "thickness": 0.3}
	first.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.6)]
	var second := _quad("slash_b", "slash_3d", Vector2(4.8, 4.8), 0.32)
	second.start_delay = 0.09
	second.shader_params = {"angle": -142.0, "thickness": 0.3}
	second.bindings = first.bindings
	var sparks := _particles("sparks", {"start_delay": 0.1, "amount": 36, "lifetime": 0.5, "emission_radius": 0.5, "spread": 180.0, "speed_min": 3.0, "speed_max": 8.0,
		"gravity": Vector3(0, -8.0, 0), "size_min": 0.07, "size_max": 0.14})
	sparks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	return _define(&"fx.cleave_strike", "Cleave strike", [first, second, sparks, _rim("flash", 0.1, 0.3, 0.3, 0.0, 0.0, 0.0), _shake(0.1, 0.25, 0.08)],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.5, 0.4), "Slash colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0)],
		"A huge X of two slashes tears across the target.", &"Hit")


## Judgement: a spear of light falls, and a halo with a cross flare opens where it lands.
func _judgement() -> FxDefinition:
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.12
	cone.height = 2.4
	var spear := _mesh_layer("spear", cone, _emissive(Color(1.0, 0.95, 0.7)), 0.28, "material_override:albedo_color")
	spear.tracks = [_slide("position:y", 6.5, 1.4), _slide("rotation_degrees:x", 180.0, 180.0, 360.0)]
	var rays := _quad("rays", "rays_3d", Vector2(6.0, 6.0), 0.8)
	rays.start_delay = 0.26
	rays.shader_params = {"ray_count": 24.0, "spin": 0.03, "fade_out": 0.6}
	rays.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.6)]
	var cross_a := _quad("cross_a", "glow_3d", Vector2(0.3, 3.4), 0.4)
	cross_a.start_delay = 0.26
	cross_a.shader_params = {"falloff": 6.0, "fade_out": 0.7}
	cross_a.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.2)]
	var cross_b := _quad("cross_b", "glow_3d", Vector2(3.4, 0.3), 0.4)
	cross_b.start_delay = 0.26
	cross_b.shader_params = cross_a.shader_params
	cross_b.bindings = cross_a.bindings
	return _define(&"fx.judgement_strike", "Judgement strike", [spear, rays, cross_a, cross_b, _flat_ring("halo", 0.26, 3.2, 0.7, true), _flat_ring("halo2", 0.4, 4.4, 0.7, true),
		_light(0.26, 5.0, 0.6), _shake(0.26, 0.2, 0.06)],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.92, 0.55), "Light colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0)],
		"A spear of light falls on the target; a halo and a cross flare open where it lands.", &"Base")


## Liquidate: coins burst off the target in a fountain.
func _liquidate() -> FxDefinition:
	var coins := _particles("coins", {"texture": load(TEX + "coin_sheet.png"), "additive": false, "amount": 24, "lifetime": 1.2, "explosiveness": 0.8,
		"emission_radius": 0.3, "direction": Vector3.UP, "spread": 55.0, "speed_min": 4.0, "speed_max": 8.0, "gravity": Vector3(0, -11.0, 0), "spin_min": 200.0,
		"spin_max": 600.0, "size_min": 0.3, "size_max": 0.42})
	coins.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.75, 1.0])
	coins.bindings = []
	var glints := _particles("glints", {"amount": 36, "lifetime": 0.8, "emission_radius": 0.4, "spread": 180.0, "speed_min": 1.0, "speed_max": 4.0, "gravity": Vector3.ZERO,
		"size_min": 0.06, "size_max": 0.13})
	glints.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	var glow := _quad("glow", "glow_3d", Vector2(2.4, 2.4), 0.4)
	glow.shader_params = {"falloff": 3.0, "fade_out": 0.7}
	glow.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.6)]
	return _define(&"fx.liquidate_strike", "Liquidate strike", [coins, glints, glow, _ring("ring", 0.0, 2.6, 0.45, true)],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.85, 0.3), "Glint colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Glow brightness.", 0.0, 4.0)],
		"Gold coins burst off the target in a fountain.", &"Center")


## Oblivion: a void bubble swallows the target while rings close in on it.
func _oblivion() -> FxDefinition:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.01, 0.0, 0.03)
	material.rim_enabled = true
	material.rim = 1.0
	material.rim_tint = 0.1
	material.emission_enabled = true
	material.emission = Color(0.35, 0.15, 0.6)
	material.emission_energy_multiplier = 0.6
	var bubble := _mesh_layer("bubble", _sphere(0.5), material, 1.1, "")
	bubble.tracks = [_scale_curve([[0.0, 0.1], [0.3, 2.3], [0.7, 2.4], [1.0, 0.2]])]
	var rings: Array = []
	for index in 3:
		var closing := _ring("close%d" % index, 0.12 * index, 4.4, 0.6, true)
		closing.shader_params = {"ring_width": 0.06, "start_radius": 0.95, "end_radius": 0.12, "intensity": 1.6}
		rings.append(closing)
	var smoke := _particles("smoke", {"texture": load(TEX + "smoke_sheet.png"), "h_frames": 4, "v_frames": 4, "additive": false, "amount": 14, "lifetime": 1.0,
		"explosiveness": 0.0, "emission_sphere": 1.5, "radial_accel": -5.0, "gravity": Vector3.ZERO, "size_min": 0.9, "size_max": 1.5, "soft_distance": 0.4})
	smoke.color = Color(0.2, 0.08, 0.35)
	smoke.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 0.8), Color(1, 1, 1, 0)], [0.0, 0.3, 1.0])
	smoke.bindings = []
	return _define(&"fx.oblivion_strike", "Oblivion strike", [bubble, rings[0], rings[1], rings[2], smoke, _rim("edge", 0.0, 1.0, 0.0, 0.0, 0.0, 0.0)],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.45, 0.25, 0.7), "Ring colour.")],
		"A black void bubble swallows the target while rings close in on it.", &"Center")


## Ossuary: bone spikes erupt from the ground around the target and sink back.
func _ossuary() -> FxDefinition:
	var layers: Array = []
	var bone := StandardMaterial3D.new()
	bone.albedo_color = Color(0.9, 0.87, 0.76)
	bone.roughness = 0.8
	bone.emission_enabled = true
	bone.emission = Color(0.9, 0.85, 0.6)
	bone.emission_energy_multiplier = 0.25
	for index in 7:
		var angle := TAU * index / 7.0 + 0.3
		var radius := 0.55 if index % 2 == 0 else 0.85
		var spike_mesh := CylinderMesh.new()
		spike_mesh.top_radius = 0.0
		spike_mesh.bottom_radius = 0.2 if index % 2 == 0 else 0.15
		spike_mesh.height = 2.3 if index % 2 == 0 else 1.7
		var spike := _mesh_layer("spike%d" % index, spike_mesh, bone, 1.1, "material_override:emission")
		spike.start_delay = 0.04 * index
		spike.tracks = [_slide("position:x", cos(angle) * radius, cos(angle) * radius), _slide("position:z", sin(angle) * radius, sin(angle) * radius),
			_slide("rotation_degrees:z", -cos(angle) * 14.0, -cos(angle) * 14.0, 90.0), _slide("rotation_degrees:x", sin(angle) * 14.0, sin(angle) * 14.0, 90.0),
			_rise_and_sink(1.1 if index % 2 == 0 else 0.8)]
		layers.append(spike)
	var dust := _particles("dust", {"texture": load(TEX + "smoke_sheet.png"), "h_frames": 4, "v_frames": 4, "additive": false, "amount": 10, "lifetime": 1.2,
		"explosiveness": 0.7, "emission_ring_radius": 0.7, "direction": Vector3.UP, "spread": 70.0, "speed_min": 0.8, "speed_max": 1.8, "size_min": 0.9, "size_max": 1.5,
		"soft_distance": 0.4})
	dust.color = Color(0.7, 0.66, 0.58)
	dust.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 0.6), Color(1, 1, 1, 0)], [0.0, 0.15, 1.0])
	dust.bindings = []
	layers.append(dust)
	layers.append(_flat_ring("rings", 0.0, 3.0, 0.5, true))
	layers.append(_shake(0.0, 0.25, 0.06))
	return _define(&"fx.ossuary_strike", "Ossuary strike", layers, [_param(&"color", FxParam.Kind.COLOR, Color(0.9, 0.88, 0.75), "Ring colour.")],
		"Bone spikes erupt from the ground around the target, hold, and sink back.", &"Base")


## Quake: the ground cracks open in glowing seams, debris flies, the screen shakes hard.
func _quake() -> FxDefinition:
	var cracks := _flat_quad("cracks", "crack_ground", 0.0, 4.4, 1.0)
	cracks.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.0)]
	var rocks := _particles("rocks", {"additive": false, "amount": 36, "lifetime": 1.0, "explosiveness": 0.9, "emission_ring_radius": 0.6, "direction": Vector3.UP,
		"spread": 40.0, "speed_min": 3.5, "speed_max": 8.0, "gravity": Vector3(0, -14.0, 0), "spin_min": -300.0, "spin_max": 300.0, "size_min": 0.12, "size_max": 0.26})
	rocks.color = Color(0.32, 0.26, 0.22)
	rocks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.8, 1.0])
	rocks.bindings = []
	var dust := _particles("dust", {"texture": load(TEX + "smoke_sheet.png"), "h_frames": 4, "v_frames": 4, "additive": false, "amount": 12, "lifetime": 1.4,
		"explosiveness": 0.6, "emission_ring_radius": 1.0, "direction": Vector3.UP, "spread": 80.0, "speed_min": 1.0, "speed_max": 2.4, "size_min": 1.0, "size_max": 1.8,
		"soft_distance": 0.4})
	dust.color = Color(0.62, 0.55, 0.46)
	dust.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)], [0.0, 0.12, 1.0])
	dust.bindings = []
	return _define(&"fx.quake_strike", "Quake strike", [cracks, rocks, dust, _flat_ring("wave", 0.0, 3.8, 0.5, true), _light(0.0, 2.0, 0.6), _shake(0.0, 0.5, 0.14)],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.95, 0.6, 0.3), "Crack glow."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0)],
		"The ground cracks open in glowing seams, debris flies and the screen shakes.", &"Base")


## Rain of Arrows: a volley of arrows streaks down onto the target.
func _rainofarrows() -> FxDefinition:
	var layers: Array = []
	for index in 8:
		var shaft := CylinderMesh.new()
		shaft.top_radius = 0.035
		shaft.bottom_radius = 0.035
		shaft.height = 1.8
		var arrow := _mesh_layer("arrow%d" % index, shaft, _emissive(Color(0.85, 1.0, 0.9)), 0.32, "material_override:albedo_color")
		arrow.start_delay = 0.05 * index
		var offset := (float(index % 4) - 1.5) * 0.45
		var depth := (float(index / 4) - 0.5) * 0.7
		arrow.tracks = [_slide("position:y", 6.5, 0.7), _slide("position:x", offset + 1.2, offset), _slide("position:z", depth, depth, 4.0),
			_slide("rotation_degrees:z", 14.0, 14.0, 90.0)]
		layers.append(arrow)
	var strikes := _particles("strikes", {"start_delay": 0.15, "amount": 40, "lifetime": 0.45, "explosiveness": 0.0, "emission_radius": 0.7, "direction": Vector3.UP,
		"spread": 60.0, "speed_min": 1.5, "speed_max": 4.5, "gravity": Vector3(0, -8.0, 0), "size_min": 0.05, "size_max": 0.11})
	strikes.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	layers.append(strikes)
	layers.append(_flat_ring("mark", 0.0, 3.2, 0.55, false))
	return _define(&"fx.rainofarrows_strike", "Rain of Arrows strike", layers, [_param(&"color", FxParam.Kind.COLOR, Color(0.8, 1.0, 0.85), "Spark colour.")],
		"A volley of arrows streaks down onto the target.", &"Base")


## Shatter Chorus: sonic rings ring out from the target and glass shards burst from it.
func _shatterchorus() -> FxDefinition:
	var layers: Array = []
	for index in 3:
		var sonic := _ring("sonic%d" % index, 0.12 * index, 3.0 + 0.9 * index, 0.55, true)
		sonic.shader_params = {"ring_width": 0.1, "start_radius": 0.1, "end_radius": 0.95, "intensity": 1.8}
		layers.append(sonic)
	var shards := _particles("shards", {"start_delay": 0.2, "texture": load(TEX + "shard_sheet.png"), "h_frames": 4, "v_frames": 2, "anim_cycles": 0.0, "random_frame": true,
		"additive": false, "amount": 34, "lifetime": 0.9, "emission_radius": 0.3, "spread": 180.0, "speed_min": 3.0, "speed_max": 8.0, "gravity": Vector3(0, -4.0, 0),
		"spin_min": -400.0, "spin_max": 400.0, "size_min": 0.25, "size_max": 0.45})
	shards.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.7, 1.0])
	layers.append(shards)
	layers.append(_rim("ring", 0.0, 0.5, 0.35, 0.0, 0.0, 0.0))
	layers.append(_shake(0.2, 0.3, 0.07))
	return _define(&"fx.shatterchorus_strike", "Shatter Chorus strike", layers, [_param(&"color", FxParam.Kind.COLOR, Color(0.7, 0.95, 1.0), "Sound and glass colour.")],
		"Sonic rings ring out from the target and glass shards burst from it.", &"Center")


## Systole: a heartbeat: rings close in, thump out and thump again, and blood flies on the second beat.
func _systole() -> FxDefinition:
	var layers: Array = []
	var closing := _ring("squeeze", 0.0, 3.8, 0.35, true)
	closing.shader_params = {"ring_width": 0.09, "start_radius": 0.95, "end_radius": 0.25, "intensity": 1.6}
	layers.append(closing)
	var lub := _ring("lub", 0.34, 3.4, 0.4, true)
	layers.append(lub)
	var squeeze_two := _ring("squeeze2", 0.5, 3.8, 0.3, true)
	squeeze_two.shader_params = {"ring_width": 0.09, "start_radius": 0.95, "end_radius": 0.25, "intensity": 1.6}
	layers.append(squeeze_two)
	var dub := _ring("dub", 0.8, 4.2, 0.45, true)
	layers.append(dub)
	layers.append(_rim("pulse1", 0.34, 0.3, 0.4, 0.0, 0.0, 0.0))
	layers.append(_rim("pulse2", 0.8, 0.35, 0.4, 0.0, 0.0, 0.0))
	var blood := _particles("blood", {"start_delay": 0.8, "amount": 36, "lifetime": 0.8, "emission_radius": 0.4, "spread": 180.0, "speed_min": 2.5, "speed_max": 7.0,
		"gravity": Vector3(0, -9.0, 0), "size_min": 0.08, "size_max": 0.17, "additive": false})
	blood.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.7, 1.0])
	layers.append(blood)
	layers.append(_sub("vignette", 0.8, "screen_flash", {"color": "$color", "intensity": 0.9}))
	layers.append(_shake(0.34, 0.15, 0.05))
	layers.append(_shake(0.8, 0.25, 0.08))
	return _define(&"fx.systole_strike", "Systole strike", layers, [_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.25, 0.3), "Blood colour.")],
		"A heartbeat: rings close in, thump out and thump again, and blood flies on the second beat.", &"Center")


## Twin Beat: two drum-hit shockwaves in quick succession.
func _twinbeat() -> FxDefinition:
	var layers: Array = []
	for index in 2:
		var delay := 0.24 * index
		var thump := _flat_ring("thump%d" % index, delay, 3.4 + 0.6 * index, 0.5, true)
		thump.shader_params = {"ring_width": 0.17, "start_radius": 0.1, "end_radius": 0.95, "intensity": 1.8}
		layers.append(thump)
		var flash := _quad("flash%d" % index, "glow_3d", Vector2(2.4, 2.4), 0.16)
		flash.start_delay = delay
		flash.shader_params = {"falloff": 4.0, "fade_out": 0.6}
		flash.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 2.4)]
		layers.append(flash)
		layers.append(_shake(delay, 0.14, 0.08))
		var dust := _particles("dust%d" % index, {"start_delay": delay, "texture": load(TEX + "smoke_sheet.png"), "h_frames": 4, "v_frames": 4, "additive": false,
			"amount": 5, "lifetime": 0.9, "explosiveness": 1.0, "emission_ring_radius": 0.5, "direction": Vector3.UP, "spread": 80.0, "speed_min": 0.8, "speed_max": 1.6,
			"size_min": 0.8, "size_max": 1.2})
		dust.color = Color(0.85, 0.8, 0.8)
		dust.color_ramp = _ramp([Color(1, 1, 1, 0.6), Color(1, 1, 1, 0)], [0.0, 1.0])
		dust.bindings = []
		layers.append(dust)
	return _define(&"fx.twinbeat_strike", "Twin Beat strike", layers,
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.5, 0.8), "Shockwave colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Flash brightness.", 0.0, 4.0)],
		"Two drum-hit shockwaves in quick succession.", &"Base")


# =====================================================================================================================================
# Support
# =====================================================================================================================================

## Bastion: a hexagonal force-field dome rises around the unit.
func _bastion() -> FxDefinition:
	var material := ShaderMaterial.new()
	material.shader = load(SHADERS + "material/hex_shield.gdshader")
	var dome := FxMeshLayer.new()
	dome.id = &"dome"
	dome.mesh = _sphere(0.95)
	dome.material = material
	dome.seconds = 1.5
	dome.bindings = [_bind("material_override:shader_parameter/color", &"color"), _bind("material_override:shader_parameter/intensity", &"intensity", 1.8)]
	var presence := FxCurveTrack.new()
	presence.property = "material_override:shader_parameter/strength"
	presence.curve = _curve([[0.0, 0.0], [0.15, 1.0], [0.8, 1.0], [1.0, 0.0]])
	dome.tracks = [_scale_curve([[0.0, 0.7], [0.2, 1.05], [0.35, 1.0], [1.0, 1.0]]), presence]
	var motes := _particles("motes", {"amount": 24, "lifetime": 1.0, "emission_ring_radius": 0.9, "direction": Vector3.UP, "spread": 10.0, "speed_min": 0.8, "speed_max": 2.0,
		"gravity": Vector3.ZERO, "size_min": 0.06, "size_max": 0.12})
	motes.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.2, 1.0])
	return _define(&"fx.bastion_strike", "Bastion strike", [dome, _flat_ring("seal", 0.0, 2.8, 0.7, false), motes, _light(0.0, 2.0, 1.0)],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.4, 0.7, 1.0), "Shield colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0)],
		"A hexagonal force-field dome rises around the unit, its plates outlined in light.", &"Center")


## Combustion: the caster ignites in a column of flame.
func _combustion() -> FxDefinition:
	var column := _particles("column", {"texture": load(TEX + "flame_sheet.png"), "h_frames": 8, "v_frames": 4, "amount": 46, "lifetime": 0.95, "explosiveness": 0.3,
		"emit_from_mesh": true, "direction": Vector3.UP, "spread": 10.0, "speed_min": 3.0, "speed_max": 5.5, "damping": 0.8, "gravity": Vector3(0, 1.2, 0),
		"size_min": 1.8, "size_max": 2.7, "soft_distance": 0.3})
	column.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.15, 1.0])
	var embers := _particles("embers", {"amount": 30, "lifetime": 1.2, "emit_from_mesh": true, "direction": Vector3.UP, "spread": 40.0, "speed_min": 2.0, "speed_max": 6.0,
		"gravity": Vector3(0, -1.0, 0), "size_min": 0.06, "size_max": 0.13})
	embers.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	return _define(&"fx.combustion_strike", "Combustion strike", [column, embers, _rim("skin", 0.0, 1.0, 0.35, 0.025, 0.3, 2.0), _flat_ring("heat", 0.0, 3.4, 0.7, false),
		_light(0.0, 4.0, 0.9), _shake(0.0, 0.3, 0.06)],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.5, 0.15), "Flame colour.")],
		"The caster ignites in a column of flame.", &"Center")


## Finale: fireworks burst above the unit and music notes float up.
func _finale() -> FxDefinition:
	var rainbow := _ramp([Color(1.0, 0.4, 0.4, 1), Color(1.0, 0.9, 0.3, 1), Color(0.4, 1.0, 0.5, 1), Color(0.4, 0.7, 1.0, 0.0)], [0.0, 0.35, 0.65, 1.0])
	var rocket := _particles("rocket", {"amount": 1, "lifetime": 0.3, "explosiveness": 1.0, "direction": Vector3.UP, "spread": 0.0, "speed_min": 0.0, "speed_max": 0.0,
		"gravity": Vector3(0, 5.0, 0), "size_min": 0.18, "size_max": 0.18})
	var first := _particles("burst_a", {"start_delay": 0.3, "amount": 70, "lifetime": 1.2, "emission_offset": Vector3(0, 1.7, 0), "spread": 180.0, "speed_min": 2.5,
		"speed_max": 5.0, "damping": 1.2, "gravity": Vector3(0, -2.5, 0), "size_min": 0.1, "size_max": 0.18})
	first.color_ramp = rainbow
	first.bindings = []
	var second := _particles("burst_b", {"start_delay": 0.55, "amount": 60, "lifetime": 1.1, "emission_offset": Vector3(0.9, 1.3, 0.2), "spread": 180.0, "speed_min": 2.0,
		"speed_max": 4.5, "damping": 1.2, "gravity": Vector3(0, -2.5, 0), "size_min": 0.1, "size_max": 0.17})
	second.color_ramp = rainbow
	second.bindings = []
	var notes := _particles("notes", {"texture": load(TEX + "note_sheet.png"), "amount": 10, "lifetime": 1.6, "explosiveness": 0.2, "emission_ring_radius": 0.7,
		"direction": Vector3.UP, "spread": 20.0, "speed_min": 0.8, "speed_max": 1.6, "gravity": Vector3(0, 0.4, 0), "spin_min": -50.0, "spin_max": 50.0, "size_min": 0.3,
		"size_max": 0.42})
	notes.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.2, 1.0])
	return _define(&"fx.finale_strike", "Finale strike", [rocket, first, second, notes, _ring("sparkle", 0.3, 3.0, 0.5, true), _sub("flash", 0.3, "screen_flash", {"color": "$color", "intensity": 0.4})],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.85, 0.35), "Notes and flash colour.")],
		"Two fireworks burst above the unit in rainbow colours and music notes float up.", &"Center")


## Resurrection: a column of golden fire with drifting feathers and spreading wings of light.
func _resurrection() -> FxDefinition:
	var fire := _particles("fire", {"texture": load(TEX + "flame_sheet.png"), "h_frames": 8, "v_frames": 4, "amount": 28, "lifetime": 1.2, "explosiveness": 0.1,
		"emission_ring_radius": 0.4, "direction": Vector3.UP, "spread": 5.0, "speed_min": 2.5, "speed_max": 4.5, "gravity": Vector3(0, 0.8, 0), "size_min": 1.4, "size_max": 2.0,
		"soft_distance": 0.3})
	fire.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.2, 1.0])
	var feathers := _particles("feathers", {"texture": load(TEX + "feather_sheet.png"), "amount": 18, "lifetime": 1.8, "explosiveness": 0.15, "emission_ring_radius": 0.5,
		"direction": Vector3.UP, "spread": 30.0, "speed_min": 0.8, "speed_max": 2.0, "gravity": Vector3(0, 0.6, 0), "spin_min": -120.0, "spin_max": 120.0, "size_min": 0.5,
		"size_max": 0.75})
	feathers.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.2, 1.0])
	var layers: Array = [fire, feathers]
	for side in [-1.0, 1.0]:
		var wing := _quad("wing%s" % ("l" if side < 0 else "r"), "glow_3d", Vector2(1.8, 2.6), 1.1)
		wing.start_delay = 0.2
		wing.shader_params = {"falloff": 2.6, "fade_out": 0.7}
		wing.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.6)]
		wing.tracks = [_slide("position:x", side * 0.5, side * 1.1, 4.0), _slide("rotation_degrees:z", side * 10.0, side * 35.0, 90.0)]
		layers.append(wing)
	layers.append(_flat_ring("halo", 0.0, 3.2, 0.8, true))
	layers.append(_light(0.0, 4.0, 1.0))
	return _define(&"fx.resurrection_strike", "Resurrection strike", layers,
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.92, 0.6), "Flame and wing colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Wing brightness.", 0.0, 4.0)],
		"A column of golden fire with drifting feathers and spreading wings of light.", &"Base")


## Sanctuary: a turning holy circle on the ground with light rising from it.
func _sanctuary() -> FxDefinition:
	var circle := _flat_quad("circle", "rune_circle", 0.0, 3.6, 1.7)
	circle.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 1.6)]
	var motes := _particles("motes", {"amount": 34, "lifetime": 1.4, "explosiveness": 0.0, "emission_ring_radius": 0.9, "direction": Vector3.UP, "spread": 8.0,
		"speed_min": 0.9, "speed_max": 2.0, "gravity": Vector3.ZERO, "size_min": 0.07, "size_max": 0.14})
	motes.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 0.2, 1.0])
	var pillar := _quad("pillar", "glow_3d", Vector2(1.7, 3.6), 1.4)
	pillar.shader_params = {"falloff": 5.0, "fade_out": 0.7}
	pillar.bindings = [_bind("material:shader_parameter/color", &"color"), _bind("material:shader_parameter/intensity", &"intensity", 0.7)]
	pillar.tracks = [_slide("position:y", 1.6, 1.6)]
	return _define(&"fx.sanctuary_strike", "Sanctuary strike", [circle, pillar, motes, _light(0.0, 2.0, 1.2)],
		[_param(&"color", FxParam.Kind.COLOR, Color(0.55, 1.0, 0.7), "Holy light colour."), _param(&"intensity", FxParam.Kind.FLOAT, 1.0, "Brightness.", 0.0, 4.0)],
		"A turning holy circle on the ground with light rising from it.", &"Base")


# =====================================================================================================================================
# Helpers
# =====================================================================================================================================

## A particle layer with properties set from a dictionary (the colour binding and the unit-radius bias are added by _define).
func _particles(layer_id: StringName, props: Dictionary) -> FxParticles3DLayer:
	var layer := FxParticles3DLayer.new()
	layer.id = layer_id
	layer.amount = 20
	layer.lifetime = 0.8
	layer.speed_min = 0.0
	layer.speed_max = 0.0
	layer.gravity = Vector3.ZERO
	for key in props:
		if key == "emission_sphere":
			layer.emission_radius = props[key]
		else:
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


## A ring facing the camera (burst_3d), around the unit's middle by default.
func _ring(layer_id: StringName, delay: float, size: float, seconds: float, bound: bool) -> FxShaderQuadLayer:
	var ring := _quad(layer_id, "burst_3d", Vector2(size, size), seconds)
	ring.start_delay = delay
	ring.shader_params = {"ring_width": 0.07, "start_radius": 0.15, "end_radius": 0.95, "intensity": 1.6}
	if bound:
		ring.bindings = [_bind("material:shader_parameter/color", &"color")]
	return ring


## A ring lying flat on the floor (the quad turned to face up), at the Base socket.
func _flat_ring(layer_id: StringName, delay: float, size: float, seconds: float, bound: bool) -> FxShaderQuadLayer:
	var ring := _flat_quad(layer_id, "burst_3d", delay, size, seconds)
	ring.shader_params = {"ring_width": 0.07, "start_radius": 0.2, "end_radius": 0.95, "intensity": 1.6}
	if bound:
		ring.bindings = [_bind("material:shader_parameter/color", &"color")]
	else:
		ring.bindings = [_bind("material:shader_parameter/color", &"color")]
	return ring


## Any flat floor quad shader (a rune circle, ground cracks).
func _flat_quad(layer_id: StringName, shader_name: String, delay: float, size: float, seconds: float) -> FxShaderQuadLayer:
	var quad := _quad(layer_id, shader_name, Vector2(size, size), seconds)
	quad.socket = &"Base"
	quad.face_camera = false
	quad.start_delay = delay
	quad.tracks = [_slide("rotation_degrees:x", -90.0, -90.0, 360.0)]
	return quad


func _mesh_layer(layer_id: StringName, mesh: Mesh, material: Material, seconds: float, bind_property: String) -> FxMeshLayer:
	var layer := FxMeshLayer.new()
	layer.id = layer_id
	layer.mesh = mesh
	layer.material = material
	layer.seconds = seconds
	if bind_property == "material_override:albedo_color" or bind_property == "material_override:emission":
		layer.bindings = [_bind(bind_property, &"color")]
	return layer


func _sphere(radius: float) -> SphereMesh:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	return sphere


## An unshaded, additive, see-through material for glowing solids (a star, a spear, an arrow).
func _emissive(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.albedo_color = colour
	return material


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


## A property moved from `from` to `to` over the layer's life (ADD: relative to where it started).
func _slide(property: String, from: float, to: float, bound: float = 8.0) -> FxCurveTrack:
	var track := FxCurveTrack.new()
	track.property = property
	track.mode = FxCurveTrack.Mode.ADD
	track.curve = _curve([[0.0, from], [1.0, to]], -bound, bound)
	return track


## The node's scale multiplied by a curve over its life.
func _scale_curve(points: Array) -> FxCurveTrack:
	var track := FxCurveTrack.new()
	track.property = "scale"
	track.mode = FxCurveTrack.Mode.MULTIPLY
	track.curve = _curve(points, 0.0, 8.0)
	return track


## A colour property's alpha over the layer's life.
func _alpha_curve(property: String, points: Array) -> FxCurveTrack:
	var track := FxCurveTrack.new()
	track.property = property
	track.mode = FxCurveTrack.Mode.SET
	track.color_channel = FxCurveTrack.ColorChannel.ALPHA
	track.curve = _curve(points)
	return track


## A spike's height: below the floor, up fast, held, then sinking back down.
func _rise_and_sink(height: float) -> FxCurveTrack:
	var track := FxCurveTrack.new()
	track.property = "position:y"
	track.mode = FxCurveTrack.Mode.ADD
	track.curve = _curve([[0.0, -height - 0.8], [0.18, height * 0.5], [0.3, height * 0.5], [0.72, height * 0.5], [1.0, -height - 0.8]], -4.0, 4.0)
	return track


func _define(effect_id: StringName, title: String, layers: Array, params: Array, note: String, socket: StringName) -> FxDefinition:
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
		push_error("build_vfx_signatures2: cannot write %s" % path)
		return definition
	_written.append(path)
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as FxDefinition


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
