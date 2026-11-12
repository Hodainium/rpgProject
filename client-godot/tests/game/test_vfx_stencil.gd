## Spec vfx-stencil, step 1: the stencil value table, stamping a unit view, the anchor carrying its unit's value, the shader copies
## and the 3D shader quad drawing in two passes, and stencil off drawing one pass. Built in memory, no presentation/ files. What the
## pixels look like needs a GPU: the windowed probe (game/tools/fx_stencil_probe.tscn, game/dev/fx_stencil_stage.tscn --compare).
extends TestCase

const GLOW := "res://game/fx/shaders/glow_3d.gdshader"
const INCLUDE := "res://game/fx/shaders/fx_stencil_depth.gdshaderinc"

var _nodes: Array[Node] = []
var _services: Array[FxService] = []


func after_each() -> void:
	FxStencilShaders.mode = FxStencilShaders.DEFAULT_MODE  # every other test runs in the default mode
	FxStencilShaders.clear()
	for service in _services:
		if is_instance_valid(service):
			service.stop_all()
			service.free()
	for node in _nodes:
		if is_instance_valid(node):
			node.free()
	_services.clear()
	_nodes.clear()
	super()


func _keep(node: Node) -> Node:
	host.add_child(node)
	_nodes.append(node)
	return node


func _view(unit_id: StringName) -> UnitAnimator:
	var view := UnitAnimator.new()
	view.unit_id = unit_id
	_keep(view)
	return view


func _glow_layer(facing: bool = true) -> FxShaderQuadLayer:
	var layer := FxShaderQuadLayer.new()
	layer.id = &"glow"
	layer.space = FxLayer.Space.WORLD_3D
	layer.shader = load(GLOW)
	layer.face_camera = facing
	layer.shader_params = {"intensity": 2.5}
	return layer


func _anchor(value: int) -> FxAnchor:
	var anchor := FxAnchor.new()
	anchor.kind = FxAnchor.Kind.NODE3D
	anchor.stencil_value = value
	return anchor


# --- The table (3.1) ---------------------------------------------------------------------------------------------------

func test_ranges_do_not_overlap_and_constants_sit_inside_them() -> void:
	var taken := {}
	for range_name in StencilIds.RANGES:
		var bounds: Array = StencilIds.RANGES[range_name]
		check(bounds[0] <= bounds[1] and bounds[0] >= 0 and bounds[1] <= 255, "%s is a valid range" % range_name)
		for value in range(bounds[0], bounds[1] + 1):
			check(not taken.has(value), "value %d is in one range only (%s and %s)" % [value, taken.get(value, ""), range_name])
			taken[value] = range_name
	eq(StencilIds.NONE, 0, "0 is NONE, the cleared value")
	eq([StencilIds.PARTY_FIRST, StencilIds.ADDED_LAST], [StencilIds.UNIT_FIRST, StencilIds.UNIT_LAST], "party to added units span the unit range")
	check(StencilIds.PARTY_LAST + 1 == StencilIds.ENEMY_FIRST and StencilIds.ENEMY_LAST + 1 == StencilIds.ADDED_FIRST,
		"party, enemy and added ranges follow each other")


func test_values_follow_battle_positions() -> void:
	eq([StencilIds.for_unit_id(&"P1"), StencilIds.for_unit_id(&"P4")], [1, 4], "party positions 1-4")
	eq([StencilIds.for_unit_id(&"E1"), StencilIds.for_unit_id(&"E3"), StencilIds.for_unit_id(&"E20")], [5, 7, 24],
		"enemy slot n is 4 + n")
	eq([StencilIds.for_unit_id(&"E21"), StencilIds.for_unit_id(&"P5"), StencilIds.for_unit_id(&"X1"), StencilIds.for_unit_id(&"P")],
		[0, 0, 0, 0], "a position outside the table, or another id, has no value")
	eq([StencilIds.for_added(1), StencilIds.for_added(7), StencilIds.for_added(8)], [25, 31, 0], "added units 25-31, then none")


# --- Stamping a unit view (3.2) -----------------------------------------------------------------------------------------

func test_mark_stencil_stamps_a_copy_of_an_opaque_pass_material() -> void:
	var view := _view(&"P2")
	view.stencil_value = 2
	var shared := StandardMaterial3D.new()
	var opaque := view.mark_stencil(shared) as BaseMaterial3D
	eq([opaque.stencil_mode, opaque.stencil_flags, opaque.stencil_compare, opaque.stencil_reference],
		[BaseMaterial3D.STENCIL_MODE_CUSTOM, BaseMaterial3D.STENCIL_FLAG_WRITE, BaseMaterial3D.STENCIL_COMPARE_ALWAYS, 2],
		"an opaque StandardMaterial3D writes the value, compare always")
	eq([opaque.transparency, opaque.render_priority], [BaseMaterial3D.TRANSPARENCY_DISABLED, 0], "and stays opaque at its priority (K1)")
	check(opaque != shared and shared.stencil_mode == BaseMaterial3D.STENCIL_MODE_DISABLED,
		"a copy is stamped: a material shared by several views never carries another view's value")
	var scissor := StandardMaterial3D.new()
	scissor.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	eq((view.mark_stencil(scissor) as BaseMaterial3D).stencil_reference, 2, "alpha scissor draws in the opaque pass: stamped")
	eq(view.effect_stencil_value(), 2, "a stamped view gives its effects its value")
	view.stencil_value = 0
	var unmarked := StandardMaterial3D.new()
	check(view.mark_stencil(unmarked) == unmarked and unmarked.stencil_mode == BaseMaterial3D.STENCIL_MODE_DISABLED,
		"value 0 stamps nothing")


func test_a_view_that_cannot_be_stamped_gives_its_effects_no_value() -> void:
	var view := _view(&"P3")
	view.stencil_value = 3
	var see_through := StandardMaterial3D.new()
	see_through.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	check(view.mark_stencil(see_through) == see_through and see_through.stencil_mode == BaseMaterial3D.STENCIL_MODE_DISABLED,
		"a blending material is not stamped (its stamp could land after the effects tested)")
	eq(view.effect_stencil_value(), 0, "so its effects draw once with the plain depth test")
	var other := _view(&"P4")
	other.stencil_value = 4
	var shader_material := ShaderMaterial.new()
	check(other.mark_stencil(shader_material) == shader_material, "a shader material comes back untouched (step 2 adds the unit include)")
	eq(other.effect_stencil_value(), 0, "and that view's effects draw once too")
	var bare := _view(&"E5")
	bare.stencil_value = 9
	eq(bare.effect_stencil_value(), 0, "a view whose paint never stamps (the base _paint) gives no value")


func test_the_latest_paint_decides_whether_a_view_is_stamped() -> void:
	var view := _view(&"P1")
	view.stencil_value = 1
	view.mark_stencil(StandardMaterial3D.new())
	eq(view.effect_stencil_value(), 1, "solid: stamped")
	var fading := StandardMaterial3D.new()
	fading.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	view.mark_stencil(fading)
	eq(view.effect_stencil_value(), 0, "fading out: not stamped, effects draw once")
	view.mark_stencil(StandardMaterial3D.new())
	eq(view.effect_stencil_value(), 1, "solid again (revived): stamped again")


func test_assign_stencil_follows_the_mode() -> void:
	var view := _view(&"E2")
	FxStencilShaders.mode = FxStencilShaders.OFF
	view.assign_stencil()
	eq(view.stencil_value, 0, "off: no value")
	FxStencilShaders.mode = FxStencilShaders.STENCIL
	view.assign_stencil()
	eq(view.stencil_value, 6, "stencil mode: E2's position value")


# --- The anchor (3.3) ---------------------------------------------------------------------------------------------------

func test_a_placed_anchor_carries_its_unit_value() -> void:
	var view := _view(&"P3")
	view.stencil_value = 3
	view.mark_stencil(StandardMaterial3D.new())
	eq(FxAnchor.node3d(view).placed(&"Center").stencil_value, 3, "an anchor on a stamped unit view takes its value")
	var on_stage := FxAnchor.node3d(view)
	on_stage.kind = FxAnchor.Kind.STAGE
	eq(on_stage.placed(&"Center").stencil_value, 0, "a stage anchor takes none: the stage's world is not stamped")
	eq(FxAnchor.node3d(_keep(Node3D.new())).placed(&"Center").stencil_value, 0, "an anchor on a plain node has none")
	eq(FxAnchor.position3d(Vector3.ONE).placed(&"Center").stencil_value, 0, "nor does a position")


func test_an_effect_on_a_unit_gets_its_value_through_the_service() -> void:
	FxStencilShaders.mode = FxStencilShaders.STENCIL
	var service := FxService.new()
	service.enabled = true
	service.manual_clock = true
	host.add_child(service)
	_services.append(service)
	var view := _view(&"E1")
	view.assign_stencil()
	view.mark_stencil(StandardMaterial3D.new())  # what the cube's _paint does
	var def := FxDefinition.new()
	def.id = &"fx.stencil_test"
	def.space = FxDefinition.Space.WORLD_3D
	def.layers = [_glow_layer()]
	service.register(def)
	var handle := service.play(def, FxAnchor.unit(&"E1"))
	service.advance(0.01)
	eq(handle.anchor.stencil_value, 5, "the effect's anchor carries E1's value")
	var quads := host.find_children("*", "FxQuad3D", true, false)
	check(not quads.is_empty(), "the glow quad is in the world")
	var material := (quads[0] as FxQuad3D).material as ShaderMaterial
	check(material.shader.code.begins_with(FxStencilShaders.defines(5, FxStencilShaders.Pass.OTHER)),
		"its material is the OTHER pass of the copy for 5")
	check(material.next_pass is ShaderMaterial, "with the OWN pass as next_pass")
	handle.stop(0.0)


# --- The copies and the quad layer (3.4) --------------------------------------------------------------------------------

func test_a_copy_is_the_defines_in_front_of_the_unchanged_code() -> void:
	var glow: Shader = load(GLOW)
	var original := glow.code
	var own := FxStencilShaders.variant(glow, 7, FxStencilShaders.Pass.OWN)
	var other := FxStencilShaders.variant(glow, 7, FxStencilShaders.Pass.OTHER)
	eq(own.code, "#define FX_STENCIL_REF 7\n#define FX_STENCIL_COMPARE compare_equal\n#define FX_STENCIL_OWN\n" + original,
		"OWN: the value, compare_equal and the OWN mark, then the original code")
	eq(other.code, "#define FX_STENCIL_REF 7\n#define FX_STENCIL_COMPARE compare_not_equal\n" + original,
		"OTHER: the value and compare_not_equal")
	eq(glow.code, original, "the shader file's own code is untouched")
	check(FxStencilShaders.variant(glow, 7, FxStencilShaders.Pass.OWN) == own, "the same key returns the same copy")
	eq(FxStencilShaders.prepare_values([glow], [1, 2, 7]), 4, "preparing 1, 2 and 7 makes only the 4 copies not made yet")
	eq(FxStencilShaders.cached_count(), 6, "3 values x 2 passes cached")


func test_an_edited_shader_gets_fresh_copies_and_names() -> void:
	var shader := Shader.new()
	shader.code = "shader_type spatial;\nuniform float a = 1.0;\n"
	var first := FxStencilShaders.variant(shader, 3, FxStencilShaders.Pass.OTHER)
	eq(FxStencilShaders.uniform_names(shader), [&"a"] as Array[StringName], "the uniform names are read")
	shader.code = "shader_type spatial;\nuniform float a = 1.0;\nuniform float b = 2.0;\n"
	var second := FxStencilShaders.variant(shader, 3, FxStencilShaders.Pass.OTHER)
	check(second != first and second.code.ends_with(shader.code), "an edited shader (a hot reload) gets a fresh copy of its new code")
	eq(FxStencilShaders.uniform_names(shader), [&"a", &"b"] as Array[StringName], "and its names are read again")
	eq(FxStencilShaders.uniform_names(second), [&"a", &"b"] as Array[StringName], "a copy has the same names")


func test_a_test_service_leaving_does_not_drop_the_copies() -> void:
	var glow: Shader = load(GLOW)
	var copy := FxStencilShaders.variant(glow, 9, FxStencilShaders.Pass.OWN)
	var service := FxService.new()
	host.add_child(service)
	service.free()
	check(FxStencilShaders.variant(glow, 9, FxStencilShaders.Pass.OWN) == copy, "only FxManager's shutdown clears the cache")


func test_the_include_keeps_every_stencil_line_behind_the_defines() -> void:
	if skip_in_export():
		return
	var text := FileAccess.get_file_as_string(INCLUDE)
	var depth := 0
	var outside: Array[String] = []
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("#if"):
			depth += 1
		elif trimmed.begins_with("#endif"):
			depth -= 1
		elif depth == 0 and (trimmed.begins_with("stencil_mode") or trimmed.begins_with("render_mode")):
			outside.append(trimmed)
	eq(outside, [] as Array[String], "no stencil_mode or render_mode line outside an #if block: without defines the shader is today's")


func test_the_quad_switches_to_two_passes_and_back_keeping_its_parameters() -> void:
	var layer := _glow_layer()
	var quad := layer.build() as FxQuad3D
	_keep(quad)
	(quad.material as ShaderMaterial).set_shader_parameter(&"color", Color(0.1, 0.2, 0.3))
	FxStencilShaders.mode = FxStencilShaders.STENCIL
	layer.apply(quad, {}, _anchor(4), 3, null)
	var material := quad.material as ShaderMaterial
	var own := material.next_pass as ShaderMaterial
	check(own != null and own.shader.code.contains("#define FX_STENCIL_OWN"), "stencil mode: an OWN pass is added")
	eq(material.get_shader_parameter(&"color"), Color(0.1, 0.2, 0.3), "the OTHER pass keeps the parameter set before the switch")
	eq(own.get_shader_parameter(&"intensity"), 2.5, "the OWN pass mirrors the layer's parameters")
	material.set_shader_parameter(&"progress", 0.6)
	layer.update(quad, 0.3, 1.0, {})
	eq(own.get_shader_parameter(&"progress"), material.get_shader_parameter(&"progress"), "updates reach the OWN pass")
	FxStencilShaders.mode = FxStencilShaders.OFF
	layer.apply(quad, {}, _anchor(4), 3, null)
	check(material.shader == layer.shader and material.next_pass == null, "off: the layer's own shader, one pass")
	eq(material.get_shader_parameter(&"color"), Color(0.1, 0.2, 0.3), "parameters survive the way back")


func test_which_quads_draw_over_their_unit() -> void:
	FxStencilShaders.mode = FxStencilShaders.STENCIL
	eq(_glow_layer(true).stencil_for(_anchor(4)), 4, "a camera-facing quad draws over its unit")
	eq(_glow_layer(false).stencil_for(_anchor(4)), 0, "a flat floor quad keeps the plain depth test")
	var forced := _glow_layer(false)
	forced.over_own_unit = FxLayer.OverOwnUnit.ON
	eq(forced.stencil_for(_anchor(4)), 4, "unless the layer says ON")
	var never := _glow_layer(true)
	never.over_own_unit = FxLayer.OverOwnUnit.OFF
	eq(never.stencil_for(_anchor(4)), 0, "and OFF turns it off")
	eq(_glow_layer(true).stencil_for(_anchor(0)), 0, "no unit value: none")
	eq(_glow_layer(true).stencil_for(_anchor(StencilIds.DEV)), 0, "a value outside the unit range: none")
	FxStencilShaders.mode = FxStencilShaders.OFF
	eq(_glow_layer(true).stencil_for(_anchor(4)), 0, "off: never")


func test_a_shader_without_the_stencil_include_stays_one_pass() -> void:
	FxStencilShaders.mode = FxStencilShaders.STENCIL
	var plain := Shader.new()
	plain.code = "shader_type spatial;
render_mode unshaded, blend_add;
uniform float progress = 0.0;
void fragment() { ALBEDO = vec3(1.0); }
"
	var layer := _glow_layer()
	layer.shader = plain
	eq(layer.stencil_for(_anchor(4)), 0, "no include, no stencil lines: it would draw its whole effect twice")
	check(not FxStencilShaders.supports(plain) and FxStencilShaders.supports(load(GLOW)), "supports() is the include")
	var named_only := Shader.new()
	named_only.code = "shader_type spatial;\n// works like fx_stencil_depth.gdshaderinc, but does not include it\nvoid fragment() { ALBEDO = vec3(1.0); }\n"
	check(not FxStencilShaders.supports(named_only), "a comment naming the file is not the include")


func test_a_live_effect_follows_its_unit_stamp_and_the_mode() -> void:
	FxStencilShaders.mode = FxStencilShaders.STENCIL
	var view := _view(&"E2")
	view.assign_stencil()
	view.mark_stencil(StandardMaterial3D.new())
	var layer := _glow_layer()
	var quad := layer.build() as FxQuad3D
	_keep(quad)
	layer.apply(quad, {}, FxAnchor.node3d(view).placed(&"Center"), 3, null)
	var material := quad.material as FxStencilMaterial
	eq(material.stencil_unit, 6, "it starts over E2")
	var fading := StandardMaterial3D.new()
	fading.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	view.mark_stencil(fading)
	layer.update(quad, 0.1, 1.0, {})
	check(material.stencil_unit == 0 and material.next_pass == null, "E2 fades out: the live effect goes back to one pass")
	view.mark_stencil(StandardMaterial3D.new())
	layer.update(quad, 0.2, 1.0, {})
	eq(material.stencil_unit, 6, "E2 solid again: over it again")
	FxStencilShaders.mode = FxStencilShaders.OFF
	layer.update(quad, 0.3, 1.0, {})
	check(material.stencil_unit == 0 and material.shader == layer.shader, "the switch turned off reaches a live effect")


# --- The material with a stencil setting (3.4) --------------------------------------------------------------------------

func test_the_stencil_material_swaps_on_its_setting_and_follows_an_edited_shader() -> void:
	var base := Shader.new()
	base.code = (load(GLOW) as Shader).code
	var material := FxStencilMaterial.new()
	material.base_shader = base
	material.set_shader_parameter(&"intensity", 3.0)
	check(material.shader == base and material.next_pass == null, "unit 0: the base shader, one pass")
	material.stencil_unit = 5
	check(material.shader.code.contains("#define FX_STENCIL_REF 5") and material.next_pass is ShaderMaterial, "unit 5: the OTHER copy and an OWN pass")
	eq((material.next_pass as ShaderMaterial).get_shader_parameter(&"intensity"), 3.0, "the OWN pass mirrors the parameters")
	var old_copy := material.shader
	base.code = base.code + "
// edited
"
	material.refresh()
	check(material.shader != old_copy and material.shader.code.ends_with("// edited
"), "an edited base shader: fresh copies on refresh")
	eq(material.get_shader_parameter(&"intensity"), 3.0, "parameters survive the swap")
	material.stencil_unit = 0
	check(material.shader == base and material.next_pass == null, "back to 0: the base shader, one pass")


# --- Step 2: particles, meshes, the caller's value, the validator, the console, prepare ------------------------------------

func _particles_layer() -> FxParticles3DLayer:
	var layer := FxParticles3DLayer.new()
	layer.id = &"sparks"
	return layer


func test_particles_draw_over_their_unit_through_their_generated_material() -> void:
	FxStencilShaders.mode = FxStencilShaders.STENCIL
	var layer := _particles_layer()
	var node := _keep(layer.build()) as GPUParticles3D
	var material := (node.draw_pass_1 as PrimitiveMesh).material as FxStencilMaterial
	check(material != null and material.base_shader == FxParticles3DLayer.PARTICLE_SHADER, "the generated draw material has a stencil setting")
	layer.apply(node, {}, _anchor(7), 3, null)
	eq(material.stencil_unit, 7, "AUTO: particles draw over their unit")
	check(material.next_pass is ShaderMaterial, "with an OWN pass")
	eq(layer.stencil_shader(), FxParticles3DLayer.PARTICLE_SHADER, "prepare() compiles the particle shader")
	var custom := _particles_layer()
	custom.draw_mesh = QuadMesh.new()
	eq(custom.stencil_shader(), null, "a custom draw mesh keeps its own material: nothing to prepare")
	custom.over_own_unit = FxLayer.OverOwnUnit.ON
	check(custom.extra_problems(null, null).size() == 1 and custom.extra_problems(null, null)[0].begins_with("fx_stencil_include_missing"),
		"and told to draw over its unit, it is reported")


func test_a_mesh_layer_takes_part_only_when_asked_and_its_shader_can() -> void:
	FxStencilShaders.mode = FxStencilShaders.STENCIL
	var source := ShaderMaterial.new()
	source.shader = load(GLOW)
	source.set_shader_parameter(&"intensity", 4.0)
	var layer := FxMeshLayer.new()
	layer.id = &"shell"
	layer.mesh = SphereMesh.new()
	layer.material = source
	var node := _keep(layer.build()) as MeshInstance3D
	var material := node.material_override as FxStencilMaterial
	check(material != null and material != source, "a stencil-capable shader material becomes the layer's own FxStencilMaterial")
	eq(material.get_shader_parameter(&"intensity"), 4.0, "with every value carried over")
	layer.apply(node, {}, _anchor(3), 3, null)
	eq(material.stencil_unit, 0, "AUTO: a solid mesh keeps the plain depth test")
	layer.over_own_unit = FxLayer.OverOwnUnit.ON
	layer.apply(node, {}, _anchor(3), 3, null)
	eq(material.stencil_unit, 3, "ON: a shell around the unit draws over it")
	var plain := FxMeshLayer.new()
	plain.id = &"rock"
	plain.material = StandardMaterial3D.new()
	plain.over_own_unit = FxLayer.OverOwnUnit.ON
	check(plain.extra_problems(null, null).size() == 2, "ON with a material that cannot (and no mesh) is reported")


func test_a_caller_can_mark_another_unit() -> void:
	FxStencilShaders.mode = FxStencilShaders.STENCIL
	var service := FxService.new()
	service.enabled = true
	service.manual_clock = true
	host.add_child(service)
	_services.append(service)
	var target := _view(&"E1")
	target.assign_stencil()
	target.mark_stencil(StandardMaterial3D.new())
	var def := FxDefinition.new()
	def.id = &"fx.stencil_beam"
	def.space = FxDefinition.Space.WORLD_3D
	def.layers = [_glow_layer()]
	service.register(def)
	var handle := service.play(def, FxAnchor.unit(&"E1"), {&"stencil_unit": 2})
	check(handle.anchor.stencil_value == 2 and handle.anchor.stencil_forced, "the caller's stencil_unit wins (a beam marks its caster)")
	eq(handle.anchor.live_stencil_value(), 2, "and is never re-read from the anchor's view")
	handle.stop(0.0)


func test_the_registry_shaders_to_prepare() -> void:
	var quad := _glow_layer(true)
	var floor_quad := _glow_layer(false)
	var def := FxDefinition.new()
	def.layers = [quad, floor_quad, _particles_layer()]
	var shaders := FxStencilShaders.over_unit_shaders([def, null, def])
	eq(shaders, [load(GLOW), FxParticles3DLayer.PARTICLE_SHADER] as Array[Shader],
		"the glow and the particles, once each; the floor quad never draws over its unit")
	eq(await FxStencilShaders.prepare(null, shaders, [1, 2]), 0, "headless (or with no camera) prepare does nothing")


func test_the_validator_reads_stencil_words_and_values() -> void:
	var dir := "user://stencil_validator_test"
	DirAccess.make_dir_recursive_absolute(dir)
	_write(dir + "/typo.gdshader", "shader_type spatial;
stencil_mode read, compare_equal, write_foo, 30;
")
	_write(dir + "/fine.gdshader", "shader_type spatial;
stencil_mode read, FX_STENCIL_COMPARE, FX_STENCIL_REF;
stencil_mode write, compare_always, 200; // outline
")
	_write(dir + "/takes_p1.gdshader", "shader_type spatial;
stencil_mode write, compare_always, 1;
")
	_write(dir + "/outline.tres", "[gd_resource type=\"StandardMaterial3D\" format=3]

[resource]
stencil_mode = 1
")
	_write(dir + "/high.tres", "[gd_resource type=\"StandardMaterial3D\" format=3]

[resource]
stencil_mode = 3
stencil_reference = 64
")
	var found := {}
	for issue in FxValidator.stencil_problems([dir]):
		found[issue.path.get_file() + ":" + issue.code] = true
	eq(found.keys().filter(func(k: String) -> bool: return k.begins_with("typo")), ["typo.gdshader:fx_stencil_mode_unknown"],
		"a misspelt word is reported (30 is only read, not written)")
	check(found.has("takes_p1.gdshader:fx_stencil_value_taken"), "a shader writing 1 takes P1's value")
	check(found.has("outline.tres:fx_stencil_value_taken"), "an Outline preset with the default reference 1 takes P1's value")
	check(not found.has("fine.gdshader:fx_stencil_mode_unknown") and not found.has("fine.gdshader:fx_stencil_value_taken"),
		"defines and a value outside the unit range are fine")
	check(not found.has("high.tres:fx_stencil_value_taken"), "a material on 64 (the target range) is fine")
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func test_the_fx_stencil_command() -> void:
	var view := _view(&"P2")
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	var off: Dictionary = await console.execute("fx stencil off")
	check(off["ok"] and off["text"].begins_with("fx stencil: off") and view.stencil_value == 0, "off: the views take no value")
	var on: Dictionary = await console.execute("fx stencil on")
	check(on["ok"] and on["text"].begins_with("fx stencil: on") and view.stencil_value == 2, "on: the views take their position's value")
	var dump: Dictionary = await console.execute("fx stencil dump")
	check(dump["ok"] and dump["text"].contains("P2") and dump["text"].contains("last prepare"), "dump lists the views: %s" % dump["text"])
	var bad: Dictionary = await console.execute("fx stencil maybe")
	check(not bad["ok"], "anything else is refused")
	eq(FxStencilShaders.DEFAULT_MODE, FxStencilShaders.STENCIL, "stencil is on by default")


# --- Step 2 review fixes -------------------------------------------------------------------------------------------------

func test_review_fixes_of_step_2() -> void:
	FxStencilShaders.mode = FxStencilShaders.STENCIL
	# Soft particles keep full strength over their own unit.
	var particle_code := FxParticles3DLayer.PARTICLE_SHADER.code
	var guard := particle_code.find("#ifndef FX_STENCIL_OWN")
	check(guard >= 0 and guard < particle_code.find("if (soft_distance > 0.0)"), "the soft fade is skipped in the OWN pass")
	# A flat quad lies on the floor: no fade against it.
	var flat := _glow_layer(false)
	var quad := _keep(flat.build()) as FxQuad3D
	flat.apply(quad, {}, _anchor(4), 3, null)
	eq((quad.material as ShaderMaterial).get_shader_parameter(&"depth_fade"), 0.0, "a floor quad does not fade against the floor")
	# A caller's forced value survives placing (a sub-effect re-places the parent's anchor).
	var view := _view(&"E1")
	view.stencil_value = 5
	view.mark_stencil(StandardMaterial3D.new())
	var forced := FxAnchor.node3d(view)
	forced.stencil_value = 2
	forced.stencil_forced = true
	var placed := forced.placed(&"Center")
	check(placed.stencil_value == 2 and placed.stencil_forced, "the forced value is kept, not E1's 5")
	# Particles on a ring around the feet stay around the unit.
	var ring := _particles_layer()
	ring.emission_ring_radius = 1.0
	eq(ring.stencil_value(_anchor(4), FxParticles3DLayer.PARTICLE_SHADER, FxLayer.OverOwnUnit.AUTO), 0, "AUTO: ring particles keep the plain depth test")
	# supports() is cached and follows an edited shader.
	var shader := Shader.new()
	shader.code = "shader_type spatial;
"
	check(not FxStencilShaders.supports(shader), "no include")
	shader.code = "shader_type spatial;
#include \"res://game/fx/shaders/fx_stencil_depth.gdshaderinc\"
"
	check(FxStencilShaders.supports(shader), "edited to include it: checked again")
