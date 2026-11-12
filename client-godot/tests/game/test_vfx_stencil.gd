## Spec vfx-stencil, step 1: the stencil value table, stamping a unit view, the anchor carrying its unit's value, the shader copies
## and the 3D shader quad drawing in two passes, and bias mode changing nothing. Built in memory, no presentation/ files. What the
## pixels look like needs a GPU: the windowed probe (game/tools/fx_stencil_probe.tscn, game/dev/fx_stencil_stage.tscn --compare).
extends TestCase

const GLOW := "res://game/fx/shaders/glow_3d.gdshader"
const INCLUDE := "res://game/fx/shaders/fx_depth_bias.gdshaderinc"

var _nodes: Array[Node] = []
var _services: Array[FxService] = []


func after_each() -> void:
	FxStencilShaders.mode = FxStencilShaders.BIAS  # the default: every other test runs in bias mode
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
	eq(view.effect_stencil_value(), 0, "so its effects keep the depth bias instead of losing it")
	var other := _view(&"P4")
	other.stencil_value = 4
	var shader_material := ShaderMaterial.new()
	check(other.mark_stencil(shader_material) == shader_material, "a shader material comes back untouched (step 2 adds the unit include)")
	eq(other.effect_stencil_value(), 0, "and that view's effects keep the bias too")
	var bare := _view(&"E5")
	bare.stencil_value = 9
	eq(bare.effect_stencil_value(), 0, "a view whose paint never stamps (the base _paint) gives no value: its effects keep the bias")


func test_the_latest_paint_decides_whether_a_view_is_stamped() -> void:
	var view := _view(&"P1")
	view.stencil_value = 1
	view.mark_stencil(StandardMaterial3D.new())
	eq(view.effect_stencil_value(), 1, "solid: stamped")
	var fading := StandardMaterial3D.new()
	fading.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	view.mark_stencil(fading)
	eq(view.effect_stencil_value(), 0, "fading out: not stamped, effects keep the bias")
	view.mark_stencil(StandardMaterial3D.new())
	eq(view.effect_stencil_value(), 1, "solid again (revived): stamped again")


func test_assign_stencil_follows_the_mode() -> void:
	var view := _view(&"E2")
	FxStencilShaders.mode = FxStencilShaders.BIAS
	view.assign_stencil()
	eq(view.stencil_value, 0, "bias mode: no value")
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
	FxStencilShaders.mode = FxStencilShaders.BIAS
	layer.apply(quad, {}, _anchor(4), 3, null)
	check(material.shader == layer.shader and material.next_pass == null, "bias mode: the layer's own shader, one pass")
	eq(material.get_shader_parameter(&"color"), Color(0.1, 0.2, 0.3), "parameters survive the way back")


func test_which_quads_draw_over_their_unit() -> void:
	FxStencilShaders.mode = FxStencilShaders.STENCIL
	eq(_glow_layer(true).stencil_for(_anchor(4)), 4, "a camera-facing quad draws over its unit")
	eq(_glow_layer(false).stencil_for(_anchor(4)), 0, "a flat floor quad keeps the plain depth test")
	var forced := _glow_layer(false)
	forced.over_own_unit = FxShaderQuadLayer.OverOwnUnit.ON
	eq(forced.stencil_for(_anchor(4)), 4, "unless the layer says ON")
	var never := _glow_layer(true)
	never.over_own_unit = FxShaderQuadLayer.OverOwnUnit.OFF
	eq(never.stencil_for(_anchor(4)), 0, "and OFF turns it off")
	eq(_glow_layer(true).stencil_for(_anchor(0)), 0, "no unit value: none")
	eq(_glow_layer(true).stencil_for(_anchor(StencilIds.DEV)), 0, "a value outside the unit range: none")
	FxStencilShaders.mode = FxStencilShaders.BIAS
	eq(_glow_layer(true).stencil_for(_anchor(4)), 0, "bias mode: never")


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
	named_only.code = "shader_type spatial;\n// works like fx_depth_bias.gdshaderinc, but does not include it\nvoid fragment() { ALBEDO = vec3(1.0); }\n"
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
	check(material.stencil_unit == 0 and material.next_pass == null, "E2 fades out: the live effect goes back to one pass with the bias")
	view.mark_stencil(StandardMaterial3D.new())
	layer.update(quad, 0.2, 1.0, {})
	eq(material.stencil_unit, 6, "E2 solid again: over it again")
	FxStencilShaders.mode = FxStencilShaders.BIAS
	layer.update(quad, 0.3, 1.0, {})
	check(material.stencil_unit == 0 and material.shader == layer.shader, "the mode back to bias reaches a live effect")


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
