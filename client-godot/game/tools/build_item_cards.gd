## Spec item-cards 3.3: the floor items' effects and the concept round's look. Creates new files only and never overwrites one
## (`--force` rewrites this builder's own files, which discards tuning), then adds the new effects to the registry through
## RegistryPatch (the approved additive patch):
##   presentation/demo/fx/item_aura.tres        fx.item_aura: the tiered aura (parameters color, tier 0..3)
##   presentation/demo/style/items/item_card_look.tres  the ItemCardLook the console's `style items` shows
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_item_cards.tscn [-- --force]
extends "res://game/tools/build_fx_set.gd"

const LOOK_PATH: String = ItemCardLook.DEFAULT_PATH
const RIBBON_SHADER: String = "res://game/fx/shaders/material/item_ribbons.gdshader"


func _ready() -> void:
	_force = OS.get_cmdline_user_args().has("--force")
	var aura := _save_definition(_aura())
	_save_look(aura)
	var added := RegistryPatch.add_missing_effects()
	print("build_item_cards: wrote %d, kept %d existing; registry: %s" % [_written.size(), _kept.size(), added])
	for path in _written:
		print("  wrote ", path)
	for path in _kept:
		print("  kept  ", path)
	get_tree().quit()


## A float binding through a curve over the tier (0..3 → the curve's x 0..1), one value per tier.
func _tier_bind(property: String, values: Array) -> FxBinding:
	var binding := _bind(property, &"tier")
	var top := 0.0
	for value in values:
		top = maxf(top, value)
	binding.curve = _curve([[0.0, values[0]], [1.0 / 3.0, values[1]], [2.0 / 3.0, values[2]], [1.0, values[3]]], 0.0, maxf(top, 1.0))
	for i in binding.curve.point_count:  # straight lines between the tiers (the tiers sit on the points)
		binding.curve.set_point_left_mode(i, Curve.TANGENT_LINEAR)
		binding.curve.set_point_right_mode(i, Curve.TANGENT_LINEAR)
	return binding


func _flat(value: float, low: float, high: float) -> Curve:
	return _curve([[0.0, value], [1.0, value]], low, high)


## Spec 2.2: the floor disc and glow pool, motes, sparks (Epic up) and the rising ribbons (Legendary), each gated by the tier.
func _aura() -> FxDefinition:
	var pool := _quad(&"pool", "glow_3d", true)
	pool.face_camera = false
	pool.size = Vector2(1.1, 1.1)
	pool.socket = &"Base"
	pool.loop = true
	pool.loop_period = 10.0
	pool.shader_params = {"falloff": 2.8, "fade_out": 0.0, "pulse_speed": 0.45, "pulse_amount": 0.3}
	pool.bindings = [_bind("material:shader_parameter/color", &"color"),
		_tier_bind("material:shader_parameter/intensity", [0.15, 0.45, 0.55, 1.4])]
	pool.tracks = [_track("rotation_degrees:x", _flat(-90.0, -360.0, 360.0), FxCurveTrack.Mode.SET)]

	var motes := FxParticles3DLayer.new()
	motes.id = &"motes"
	motes.socket = &"Base"
	motes.loop = true
	motes.amount = 14
	motes.lifetime = 2.2
	motes.explosiveness = 0.0
	motes.emission_ring_radius = 0.32
	motes.emission_offset = Vector3(0, 0.1, 0)
	motes.direction = Vector3.UP
	motes.spread = 20.0
	motes.speed_min = 0.12
	motes.speed_max = 0.3
	motes.gravity = Vector3(0, 0.08, 0)
	motes.size_min = 0.05
	motes.size_max = 0.1
	motes.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.6), Color(1, 1, 1, 0)], [0.0, 0.2, 0.6, 1.0])
	motes.bindings = [_bind("process_material:color", &"color"), _tier_bind("amount_ratio", [0.3, 0.6, 0.8, 1.0])]

	var sparks := FxParticles3DLayer.new()
	sparks.id = &"sparks"
	sparks.socket = &"Base"
	sparks.loop = true
	sparks.min_quality = FxLayer.Quality.MEDIUM
	sparks.amount = 10
	sparks.lifetime = 0.7
	sparks.explosiveness = 0.0
	sparks.emission_radius = 0.28
	sparks.emission_offset = Vector3(0, 0.7, 0)
	sparks.direction = Vector3.UP
	sparks.spread = 50.0
	sparks.speed_min = 0.6
	sparks.speed_max = 1.3
	sparks.gravity = Vector3(0, -1.2, 0)
	sparks.size_min = 0.025
	sparks.size_max = 0.05
	sparks.color_ramp = _ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)], [0.0, 1.0])
	sparks.bindings = [_bind("process_material:color", &"color", 1.4), _tier_bind("amount_ratio", [0.0, 0.0, 1.0, 1.0])]

	var ribbons := FxMeshLayer.new()
	ribbons.id = &"ribbons"
	ribbons.socket = &"Base"
	ribbons.loop = true
	ribbons.seconds = 1000000.0
	ribbons.min_quality = FxLayer.Quality.MEDIUM
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.3
	cylinder.bottom_radius = 0.42
	cylinder.height = 1.5
	cylinder.radial_segments = 48
	cylinder.rings = 1
	cylinder.cap_top = false
	cylinder.cap_bottom = false
	ribbons.mesh = cylinder
	var material := ShaderMaterial.new()
	material.shader = load(RIBBON_SHADER)
	ribbons.material = material
	ribbons.bindings = [_bind("material_override:shader_parameter/color", &"color"),
		_tier_bind("material_override:shader_parameter/strength", [0.0, 0.0, 0.0, 1.0])]
	ribbons.tracks = [_track("position:y", _flat(0.75, 0.0, 2.0), FxCurveTrack.Mode.SET)]

	return _define(&"fx.item_aura", "Item aura", FxDefinition.Space.WORLD_3D, [pool, motes, sparks, ribbons],
		[_param(&"color", FxParam.Kind.COLOR, Color(1.0, 0.75, 0.3), 0, 0, "The item's rarity colour (the floor map; magenta when corrupted)."),
		_param(&"tier", FxParam.Kind.FLOAT, 0.0, 0.0, 3.0, "0 Common, 1 Rare, 2 Epic, 3 Legendary (and corrupted): which layers show and how bright.")],
		"A floor pickup's aura in Risk of Rain 2's tiers (spec item-cards 2.2): a glow under it and motes, sparks from Epic, rising ribbons and a bright pool at Legendary.",
		[&"Fx.Kind.Aura"])


func _save_look(aura: FxDefinition) -> void:
	if FileAccess.file_exists(LOOK_PATH) and not _force:
		_kept.append(LOOK_PATH)
		return
	DirAccess.make_dir_recursive_absolute(LOOK_PATH.get_base_dir())
	var look := ItemCardLook.new()
	look.aura = aura
	var error := BuilderSave.save(look, LOOK_PATH)
	if error != OK:
		push_error("build_item_cards: cannot write %s (%s)" % [LOOK_PATH, error_string(error)])
		return
	_written.append(LOOK_PATH)
