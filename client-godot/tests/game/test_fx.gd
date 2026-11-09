## Spec vfx-framework: the effects system. Everything is built in memory (no presentation/ files) and driven on a
## scripted clock (FxService.manual_clock + advance), so no test waits for real time.
extends TestCase

var _services: Array[FxService] = []
var _nodes: Array[Node] = []


func after_each() -> void:
	FxCueNotify.service_override = null
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


# --- Builders ------------------------------------------------------------------------------------------------------

func _service() -> FxService:
	var service := FxService.new()
	service.enabled = true
	service.manual_clock = true
	host.add_child(service)
	_services.append(service)
	return service


func _keep(node: Node) -> Node:
	host.add_child(node)
	_nodes.append(node)
	return node


func _param(param_name: StringName, kind: FxParam.Kind, default: Variant, low: float = 0.0, high: float = 0.0) -> FxParam:
	var param := FxParam.new()
	param.name = param_name
	param.kind = kind
	param.default_value = default
	param.min_value = low
	param.max_value = high
	return param


func _bind(property: String, param: StringName, scale: float = 1.0) -> FxBinding:
	var binding := FxBinding.new()
	binding.property = property
	binding.param = param
	binding.scale = scale
	return binding


func _particles(layer_id: StringName, lifetime: float = 1.0, amount: int = 10) -> FxParticles3DLayer:
	var layer := FxParticles3DLayer.new()
	layer.id = layer_id
	layer.lifetime = lifetime
	layer.amount = amount
	return layer


func _constant_curve(value: float) -> Curve:
	var curve := Curve.new()
	curve.min_value = 0.0
	curve.max_value = maxf(value, 1.0)
	curve.add_point(Vector2(0, value))
	curve.add_point(Vector2(1, value))
	return curve


func _def(effect_id: StringName, layers: Array, params: Array = [], space: FxDefinition.Space = FxDefinition.Space.WORLD_3D) -> FxDefinition:
	var def := FxDefinition.new()
	def.id = effect_id
	def.space = space
	def.layers.assign(layers)
	def.params.assign(params)
	return def


func _quad_shader() -> Shader:
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\nuniform float progress = 0.0;\nuniform float time = 0.0;\nuniform vec4 tint : source_color = vec4(1.0);\nvoid fragment() { COLOR = tint; }\n"
	return shader


# --- Parameters, bindings, tracks -----------------------------------------------------------------------------------

func test_param_types_clamp_and_parse() -> void:
	var number := _param(&"n", FxParam.Kind.FLOAT, 1.0, 0.0, 2.0)
	eq(number.clamp_value(5), 2.0, "float clamps to the range")
	check(number.accepts(3) and not number.accepts("x") and not number.accepts(Color.RED), "float accepts numbers only")
	var count := _param(&"c", FxParam.Kind.INT, 3, 1, 10)
	eq(count.clamp_value(2.6), 3, "an int rounds")
	var color := _param(&"k", FxParam.Kind.COLOR, Color.RED)
	check(color.accepts("#00ff00") and color.clamp_value("#00ff00") == Color(0, 1, 0), "a colour reads hex text")
	check(not color.accepts("not a colour"), "bad colour text is refused")
	check(color.parse_text("#0000ff")["ok"] and not color.parse_text("zzz")["ok"], "console text parses colours")
	var vector := _param(&"v", FxParam.Kind.VECTOR2, Vector2.ONE)
	eq(vector.parse_text("1.5, 2")["value"], Vector2(1.5, 2), "vectors parse from text")
	check(_param(&"t", FxParam.Kind.TEXTURE, null).accepts(null), "a texture may be empty")
	eq(_param(&"b", FxParam.Kind.BOOL, true).parse_text("off")["value"], false, "bools parse")


func test_binding_scale_offset_curve_and_color() -> void:
	var binding := _bind("x", &"p", 2.0)
	binding.offset = 1.0
	eq(binding.value_for(3.0), 7.0, "value * scale + offset")
	var curve := Curve.new()
	curve.max_value = 10.0
	curve.add_point(Vector2(0, 0))
	curve.add_point(Vector2(1, 10))
	var mapped := _bind("x", &"p")
	mapped.curve = curve
	var spec := _param(&"p", FxParam.Kind.FLOAT, 0.0, 0.0, 4.0)
	check(absf(float(mapped.value_for(2.0, spec)) - 5.0) < 0.2, "the curve remaps the normalised parameter")
	var tint := _bind("x", &"c", 2.0)
	var out: Color = tint.value_for(Color(0.5, 0.25, 0.1, 0.8))
	check(is_equal_approx(out.r, 1.0) and is_equal_approx(out.a, 0.8), "a colour scales its rgb, not its alpha")


func test_curve_track_modes_and_axes() -> void:
	var track := FxCurveTrack.new()
	track.curve = _constant_curve(2.0)
	track.mode = FxCurveTrack.Mode.MULTIPLY
	eq(track.evaluate(3.0, 0.5, {}), 6.0, "multiply")
	eq(track.evaluate(Vector3(1, 2, 3), 0.5, {}), Vector3(2, 4, 6), "multiply a vector")
	track.mode = FxCurveTrack.Mode.ADD
	eq(track.evaluate(3.0, 0.5, {}), 5.0, "add")
	track.mode = FxCurveTrack.Mode.SET
	track.axes = Vector3(1, 0, 1)
	eq(track.evaluate(Vector3(1, 7, 1), 0.5, {}), Vector3(2, 7, 2), "a zero axis is left alone")
	track.scale_param = &"boost"
	eq(track.evaluate(0.0, 0.5, {&"boost": 3.0}), 6.0, "a scale parameter multiplies the value")
	var fade := FxCurveTrack.new()
	fade.curve = _constant_curve(0.5)
	fade.mode = FxCurveTrack.Mode.MULTIPLY
	var faded: Color = fade.evaluate(Color(1, 1, 1, 1), 0.0, {})
	check(is_equal_approx(faded.a, 0.5) and is_equal_approx(faded.r, 1.0), "a colour track fades alpha by default")


func test_definition_problems_are_coded() -> void:
	var layer := _particles(&"a")
	layer.bindings.append(_bind("amount", &"missing"))
	layer.bindings.append(_bind("no_such_property", &"p"))
	var def := _def(&"fx.bad", [layer, layer], [_param(&"p", FxParam.Kind.FLOAT, 0.0), _param(&"p", FxParam.Kind.FLOAT, 0.0)])
	var text := "\n".join(def.problems())
	for code in ["fx_param_missing", "fx_binding_invalid", "fx_param_duplicate", "fx_layer_duplicate"]:
		check(text.contains(code), "the problems name %s: %s" % [code, text])
	var ui := _def(&"fx.ui", [_particles(&"p3d")], [], FxDefinition.Space.UI)
	check("\n".join(ui.problems()).contains("fx_space_mismatch"), "a 3D layer in a UI effect is refused")
	var good := _def(&"fx.good", [_particles(&"a")])
	eq(good.problems().size(), 0, "a clean effect has no problems")


# --- Playing ---------------------------------------------------------------------------------------------------------

func test_play_applies_params_and_clamps() -> void:
	var service := _service()
	var layer := _particles(&"a", 1.0, 10)
	layer.bindings.append(_bind("amount", &"count"))
	var def := _def(&"fx.params", [layer], [_param(&"count", FxParam.Kind.INT, 5, 1, 50)])
	service.register(def)
	var anchor_node := _keep(Node3D.new())
	var handle := service.play(&"fx.params", FxAnchor.node3d(anchor_node), {"count": 99})
	check(handle.is_playing(), "plays")
	eq(handle.params[&"count"], 50, "the value is clamped to the range")
	eq(handle.instance.nodes[0].amount, 50, "the binding wrote the node")
	var second := service.play(&"fx.params", FxAnchor.node3d(anchor_node))
	eq(second.instance.nodes[0].amount, 5, "defaults apply")


func test_unknown_id_and_bad_params_are_inert_or_ignored() -> void:
	var service := _service()
	var inert := service.play(&"fx.nope", FxAnchor.screen())
	check(not inert.is_playing() and inert.inert, "an unknown id returns an inert handle")
	inert.set_param(&"x", 1)
	inert.stop()
	eq(service.stats()["unknown"], 1, "counted")
	var def := _def(&"fx.p", [_particles(&"a")], [_param(&"size", FxParam.Kind.FLOAT, 1.0, 0.0, 3.0)])
	service.register(def)
	var handle := service.play(&"fx.p", FxAnchor.screen(), {"size": "wide", "ghost": 1})
	eq(handle.params[&"size"], 1.0, "a value of the wrong type keeps the default")
	check(not handle.params.has(&"ghost"), "an unknown parameter is dropped")
	handle.stop(0.0)


func test_lifecycle_runs_on_the_clock() -> void:
	var service := _service()
	var tween := FxTweenLayer.new()
	tween.id = &"b"
	tween.start_delay = 0.5
	tween.seconds = 0.2
	var track := FxCurveTrack.new()
	track.property = "scale"
	track.curve = _constant_curve(2.0)
	track.mode = FxCurveTrack.Mode.MULTIPLY
	tween.tracks.append(track)
	var def := _def(&"fx.life", [_particles(&"a", 1.0), tween])
	service.register(def)
	var target := _keep(Node3D.new()) as Node3D
	var handle := service.play(&"fx.life", FxAnchor.node3d(target))
	var finished := [0]
	handle.finished.connect(func() -> void: finished[0] += 1)
	eq(handle.states[0], FxHandle.LayerState.RUNNING, "the first layer starts at once")
	eq(handle.states[1], FxHandle.LayerState.PENDING, "the delayed layer waits")
	service.advance(0.6)
	eq(handle.states[1], FxHandle.LayerState.RUNNING, "the delayed layer started")
	eq(target.scale, Vector3(2, 2, 2), "its track wrote the anchor")
	service.advance(0.2)
	eq(handle.states[1], FxHandle.LayerState.DONE, "and ended")
	eq(target.scale, Vector3.ONE, "the anchor's scale is put back")
	check(handle.is_playing(), "the particles are still going")
	service.advance(0.3)
	check(not handle.is_playing(), "everything ended")
	eq(finished[0], 1, "finished fired once")
	eq(service.live_count(), 0, "nothing is live")
	eq(service.pool_size(&"fx.life"), 1, "the instance went back to the pool")


func test_pool_reuse_and_max_instances() -> void:
	var service := _service()
	var def := _def(&"fx.pool", [_particles(&"a", 0.5)])
	def.max_instances = 2
	service.register(def)
	var anchor := FxAnchor.screen()
	service.play(def, anchor)
	service.advance(1.0)
	service.play(def, anchor)
	eq(service.stats()["built"], 1, "built once")
	eq(service.stats()["pool_hits"], 1, "reused from the pool")
	service.play(def, anchor)
	service.play(def, anchor)
	eq(service.live_count(&"fx.pool"), 2, "the cap holds")
	eq(service.stats()["recycled"], 1, "the oldest was recycled")


func test_anchor_freed_releases_the_effect() -> void:
	var service := _service()
	var def := _def(&"fx.free", [_particles(&"a", 5.0)])
	service.register(def)
	var target := Node3D.new()
	host.add_child(target)
	var handle := service.play(def, FxAnchor.node3d(target))
	check(handle.is_playing(), "plays")
	target.free()
	service.advance(0.1)
	check(not handle.is_playing(), "released when the anchor left")
	eq(service.live_count(), 0, "nothing leaks")
	var again := service.play(def, FxAnchor.node3d(_keep(Node3D.new())))
	check(again.is_playing(), "the pool survives a freed anchor")


func test_loop_runs_until_stopped_with_a_fade() -> void:
	var service := _service()
	var layer := _particles(&"aura", 0.5)
	layer.loop = true
	var def := _def(&"fx.aura", [layer])
	service.register(def)
	var handle := service.play(def, FxAnchor.node3d(_keep(Node3D.new())))
	service.advance(30.0)
	check(handle.is_playing(), "a looping effect plays on")
	handle.stop(0.2)
	check(handle.is_playing(), "it fades first")
	service.advance(0.3)
	check(handle.is_playing(), "the particles in the air get their lifetime")
	service.advance(0.4)
	check(not handle.is_playing(), "then it is gone")


func test_quality_tiers_filter_layers_and_scale_particles() -> void:
	var service := _service()
	var low := _particles(&"low", 1.0, 10)
	var high := _particles(&"high", 1.0, 10)
	high.min_quality = FxLayer.Quality.HIGH
	var medium := _particles(&"medium", 1.0, 10)
	medium.min_quality = FxLayer.Quality.MEDIUM
	var def := _def(&"fx.tiers", [low, medium, high])
	service.register(def)
	var anchor := FxAnchor.node3d(_keep(Node3D.new()))
	service.quality = FxQuality.LOW
	var handle := service.play(def, anchor)
	eq(handle.states[0], FxHandle.LayerState.RUNNING, "low plays the low layer")
	eq(handle.states[1], FxHandle.LayerState.SKIPPED, "low skips the medium layer")
	eq(handle.states[2], FxHandle.LayerState.SKIPPED, "low skips the high layer")
	eq(handle.instance.nodes[0].amount, 4, "low keeps 40% of the particles")
	handle.stop(0.0)
	service.quality = FxQuality.MEDIUM
	handle = service.play(def, anchor)
	eq(handle.states[1], FxHandle.LayerState.RUNNING, "medium plays the medium layer")
	eq(handle.states[2], FxHandle.LayerState.SKIPPED, "medium skips the high layer")
	eq(handle.instance.nodes[0].amount, 7, "medium keeps 70%")
	handle.stop(0.0)
	service.quality = FxQuality.HIGH
	handle = service.play(def, anchor)
	eq(handle.states[2], FxHandle.LayerState.RUNNING, "high plays everything")
	eq(handle.instance.nodes[0].amount, 10, "at full amount")
	handle.stop(0.0)
	service.quality = FxQuality.OFF
	check(not service.play(def, anchor).is_playing(), "off plays nothing")


func test_disabled_service_is_a_no_op() -> void:
	var service := _service()
	service.enabled = false
	var def := _def(&"fx.off", [_particles(&"a")])
	service.register(def)
	var handle := service.play(def, FxAnchor.screen())
	check(handle.inert and not handle.is_playing(), "headless / disabled: inert")
	eq(service.live_count(), 0, "nothing built or live")
	eq(service.stats()["skipped"], 1, "counted as skipped")


func test_set_param_updates_bound_layers_live() -> void:
	var service := _service()
	var layer := _particles(&"a", 5.0)
	layer.bindings.append(_bind("lifetime", &"life"))
	var def := _def(&"fx.live", [layer], [_param(&"life", FxParam.Kind.FLOAT, 1.0, 0.1, 9.0)])
	service.register(def)
	var handle := service.play(def, FxAnchor.node3d(_keep(Node3D.new())))
	eq(handle.instance.nodes[0].lifetime, 1.0, "starts at the default")
	handle.set_param(&"life", 4.0)
	eq(handle.instance.nodes[0].lifetime, 4.0, "set_param reaches the node")
	handle.set_param(&"life", "99")
	eq(handle.instance.nodes[0].lifetime, 9.0, "text is parsed and clamped")
	handle.stop(0.0)


func test_stop_all() -> void:
	var service := _service()
	var layer := _particles(&"a")
	layer.loop = true
	var def := _def(&"fx.all", [layer])
	service.register(def)
	service.play(def, FxAnchor.screen())
	service.play(def, FxAnchor.screen())
	service.stop_all()
	eq(service.live_count(), 0, "stop_all ends everything")


func test_registry_includes_and_catalog() -> void:
	var service := _service()
	var base := FxRegistry.new()
	base.definitions.append(_def(&"fx.a", [_particles(&"a")]))
	var override := _def(&"fx.a", [_particles(&"a"), _particles(&"b")])
	var pack := FxRegistry.new()
	pack.includes.append(base)
	pack.definitions.append(override)
	pack.definitions.append(_def(&"fx.b", [_particles(&"a")]))
	service.registry = pack
	service.reload()
	eq(service.catalog(), [&"fx.a", &"fx.b"], "sorted ids")
	eq(service.definition(&"fx.a").layers.size(), 2, "the including registry overrides")


# --- Layer kinds ---------------------------------------------------------------------------------------------------

func test_mesh_flash_overlays_and_restores() -> void:
	var service := _service()
	var flash := FxMeshFlashLayer.new()
	flash.id = &"flash"
	flash.seconds = 0.4
	var def := _def(&"fx.flash", [flash])
	service.register(def)
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	var before := StandardMaterial3D.new()
	mesh.material_overlay = before
	_keep(mesh)
	var handle := service.play(def, FxAnchor.node3d(mesh))
	check(mesh.material_overlay != before and mesh.material_overlay != null, "the flash overlay is on the mesh")
	service.advance(0.1)
	check((mesh.material_overlay as StandardMaterial3D).albedo_color.a > 0.0, "and it fades from visible")
	service.advance(0.5)
	check(not handle.is_playing() and mesh.material_overlay == before, "the old overlay is back")


func test_shader_quad_fills_a_control_and_drives_progress() -> void:
	var service := _service()
	var quad := FxShaderQuadLayer.new()
	quad.id = &"glow"
	quad.shader = _quad_shader()
	quad.duration = 1.0
	quad.grow = 10.0
	quad.bindings.append(_bind("material:shader_parameter/tint", &"color"))
	var def := _def(&"fx.quad", [quad], [_param(&"color", FxParam.Kind.COLOR, Color.WHITE)], FxDefinition.Space.UI)
	service.register(def)
	check(def.problems().is_empty(), "the quad effect is clean: %s" % "\n".join(def.problems()))
	var control := Control.new()
	control.position = Vector2(100, 50)
	control.size = Vector2(200, 300)
	_keep(control)
	var handle := service.play(def, FxAnchor.control(control), {"color": Color.RED})
	var holder: Control = handle.instance.holder_ui
	check(holder.get_parent() == control and holder.top_level, "the holder is a top-level child of the control")
	eq(holder.size, Vector2(200, 300), "and has its size")
	var rect := handle.instance.nodes[0] as ColorRect
	eq(rect.size, Vector2(220, 320), "the quad is `grow` bigger on every side")
	eq(rect.position, Vector2(-10, -10), "and centred on it")
	eq((rect.material as ShaderMaterial).get_shader_parameter("tint"), Color.RED, "the binding set the uniform")
	service.advance(0.25)
	check(absf(float((rect.material as ShaderMaterial).get_shader_parameter("progress")) - 0.25) < 0.01, "progress is driven")
	control.position = Vector2(300, 80)
	service.advance(0.0)
	eq(holder.global_position, Vector2(300, 80), "the holder follows the control")
	service.advance(1.0)
	check(not handle.is_playing(), "ends")


func test_screen_anchor_uses_the_window_layer() -> void:
	var service := _service()
	var quad := FxShaderQuadLayer.new()
	quad.id = &"flash"
	quad.shader = _quad_shader()
	quad.duration = 0.2
	var def := _def(&"fx.screen", [quad], [], FxDefinition.Space.SCREEN)
	service.register(def)
	var handle := service.play(def, FxAnchor.screen())
	check(handle.instance.holder_ui.get_parent() == service.screen_root, "2D layers go in the screen layer")
	service.advance(0.5)
	check(not handle.is_playing(), "ends")


func test_3d_layer_on_a_control_is_skipped() -> void:
	var service := _service()
	var def := _def(&"fx.mixed", [_particles(&"p3d")], [], FxDefinition.Space.HYBRID)
	service.register(def)
	var handle := service.play(def, FxAnchor.control(_keep(Control.new())))
	eq(handle.states[0], FxHandle.LayerState.SKIPPED, "a control has no 3D world")


func test_shake_moves_a_control_and_restores_it() -> void:
	var service := _service()
	var shake := FxShakeLayer.new()
	shake.id = &"shake"
	shake.seconds = 0.4
	shake.strength_px = 20.0
	var def := _def(&"fx.shake", [shake], [], FxDefinition.Space.UI)
	service.register(def)
	var control := Control.new()
	control.position = Vector2(50, 50)
	_keep(control)
	var handle := service.play(def, FxAnchor.control(control))
	service.advance(0.05)
	check(control.position != Vector2(50, 50), "the control is nudged")
	service.advance(1.0)
	eq(control.position, Vector2(50, 50), "and put back")
	check(not handle.is_playing(), "ends")


func test_shake_moves_the_camera_for_a_screen_anchor() -> void:
	var service := _service()
	var shake := FxShakeLayer.new()
	shake.id = &"shake"
	shake.seconds = 0.4
	shake.strength_world = 1.0
	var def := _def(&"fx.camshake", [shake], [], FxDefinition.Space.SCREEN)
	service.register(def)
	var stage := FxStage.new()
	_keep(stage)
	service.play(def, FxAnchor.on_stage(stage))
	service.advance(0.05)
	check(stage.camera.h_offset != 0.0 or stage.camera.v_offset != 0.0, "the stage camera shakes")
	service.advance(1.0)
	eq(stage.camera.h_offset, 0.0, "and settles")


func test_sound_layer_lasts_as_long_as_its_stream() -> void:
	var service := _service()
	var sound := FxSoundLayer.new()
	sound.id = &"hit"
	var wave := AudioStreamWAV.new()
	wave.format = AudioStreamWAV.FORMAT_8_BITS
	wave.mix_rate = 8000
	var samples := PackedByteArray()
	samples.resize(8000)
	wave.data = samples
	sound.stream = wave
	var def := _def(&"fx.sound", [sound], [], FxDefinition.Space.UI)
	service.register(def)
	var handle := service.play(def, FxAnchor.screen())
	check(handle.ends[0] > 0.9 and handle.ends[0] < 1.1, "one second of audio: %s" % handle.ends[0])
	handle.stop(0.0)


# --- Stages, sub-effects, bridges ------------------------------------------------------------------------------------

func test_stage_hosts_3d_in_its_world_and_2d_in_its_overlay() -> void:
	var service := _service()
	var quad := FxShaderQuadLayer.new()
	quad.id = &"glow"
	quad.shader = _quad_shader()
	quad.duration = 1.0
	quad.size = Vector2(64, 64)
	var def := _def(&"fx.stage", [_particles(&"burst", 1.0), quad], [], FxDefinition.Space.HYBRID)
	service.register(def)
	check(def.problems().is_empty(), "the hybrid effect is clean: %s" % "\n".join(def.problems()))
	var stage := FxStage.new()
	stage.size = Vector2(800, 600)
	_keep(stage)
	var card := MeshInstance3D.new()
	card.mesh = BoxMesh.new()
	stage.world_root.add_child(card)
	var handle := service.play(def, FxAnchor.on_stage(stage, card))
	check(handle.instance.holder_3d.get_parent() == card, "3D layers sit on the card mesh in the stage world")
	check(handle.instance.holder_ui.get_parent() == stage.overlay, "2D layers sit in the stage overlay")
	eq(handle.ui_follow, FxService.Follow.PROJECT_STAGE, "and follow the card's projected position")
	check(stage.project(Vector3.ZERO).distance_to(stage.size * 0.5) < 2.0, "the origin projects to the middle of the stage")
	stage.free()
	service.advance(0.1)
	check(not handle.is_playing(), "a freed stage releases its effects")


func test_a_stage_keeps_its_own_world() -> void:
	var stage := FxStage.new()
	_keep(stage)
	check(stage.viewport.own_world_3d and stage.viewport.transparent_bg, "own world, transparent")
	check(stage.world_root.get_world_3d() != host.get_viewport().world_3d, "the stage world is not the game's")


func test_sub_effect_follows_its_parent() -> void:
	var service := _service()
	var light := FxLightLayer.new()
	light.id = &"light"
	light.seconds = 0.3
	light.bindings.append(_bind("light_color", &"color"))
	var child := _def(&"fx.child", [light], [_param(&"color", FxParam.Kind.COLOR, Color.WHITE)])
	var sub := FxSubFxLayer.new()
	sub.id = &"child"
	sub.effect = child
	sub.param_map = {"color": "$tint"}
	var parent := _def(&"fx.parent", [sub], [_param(&"tint", FxParam.Kind.COLOR, Color.WHITE)])
	service.register(parent)
	check(parent.problems().is_empty(), "no problems: %s" % "\n".join(parent.problems()))
	var handle := service.play(parent, FxAnchor.node3d(_keep(Node3D.new())), {"tint": Color.BLUE})
	eq(service.live_count(&"fx.child"), 1, "the sub-effect plays")
	eq(service.live()[1].params[&"color"], Color.BLUE, "with the mapped parameter")
	service.advance(0.5)
	service.advance(0.0)  # the parent sees its sub-effect gone on the next tick
	check(not handle.is_playing() and service.live_count() == 0, "the parent ends with its sub-effect")


func test_sub_effect_cycle_is_a_problem_and_never_runs_away() -> void:
	var service := _service()
	var sub := FxSubFxLayer.new()
	sub.id = &"again"
	var def := _def(&"fx.loop", [sub])
	sub.effect = def
	check("\n".join(def.problems()).contains("fx_cycle"), "the validator names the cycle")
	service.register(def)
	service.play(def, FxAnchor.node3d(_keep(Node3D.new())))
	service.advance(0.1)
	check(service.live_count() <= FxService.MAX_DEPTH + 2, "the depth cap stops it: %d live" % service.live_count())
	service.stop_all()


func test_unit_anchor_uses_the_resolver() -> void:
	var service := _service()
	var unit_view := _keep(Node3D.new()) as Node3D
	service.unit_resolver = func(unit_id: StringName) -> Node3D: return unit_view if unit_id == &"P1" else null
	var def := _def(&"fx.unit", [_particles(&"a", 5.0)])
	service.register(def)
	var handle := service.play(def, FxAnchor.unit(&"P1"))
	check(handle.is_playing() and handle.instance.holder_3d.get_parent() == unit_view, "on the unit's view")
	handle.stop(0.0)
	check(not service.play(def, FxAnchor.unit(&"E9")).is_playing(), "an unknown unit plays nothing")


func test_cue_notify_plays_and_finishes() -> void:
	var service := _service()
	FxCueNotify.service_override = service
	var def := _def(&"fx.cue", [_particles(&"a", 0.5)], [_param(&"color", FxParam.Kind.COLOR, Color.WHITE)])
	var binding := FxCueBinding.new()
	binding.param = &"color"
	binding.value = Color.GREEN
	var cue := FxCueNotify.new()
	cue.fx = def
	cue.bindings.append(binding)
	_keep(cue)
	var done := [0]
	cue.cue_finished.connect(func(_node, _tag) -> void: done[0] += 1)
	var target := _keep(Node3D.new()) as Node3D
	cue.execute_cue(target)
	eq(service.live_count(&"fx.cue"), 1, "the cue played the effect")
	eq(service.live()[0].params[&"color"], Color.GREEN, "with the cue binding")
	service.advance(2.0)
	eq(done[0], 1, "the cue finished when the effect did")


func test_persistent_cue_loops_until_ended() -> void:
	var service := _service()
	FxCueNotify.service_override = service
	var layer := _particles(&"aura", 0.4)
	layer.loop = true
	var def := _def(&"fx.aura_cue", [layer])
	var cue := FxCueNotify.new()
	cue.fx = def
	cue.auto_destroy = false
	cue.stop_fade = 0.1
	_keep(cue)
	var done := [0]
	cue.cue_finished.connect(func(_node, _tag) -> void: done[0] += 1)
	cue.execute_cue(_keep(Node3D.new()))
	service.advance(10.0)
	eq(done[0], 0, "a persistent cue stays")
	cue.end_cue()
	service.advance(1.0)
	eq(done[0], 1, "and finishes after the fade")


func test_cue_through_the_real_cue_manager() -> void:
	var service := _service()
	FxCueNotify.service_override = service
	var def := _def(&"fx.managed", [_particles(&"a", 0.5)])
	var cue := FxCueNotify.new()
	cue.fx = def
	var scene := PackedScene.new()
	check(scene.pack(cue) == OK, "the cue scene packs")
	cue.free()
	var tag := &"Cue.Test.FxBridge"
	var was_suppressed: bool = GameplayCueManager.suppress_cues
	GameplayCueManager.suppress_cues = false  # headless suppresses cues; this test wants the real path
	GameplayCueManager.register_cue(tag, scene)
	var target := _keep(Node3D.new())
	GameplayCueManager.execute_cue(tag, target, {})
	eq(service.live_count(&"fx.managed"), 1, "GodotGAS's manager spawned the FX cue")
	service.advance(2.0)
	eq(service.live_count(), 0, "it ended")
	eq((GameplayCueManager._pool[tag] as Array).size(), 1, "and the cue went back to GodotGAS's pool")
	GameplayCueManager.unregister_cue(tag)
	GameplayCueManager.suppress_cues = was_suppressed


func test_cue_binding_reads_the_payload_and_target_tags() -> void:
	var from_payload := FxCueBinding.new()
	from_payload.source = FxCueBinding.Source.PAYLOAD
	from_payload.payload_key = &"power"
	from_payload.value = 1.0
	eq(from_payload.resolve(null, {"power": 4.0}), 4.0, "payload value")
	eq(from_payload.resolve(null, {}), 1.0, "fallback")
	var from_tags := FxCueBinding.new()
	from_tags.source = FxCueBinding.Source.TARGET_TAGS
	from_tags.tag_values = {"Status.Debuff.Burn": Color.ORANGE}
	var target := Node.new()
	_keep(target)
	eq(from_tags.resolve(target, {}), null, "no ASC, no match")


func test_listener_plays_on_a_message_and_leaves_with_its_owner() -> void:
	var service := _service()
	FxCueNotify.service_override = service
	var def := _def(&"fx.listen", [_particles(&"a", 0.5)], [_param(&"power", FxParam.Kind.FLOAT, 0.0, 0.0, 100.0)])
	var listener := FxListener.new()
	listener.channel = &"Message.Test.Fx"
	listener.effect = def
	listener.magnitude_param = &"power"
	var owner_node := Node.new()
	host.add_child(owner_node)
	listener.attach(owner_node)
	GameplayMessages.broadcast(&"Message.Test.Fx", VerbMessage.make(&"Verb.Win", &"P1", &"E1", 7))
	eq(service.live_count(&"fx.listen"), 1, "the message played the effect")
	eq(service.live()[0].params[&"power"], 7.0, "with the magnitude")
	owner_node.free()
	eq(GameplayMessages.listener_count(&"Message.Test.Fx"), 0, "the listener left with its owner")


func test_combat_never_references_the_effects_system() -> void:
	if skip_in_export():
		return
	for directory in ["res://combat/"]:
		for path in _scripts(directory):
			var text := FileAccess.get_file_as_string(path)
			for word in ["FxManager", "FxService", "FxDefinition", "FxAnchor", "FxCueNotify"]:
				check(not text.contains(word), "%s mentions %s: combat must not know about effects" % [path, word])


func _scripts(directory: String) -> Array[String]:
	var out: Array[String] = []
	for entry in DirAccess.get_directories_at(directory):
		out.append_array(_scripts(directory + entry + "/"))
	for file in DirAccess.get_files_at(directory):
		if file.ends_with(".gd"):
			out.append(directory + file)
	return out


# --- Shipped set, validator, tools ---------------------------------------------------------------------------------

func test_shader_library_documents_its_uniforms() -> void:
	if skip_in_export():
		return
	var directory := "res://game/fx/shaders/"
	var files := DirAccess.get_files_at(directory)
	check(files.size() >= 10, "the shader library is there (%d files)" % files.size())
	var uniform_line := RegEx.create_from_string(r"(?m)^uniform\s+\w+\s+(\w+)")
	var doc_line := RegEx.create_from_string(r"(?m)^//\s*@uniform\s+(\w+)")
	for file in files:
		if not file.ends_with(".gdshader"):
			continue
		var text := FileAccess.get_file_as_string(directory + file)
		var declared := {}
		for found in uniform_line.search_all(text):
			declared[found.get_string(1)] = true
		var documented := {}
		for found in doc_line.search_all(text):
			documented[found.get_string(1)] = true
		for name in declared:
			check(documented.has(name), "%s declares '%s' but its header does not document it (// @uniform %s)" % [file, name, name])
		for name in documented:
			check(declared.has(name), "%s documents '%s' but declares no such uniform" % [file, name])
		check(declared.has("progress") and declared.has("time"), "%s declares the driven uniforms progress and time" % file)
		var shader := load(directory + file) as Shader
		check(shader != null and shader.code.length() > 50, "%s loads as a shader" % file)


func test_validator_names_registry_problems() -> void:
	var registry := FxRegistry.new()
	var layer := _particles(&"a")
	layer.bindings.append(_bind("amount", &"nope"))
	registry.definitions.append(_def(&"fx.dup", [layer]))
	registry.definitions.append(_def(&"fx.dup", [_particles(&"b")]))
	var quad := FxShaderQuadLayer.new()
	quad.id = &"q"
	registry.definitions.append(_def(&"fx.noshader", [quad], [], FxDefinition.Space.UI))
	var codes := {}
	for issue in FxValidator.validate(registry):
		codes[issue.code] = true
		check(issue.is_error(), "%s is an error" % issue.code)
	for code in ["fx_duplicate_id", "fx_param_missing", "fx_shader_missing"]:
		check(codes.has(code), "the validator reports %s: %s" % [code, codes.keys()])
	var clean := FxRegistry.new()
	clean.definitions.append(_def(&"fx.fine", [_particles(&"a")]))
	eq(FxValidator.validate(clean).size(), 0, "a clean registry has no issues")


func test_shipped_effects_are_valid_and_play_at_every_tier() -> void:
	var registry := load(FxService.DEFAULT_REGISTRY) as FxRegistry
	check(registry != null and registry.definitions.size() >= 12, "the proof set is registered")
	if registry == null:
		return
	for issue in FxValidator.validate(registry):
		failures.append(str(issue))
	var service := _service()
	service.registry = registry
	service.reload()
	var results := FxSmoke.run(host, service, [], [FxQuality.OFF, FxQuality.LOW, FxQuality.MEDIUM, FxQuality.HIGH])
	for result in results:
		check((result["problems"] as Array).is_empty(), "%s: %s" % [result["id"], result["problems"]])
		for tier in result["tiers"]:
			var report: Dictionary = result["tiers"][tier]
			if tier == "off":
				check(not report["played"], "%s plays nothing at off" % result["id"])
			else:
				check(report["played"] or report.get("note", "") == "", "%s plays at %s: %s" % [result["id"], tier, report])
	eq(service.live_count(), 0, "nothing is left playing")


func test_proof_cues_are_registered_with_gas() -> void:
	for tag in [&"Cue.Sfx.Hit", &"Cue.Fx.HitSpark", &"Cue.Fx.Heal", &"Cue.Fx.Break", &"Cue.Fx.Aura"]:
		check(GameplayCueManager.has_cue(tag), "%s is in the cue registry" % tag)
	for tag in [&"Cue.Fx.HitSpark", &"Cue.Fx.Heal", &"Cue.Fx.Break", &"Cue.Fx.Aura"]:
		var scene: PackedScene = GameplayCueManager._scene_for(tag)
		var cue := scene.instantiate() if scene != null else null
		check(cue is FxCueNotify and cue.fx != null, "%s plays an effect" % tag)
		if cue != null:
			cue.free()


func test_fx_console_command() -> void:
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	check(console.commands.has("fx"), "the fx command exists")
	var list: Dictionary = await console.execute("fx list")
	check(list["ok"] and list["text"].contains("fx.hit_spark"), "fx list names the shipped effects: %s" % list["text"])
	var params: Dictionary = await console.execute("fx params fx.pack_burst")
	check(params["ok"] and params["text"].contains("count: int") and params["text"].contains("layer shake"), "fx params: %s" % params["text"])
	var checked: Dictionary = await console.execute("fx check")
	check(checked["ok"], "fx check passes: %s" % checked["text"])
	var played: Dictionary = await console.execute("fx play fx.hit_spark color=#00ff88")
	check(played["ok"] and played["text"].contains("played fx.hit_spark"), "fx play runs headless: %s" % played["text"])
	var bad: Dictionary = await console.execute("fx play fx.nope")
	check(not bad["ok"], "an unknown effect fails")
	var stats: Dictionary = await console.execute("fx stats")
	check(stats["ok"] and stats["text"].contains("fx.hit_spark"), "fx stats counts the play: %s" % stats["text"])
	check(not FxManager.enabled and not FxManager.manual_clock, "the headless switches are put back")
	var quality: Dictionary = await console.execute("fx quality")
	check(quality["ok"] and quality["text"].begins_with("fx quality:"), "fx quality reads the tier")
	var wrong: Dictionary = await console.execute("fx quality ultra")
	check(not wrong["ok"], "an unknown tier is refused")
	FxManager.stop_all()


# --- Review findings (round 1): overlapping effects, pools, fades ---------------------------------------------------------

func test_overlapping_shakes_restore_the_original_camera() -> void:
	var service := _service()
	var shake := FxShakeLayer.new()
	shake.id = &"shake"
	shake.seconds = 0.4
	shake.strength_world = 1.0
	var def := _def(&"fx.twoshakes", [shake], [], FxDefinition.Space.SCREEN)
	service.register(def)
	var stage := FxStage.new()
	_keep(stage)
	var anchor := FxAnchor.on_stage(stage)
	service.play(def, anchor)
	service.advance(0.05)
	service.play(def, anchor)  # starts while the first has already moved the camera
	service.advance(2.0)
	eq(stage.camera.h_offset, 0.0, "the camera is back at its own offset, not the first shake's")
	eq(stage.camera.v_offset, 0.0, "and its own v offset")


func test_overlapping_tweens_restore_the_original_scale() -> void:
	var service := _service()
	var tween := FxTweenLayer.new()
	tween.id = &"punch"
	tween.seconds = 0.3
	var track := FxCurveTrack.new()
	track.property = "scale"
	track.curve = _constant_curve(2.0)
	track.mode = FxCurveTrack.Mode.MULTIPLY
	tween.tracks.append(track)
	var def := _def(&"fx.twopunch", [tween])
	service.register(def)
	var target := _keep(Node3D.new()) as Node3D
	service.play(def, FxAnchor.node3d(target))
	service.advance(0.1)
	service.play(def, FxAnchor.node3d(target))
	service.advance(2.0)
	eq(target.scale, Vector3.ONE, "two punches on one node leave it at its own scale")


func test_overlapping_mesh_flashes_restore_the_original_overlay() -> void:
	var service := _service()
	var flash := FxMeshFlashLayer.new()
	flash.id = &"flash"
	flash.seconds = 0.3
	var def := _def(&"fx.twoflash", [flash])
	service.register(def)
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	var original := StandardMaterial3D.new()
	mesh.material_overlay = original
	_keep(mesh)
	service.play(def, FxAnchor.node3d(mesh))
	service.advance(0.1)
	service.play(def, FxAnchor.node3d(mesh))
	service.advance(0.25)  # the first has ended, the second is running
	check(mesh.material_overlay != original and mesh.material_overlay != null, "the running flash stays on the mesh")
	service.advance(1.0)
	check(mesh.material_overlay == original, "the original overlay comes back once both are over")


func test_stopping_a_shader_quad_fades_it_out() -> void:
	var service := _service()
	var quad := FxShaderQuadLayer.new()
	quad.id = &"glow"
	quad.shader = _quad_shader()
	quad.loop = true
	var def := _def(&"fx.fadeout", [quad], [], FxDefinition.Space.UI)
	service.register(def)
	var control := Control.new()
	control.size = Vector2(100, 100)
	_keep(control)
	var handle := service.play(def, FxAnchor.control(control))
	service.advance(1.0)
	var material := (handle.instance.nodes[0] as ColorRect).material as ShaderMaterial
	eq(material.get_shader_parameter("fade"), null, "no fade while playing (the shader default is 1)")
	handle.stop(1.0)
	service.advance(0.5)
	var half: float = material.get_shader_parameter("fade")
	check(half > 0.2 and half < 0.8, "half way through the stop the quad is half faded: %s" % half)
	service.advance(1.0)
	check(not handle.is_playing(), "and it is gone after the fade")
	eq(material.get_shader_parameter("fade"), 1.0, "the pooled quad is back at full strength")


func test_registering_a_new_definition_drops_pooled_instances_of_the_old_one() -> void:
	var service := _service()
	var first := _def(&"fx.swap", [_particles(&"a", 0.2)])
	service.register(first)
	service.play(first, FxAnchor.screen())
	service.advance(1.0)
	eq(service.pool_size(&"fx.swap"), 1, "an instance is pooled")
	var second := _def(&"fx.swap", [FxTweenLayer.new(), FxTweenLayer.new()])
	service.register(second)
	eq(service.pool_size(&"fx.swap"), 0, "the pool is flushed")
	var handle := service.play(second, FxAnchor.node3d(_keep(Node3D.new())))
	eq(handle.instance.nodes.size(), 2, "the new effect gets nodes built for it")
	handle.stop(0.0)


func test_a_reused_ui_holder_is_shown_again() -> void:
	var service := _service()
	var quad := FxShaderQuadLayer.new()
	quad.id = &"q"
	quad.shader = _quad_shader()
	quad.duration = 0.2
	quad.size = Vector2(40, 40)
	var def := _def(&"fx.shown", [quad], [], FxDefinition.Space.UI)
	service.register(def)
	var first := service.play(def, FxAnchor.control(_keep(Control.new())))
	first.instance.holder_ui.visible = false  # what a projected holder does behind the camera
	service.advance(1.0)
	var second := service.play(def, FxAnchor.control(_keep(Control.new())))
	check(second.instance.holder_ui.visible, "the pooled holder is visible on its next play")
	second.stop(0.0)


func test_listener_scales_the_magnitude_and_a_curve_needs_no_range() -> void:
	var service := _service()
	FxCueNotify.service_override = service
	var def := _def(&"fx.scaled", [_particles(&"a", 0.5)], [_param(&"power", FxParam.Kind.FLOAT, 0.0, 0.0, 100.0)])
	var listener := FxListener.new()
	listener.channel = &"Message.Test.FxScale"
	listener.effect = def
	listener.magnitude_param = &"power"
	listener.magnitude_scale = 0.01
	var owner_node := Node.new()
	host.add_child(owner_node)
	listener.attach(owner_node)
	GameplayMessages.broadcast(&"Message.Test.FxScale", VerbMessage.make(&"Verb.Damage", &"P1", &"E1", 1500))
	eq(service.live()[0].params[&"power"], 15.0, "damage 15.00 arrives as 15, not 1500")
	owner_node.free()
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0))
	curve.add_point(Vector2(1, 1))
	var binding := _bind("x", &"p")
	binding.curve = curve
	var unranged := _param(&"p", FxParam.Kind.FLOAT, 0.0, 5.0, 5.0)
	check(is_finite(float(binding.value_for(7.0, unranged))), "a curve with a min but no range does not divide by zero")


func test_headless_play_loads_nothing() -> void:
	var service := _service()
	service.enabled = false
	service.play(&"fx.hit_spark", FxAnchor.screen())
	check(service.world_root == null and service.screen_layer == null, "no host nodes are made while disabled")
	eq(service.stats()["skipped"], 1, "counted")


# --- Review findings (round 2) ------------------------------------------------------------------------------------------

func test_a_freed_anchor_still_gives_the_camera_back() -> void:
	var service := _service()
	var camera := Camera3D.new()
	_keep(camera)
	camera.current = true
	var shake := FxShakeLayer.new()
	shake.id = &"shake"
	shake.seconds = 1.0
	shake.strength_world = 1.0
	var def := _def(&"fx.camfree", [shake])
	service.register(def)
	var unit := Node3D.new()
	host.add_child(unit)
	service.play(def, FxAnchor.node3d(unit))
	service.advance(0.05)
	check(camera.h_offset != 0.0 or camera.v_offset != 0.0, "the camera is shaking")
	unit.free()
	service.advance(0.05)
	eq(camera.h_offset, 0.0, "the camera is back after the anchor was freed mid-shake")
	var again := _keep(Node3D.new()) as Node3D
	service.play(def, FxAnchor.node3d(again))
	service.advance(2.0)
	eq(camera.h_offset, 0.0, "and a later shake still restores it (the shared original was released)")


func test_live_retune_keeps_the_quality_scaling_and_the_light_peak() -> void:
	var service := _service()
	var layer := _particles(&"a", 5.0, 10)
	layer.bindings.append(_bind("amount", &"count"))
	var light := FxLightLayer.new()
	light.id = &"light"
	light.seconds = 2.0
	light.bindings.append(_bind("light_energy", &"power"))
	var def := _def(&"fx.retune", [layer, light], [_param(&"count", FxParam.Kind.INT, 10, 1, 100), _param(&"power", FxParam.Kind.FLOAT, 1.0, 0.0, 10.0)])
	service.register(def)
	service.quality = FxQuality.LOW
	var handle := service.play(def, FxAnchor.node3d(_keep(Node3D.new())), {"count": 50})
	eq(handle.instance.nodes[0].amount, 20, "low keeps 40% of a bound amount at play")
	handle.set_param(&"count", 100)
	eq(handle.instance.nodes[0].amount, 40, "and after a live retune")
	handle.set_param(&"power", 5.0)
	service.advance(0.1)
	check(handle.instance.nodes[1].light_energy > 4.0, "the light follows a retuned peak: %s" % handle.instance.nodes[1].light_energy)
	handle.stop(0.0)


func test_the_mesh_flash_skips_effect_quads() -> void:
	var service := _service()
	var flash := FxMeshFlashLayer.new()
	flash.id = &"flash"
	flash.seconds = 0.2
	var def := _def(&"fx.flashpick", [flash])
	service.register(def)
	var unit := Node3D.new()
	_keep(unit)
	var holder := Node3D.new()
	holder.name = "Fx3D_other"
	var quad := FxQuad3D.new()
	quad.mesh = QuadMesh.new()
	holder.add_child(quad)
	unit.add_child(holder)
	var body := MeshInstance3D.new()
	body.mesh = BoxMesh.new()
	var rig := Node3D.new()
	rig.add_child(body)
	unit.add_child(rig)
	service.play(def, FxAnchor.node3d(unit))
	check(body.material_overlay != null and quad.material_overlay == null, "the flash is on the body, not on another effect's quad")
	service.stop_all()


func test_fx_params_survives_empty_slots() -> void:
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	var broken := FxDefinition.new()
	broken.id = &"fx.broken_slots"
	broken.params.append(null)
	broken.layers.append(null)
	FxManager.register(broken)
	var reply: Dictionary = await console.execute("fx params fx.broken_slots")
	check(reply["ok"] and reply["text"].contains("empty"), "fx params names the empty slots: %s" % reply["text"])
	var checked: Dictionary = await console.execute("fx check fx.broken_slots")
	check(not checked["ok"], "fx check fails for it")
	FxManager._runtime.erase(&"fx.broken_slots")
	FxManager.reload()


# --- Review findings (round 3) ------------------------------------------------------------------------------------------

func test_a_screen_shake_moves_the_canvas_layers_the_ui_sits_under() -> void:
	var service := _service()
	var shake := FxShakeLayer.new()
	shake.id = &"shake"
	shake.seconds = 0.4
	shake.strength_px = 20.0
	var def := _def(&"fx.layershake", [shake], [], FxDefinition.Space.SCREEN)
	service.register(def)
	var layer := CanvasLayer.new()
	layer.offset = Vector2(5, 7)
	_keep(layer)
	service.play(def, FxAnchor.screen())
	service.advance(0.05)
	check(layer.offset != Vector2(5, 7), "the game's CanvasLayer is shaken (the viewport's canvas transform would not move it)")
	service.advance(1.0)
	eq(layer.offset, Vector2(5, 7), "and put back")


func test_a_unit_anchor_needs_an_id_and_skips_views_being_deleted() -> void:
	var service := _service()
	var def := _def(&"fx.unitpick", [_particles(&"a", 5.0)])
	service.register(def)
	check(not service.play(def, FxAnchor.unit(&"")).is_playing(), "an empty unit id plays nothing")
	var old_view := UnitAnimator.new()
	old_view.unit_id = &"P1"
	host.add_child(old_view)
	old_view.queue_free()
	var new_view := UnitAnimator.new()
	new_view.unit_id = &"P1"
	_keep(new_view)
	var handle := service.play(def, FxAnchor.unit(&"P1"))
	check(handle.is_playing() and handle.anchor.node == new_view, "the live view is picked, not the one queued for deletion")
	handle.stop(0.0)


func test_a_looping_effect_on_a_one_shot_cue_ends_after_the_delay() -> void:
	var service := _service()
	FxCueNotify.service_override = service
	var layer := _particles(&"aura", 0.2)
	layer.loop = true
	var cue := FxCueNotify.new()
	cue.fx = _def(&"fx.loopcue", [layer])
	cue.destroy_delay = 0.05
	cue.stop_fade = 0.05
	_keep(cue)
	var done := [0]
	cue.cue_finished.connect(func(_node, _tag) -> void: done[0] += 1)
	cue.execute_cue(_keep(Node3D.new()))
	eq(service.live_count(&"fx.loopcue"), 1, "it plays")
	await host.get_tree().create_timer(0.2).timeout
	service.advance(1.0)
	eq(done[0], 1, "the cue ended and the loop with it")
	eq(service.live_count(), 0, "nothing keeps looping")


# --- Review findings (round 4) ------------------------------------------------------------------------------------------

func test_looping_effects_are_not_recycled_by_the_instance_cap() -> void:
	var service := _service()
	var layer := _particles(&"aura", 0.2)
	layer.loop = true
	var def := _def(&"fx.manyauras", [layer])
	def.max_instances = 2
	service.register(def)
	var handles: Array[FxHandle] = []
	for index in 4:
		handles.append(service.play(def, FxAnchor.node3d(_keep(Node3D.new()))))
	for handle in handles:
		check(handle.is_playing(), "every unit keeps its aura")
	eq(service.stats()["recycled"], 0, "nothing was recycled")
	service.stop_all()


func test_a_stopped_quad_fades_even_without_driven_progress() -> void:
	var service := _service()
	var quad := FxShaderQuadLayer.new()
	quad.id = &"glow"
	quad.shader = _quad_shader()
	quad.loop = true
	quad.drive_progress = false
	var def := _def(&"fx.fadenoprogress", [quad], [], FxDefinition.Space.UI)
	service.register(def)
	var control := Control.new()
	control.size = Vector2(80, 80)
	_keep(control)
	var handle := service.play(def, FxAnchor.control(control))
	service.advance(0.5)
	handle.stop(1.0)
	service.advance(0.5)
	var half: float = ((handle.instance.nodes[0] as ColorRect).material as ShaderMaterial).get_shader_parameter("fade")
	check(half > 0.2 and half < 0.8, "the fade runs: %s" % half)
	handle.stop(0.0)


func test_a_parent_waits_for_its_sub_effects_tail() -> void:
	var service := _service()
	var child := _def(&"fx.slowchild", [_particles(&"p", 1.0)])
	var sub := FxSubFxLayer.new()
	sub.id = &"child"
	sub.effect = child
	var parent := _def(&"fx.tailparent", [sub])
	service.register(parent)
	var handle := service.play(parent, FxAnchor.node3d(_keep(Node3D.new())))
	service.advance(0.1)
	handle.stop(0.1)
	service.advance(0.3)
	check(handle.is_playing(), "the parent is still up while the child's particles are in the air")
	service.advance(2.0)
	check(not handle.is_playing(), "and ends after them")


func test_a_stale_cue_timer_cannot_end_a_reused_cue() -> void:
	var service := _service()
	FxCueNotify.service_override = service
	var layer := _particles(&"aura", 0.2)
	layer.loop = true
	var cue := FxCueNotify.new()
	cue.fx = _def(&"fx.timercue", [layer])
	cue.destroy_delay = 0.2
	_keep(cue)
	cue.execute_cue(_keep(Node3D.new()))
	cue.finish_cue()  # ended early (anchor freed, stop_all): the node goes back to GodotGAS's pool
	service.stop_all()
	cue.execute_cue(_keep(Node3D.new()))  # reused for another unit's hit
	await host.get_tree().create_timer(0.3).timeout  # the first play's timer fires now
	check(cue._handle != null and cue._handle.is_playing(), "the second play was not ended by the first play's timer")
	service.stop_all()


func test_the_cue_manager_remembers_a_scene_that_fails_to_load() -> void:
	var manager := GameplayCueManager
	var entry := GameplayCueEntry.new()
	entry.tag = &"Cue.Test.Broken"
	entry.scene_ref = "res://does/not/exist.tscn"
	manager._entries[entry.tag] = entry
	manager._pool[entry.tag] = []
	check(manager.has_cue(entry.tag), "the cue is known")
	check(manager._scene_for(entry.tag) == null, "its scene does not load (one warning, no engine error)")
	check(not manager.has_cue(entry.tag), "and it is dropped, so later hits do not retry or warn")
	manager._pool.erase(entry.tag)


func test_registering_a_cue_again_frees_its_pooled_nodes() -> void:
	var manager := GameplayCueManager
	var tag := &"Cue.Test.Replace"
	var scene := PackedScene.new()
	var node := FxCueNotify.new()
	scene.pack(node)
	node.free()
	manager.register_cue(tag, scene)
	var pooled := Node.new()
	manager._pool[tag].append(pooled)
	manager.register_cue(tag, scene)
	check(not is_instance_valid(pooled), "the old pooled node was freed")
	manager.unregister_cue(tag)


# --- The Settings quality selector and the inspector's Preview button -----------------------------------------------------

func test_the_settings_screen_has_the_effects_quality_selector() -> void:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	_nodes.append(game)
	game.content_root = FIXTURES
	game.load_content()
	var screen := game.ui.push(&"UI.Layer.Menu", load("res://presentation/demo/ui/settings.tscn"))
	check(screen != null, "the Settings screen opens")
	if screen == null:
		return
	var picker := screen.get_node_or_null("%FxQuality") as OptionButton
	check(picker != null, "it has the quality selector")
	if picker == null:
		return
	eq(picker.item_count, 4, "four tiers")
	var names: Array[String] = []
	for index in picker.item_count:
		names.append(picker.get_item_text(index))
	eq(names, ["Off", "Low", "Medium", "High"], "named like the console's tiers")
	eq(picker.selected, FxManager.quality, "the current tier is selected")
	check(picker.item_selected.get_connections().size() > 0, "choosing a tier is wired (it applies the tier and saves the Settings key)")


func test_the_preview_request_reaches_the_gallery() -> void:
	var path := "res://presentation/demo/fx/hit_spark.tres"
	eq(FxPreviewRequest.write(path), OK, "the request is written")
	eq(FxPreviewRequest.take(), path, "and read back")
	eq(FxPreviewRequest.take(), "", "once: it is deleted when read")
	FxPreviewRequest.write(path)
	var gallery := (load("res://game/dev/fx_gallery.tscn") as PackedScene).instantiate()
	host.add_child(gallery)
	_nodes.append(gallery)
	eq(FxPreviewRequest.take(), "", "the gallery consumed the request")
	check(FxManager.definition(&"fx.hit_spark") != null, "and registered the effect it names")


# --- Changing the quality tier while effects are playing ------------------------------------------------------------------

func _tiered_loop(effect_id: StringName) -> FxDefinition:
	var low := _particles(&"low", 0.5, 10)
	low.loop = true
	var medium := _particles(&"medium", 0.5, 10)
	medium.loop = true
	medium.min_quality = FxLayer.Quality.MEDIUM
	var high := _particles(&"high", 0.5, 10)
	high.loop = true
	high.min_quality = FxLayer.Quality.HIGH
	return _def(effect_id, [low, medium, high])


func test_switching_to_off_stops_every_live_effect() -> void:
	var service := _service()
	var aura := _tiered_loop(&"fx.offloop")
	var shot := _def(&"fx.offshot", [_particles(&"a", 5.0)])
	service.register(aura)
	service.register(shot)
	var anchor := FxAnchor.node3d(_keep(Node3D.new()))
	var loop_handle := service.play(aura, anchor)
	var shot_handle := service.play(shot, anchor)
	var heard := [0]
	service.quality_changed.connect(func(_tier: int) -> void: heard[0] += 1)
	service.quality = FxQuality.OFF
	check(not loop_handle.is_playing() and not shot_handle.is_playing(), "off ends the loop and the one-shot")
	eq(service.live_count(), 0, "nothing is live")
	eq(heard[0], 1, "quality_changed fired once")
	service.quality = FxQuality.OFF
	eq(heard[0], 1, "setting the same tier again does nothing")


func test_changing_the_tier_re_applies_a_running_loop() -> void:
	var service := _service()
	var def := _tiered_loop(&"fx.retier")
	service.register(def)
	var handle := service.play(def, FxAnchor.node3d(_keep(Node3D.new())))
	service.advance(0.1)
	eq(handle.states[2], FxHandle.LayerState.RUNNING, "high runs all three layers")
	eq(handle.instance.nodes[0].amount, 10, "at full amount")
	service.quality = FxQuality.LOW
	check(handle.is_playing(), "the same handle keeps playing")
	eq(handle.states[0], FxHandle.LayerState.RUNNING, "the low layer stays")
	eq(handle.states[1], FxHandle.LayerState.SKIPPED, "the medium layer stops")
	eq(handle.states[2], FxHandle.LayerState.SKIPPED, "the high layer stops")
	check(not handle.instance.nodes[2].emitting, "and its particles stop emitting")
	eq(handle.instance.nodes[0].amount, 4, "the low layer's count follows the tier (40%)")
	service.quality = FxQuality.MEDIUM
	service.advance(0.1)
	eq(handle.states[1], FxHandle.LayerState.RUNNING, "medium brings the medium layer back")
	eq(handle.states[2], FxHandle.LayerState.SKIPPED, "and not the high one")
	eq(handle.instance.nodes[0].amount, 7, "at 70%")
	service.quality = FxQuality.HIGH
	service.advance(0.1)
	eq(handle.states[2], FxHandle.LayerState.RUNNING, "high brings everything back")
	eq(handle.instance.nodes[0].amount, 10, "at full amount")
	check(handle.instance.nodes[2].emitting, "and the high layer emits again")
	service.stop_all()


func test_a_loop_with_every_layer_above_the_tier_stays_alive() -> void:
	var service := _service()
	var only_high := _particles(&"high", 0.5, 10)
	only_high.loop = true
	only_high.min_quality = FxLayer.Quality.HIGH
	var def := _def(&"fx.allhigh", [only_high])
	service.register(def)
	var handle := service.play(def, FxAnchor.node3d(_keep(Node3D.new())))
	service.quality = FxQuality.LOW
	service.advance(1.0)
	check(handle.is_playing(), "the loop is not ended by the tier: a higher tier can bring it back")
	service.quality = FxQuality.HIGH
	service.advance(0.1)
	eq(handle.states[0], FxHandle.LayerState.RUNNING, "and it runs again")
	handle.stop(0.0)


func test_one_shots_in_flight_are_not_changed_by_a_new_tier() -> void:
	var service := _service()
	var layers := [_particles(&"a", 1.0, 10)]
	var high := _particles(&"b", 1.0, 10)
	high.min_quality = FxLayer.Quality.HIGH
	layers.append(high)
	var def := _def(&"fx.inflight", layers)
	service.register(def)
	var handle := service.play(def, FxAnchor.node3d(_keep(Node3D.new())))
	service.quality = FxQuality.LOW
	check(handle.is_playing(), "the one-shot is still playing")
	eq(handle.states[1], FxHandle.LayerState.RUNNING, "with the layers it started with")
	service.advance(3.0)
	check(not handle.is_playing(), "and ends on its own")


func test_a_persistent_cue_that_played_while_effects_were_off_starts_when_the_tier_is_raised() -> void:
	var service := _service()
	FxCueNotify.service_override = service
	service.quality = FxQuality.OFF
	var cue := FxCueNotify.new()
	cue.fx = _tiered_loop(&"fx.cueoff")
	cue.auto_destroy = false
	cue.stop_fade = 0.05
	_keep(cue)
	var done := [0]
	cue.cue_finished.connect(func(_node, _tag) -> void: done[0] += 1)
	cue.execute_cue(_keep(Node3D.new()))
	eq(service.live_count(), 0, "nothing plays at off")
	service.quality = FxQuality.MEDIUM
	eq(service.live_count(&"fx.cueoff"), 1, "raising the tier starts the aura of the cue that is still on")
	cue.end_cue()
	service.advance(1.0)
	eq(done[0], 1, "ending the cue finishes it")
	service.quality = FxQuality.HIGH
	eq(service.live_count(), 0, "and a later tier change starts nothing for a cue that ended")
