## Spec vfx-content-pass: the pieces the content effects stand on: listener tag filters and tag-driven parameters, the text
## layer, the flipbook fields, the message bridge for hits and HP changes, and the shipped slice (rules and effects) read as
## data. Built in memory and driven on a scripted clock, like test_fx.
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


func _service() -> FxService:
	var service := FxService.new()
	service.enabled = true
	service.manual_clock = true
	host.add_child(service)
	_services.append(service)
	FxCueNotify.service_override = service
	return service


func _param(param_name: StringName, kind: FxParam.Kind, default: Variant) -> FxParam:
	var param := FxParam.new()
	param.name = param_name
	param.kind = kind
	param.default_value = default
	return param


func _bind(property: String, param: StringName) -> FxBinding:
	var binding := FxBinding.new()
	binding.property = property
	binding.param = param
	return binding


## A tiny number effect: the text layer with the same bindings as the shipped damage number.
func _number_effect() -> FxDefinition:
	var layer := FxTextLayer.new()
	layer.id = &"number"
	layer.seconds = 1.0
	layer.bindings = [_bind("text", &"text"), _bind("modulate", &"color"), _bind("font_size", &"font_size")]
	var definition := FxDefinition.new()
	definition.id = &"fx.test_number"
	definition.space = FxDefinition.Space.WORLD_3D
	definition.layers.assign([layer])
	definition.params.assign([_param(&"text", FxParam.Kind.STRING, "0"), _param(&"color", FxParam.Kind.COLOR, Color.WHITE),
		_param(&"font_size", FxParam.Kind.INT, 64), _param(&"label", FxParam.Kind.STRING, ""),
		_param(&"label_color", FxParam.Kind.COLOR, Color.WHITE)])
	return definition


func _listener(channel: StringName, effect: FxDefinition) -> FxListener:
	var listener := FxListener.new()
	listener.channel = channel
	listener.effect = effect
	listener.anchor_rule = FxListener.AnchorRule.SCREEN
	return listener


func _owner() -> Node:
	var owner_node := Node.new()
	host.add_child(owner_node)
	_nodes.append(owner_node)
	return owner_node


# --- Listener filters and tag parameters ---------------------------------------------------------------------------

func test_tag_filters() -> void:
	var listener := _listener(&"Message.Test.Vc", _number_effect())
	listener.require_tags = [&"Damage.Type.Fire"]
	listener.exclude_tags = [&"Hit.Resisted"]
	var fire := VerbMessage.make(&"Verb.Damage", &"P1", &"E1", 100, [&"Damage.Type.Fire"])
	var resisted := VerbMessage.make(&"Verb.Damage", &"P1", &"E1", 100, [&"Damage.Type.Fire", &"Hit.Resisted"])
	var ice := VerbMessage.make(&"Verb.Damage", &"P1", &"E1", 100, [&"Damage.Type.Ice"])
	check(listener.accepts(fire), "a required tag lets it through")
	check(not listener.accepts(resisted), "an excluded tag stops it")
	check(not listener.accepts(ice), "a missing required tag stops it")
	listener.require_tags = [&"Damage.Type"]
	check(listener.accepts(ice), "a tag matches its children (Damage.Type hears Damage.Type.Ice)")
	check(not FxListener.tag_matches([&"Hit.WeaknessX"], &"Hit.Weakness"), "a longer name is not a child")
	var open := _listener(&"Message.Test.Vc", _number_effect())
	check(open.accepts(fire) and open.accepts(GameplayMessage.new()), "no filter: every message passes, as before")
	var verb := _listener(&"Message.Test.Vc", _number_effect())
	verb.require_verb = &"Verb.Heal"
	check(not verb.accepts(fire), "a verb filter needs that verb")


func test_tag_params_text_and_order() -> void:
	var service := _service()
	var listener := _listener(&"Message.Test.VcParams", _number_effect())
	listener.text_param = &"text"
	listener.text_prefix = "+"
	listener.tag_params = {
		"Hit.Weakness": {"label": "Weak!", "font_size": 76},
		"Hit.Critical": {"label": "Crit!", "font_size": 96},
		"Damage.Type.Fire": {"color": Color.ORANGE}}
	listener.tag_order = [&"Hit.Weakness", &"Hit.Critical"]
	listener.attach(_owner())
	GameplayMessages.broadcast(&"Message.Test.VcParams",
		VerbMessage.make(&"Verb.Damage", &"", &"E1", 245600, [&"Damage.Type.Fire", &"Hit.Critical", &"Hit.Weakness"]))
	var params: Dictionary = service.live()[0].params
	eq(params[&"text"], "+2456", "the amount arrives as a whole number, x100 removed, with the prefix")
	eq(params[&"color"], Color.ORANGE, "the damage type chose the colour")
	eq(params[&"label"], "Crit!", "the crit wins over the weakness whatever the dictionary order")
	eq(params[&"font_size"], 96, "and sets the size")
	GameplayMessages.broadcast(&"Message.Test.VcParams", VerbMessage.make(&"Verb.Damage", &"", &"E1", 5000, [&"Hit.Weakness"]))
	eq(service.live()[1].params[&"label"], "Weak!", "a weakness alone shows Weak!")


func test_string_parameter() -> void:
	var param := _param(&"text", FxParam.Kind.STRING, "12")
	check(param.accepts("x") and param.accepts(&"y") and not param.accepts(3), "a string parameter takes text")
	eq(param.parse_text("Crit!")["value"], "Crit!", "the console passes the text as it is")
	eq(param.default(), "12", "the default is the text")


# --- The text layer ------------------------------------------------------------------------------------------------

func test_number_rises_pops_and_fades() -> void:
	var service := _service()
	var definition := _number_effect()
	var handle := service.play(definition, FxAnchor.position3d(Vector3.ZERO), {"text": "9999", "color": Color.RED, "label": "Crit!"})
	var label := _label(service)
	eq(label.text, "9999", "the bound text is shown")
	eq(label.modulate.r, 1.0, "the bound colour")
	check((label.get_child(0) as Label3D).visible and (label.get_child(0) as Label3D).text == "Crit!", "the tag line above shows Crit!")
	service.advance(0.05)
	var early := label.position.y
	var scale_early := label.scale.x
	service.advance(0.5)
	check(label.position.y > early, "it rises")
	check(scale_early != 1.0, "it pops in (scale differs from 1 early)")
	service.advance(0.45)
	check(label.modulate.a < 0.9, "it fades near the end of its life")
	service.advance(0.5)
	check(not handle.is_playing(), "it is gone after its seconds")


func test_number_arrives_large_and_transparent() -> void:
	var service := _service()
	service.play(_number_effect(), FxAnchor.position3d(Vector3.ZERO), {"text": "7"})
	var label := _label(service)
	service.advance(0.02)
	check(label.scale.x > 1.6, "it starts large (%s)" % label.scale.x)
	check(label.modulate.a < 0.3, "and nearly transparent (%s)" % label.modulate.a)
	service.advance(0.2)
	check(absf(label.scale.x - 1.0) < 0.05 and label.modulate.a > 0.95, "it settles at normal size, fully visible")
	var spots := {}
	for index in 12:
		service.play(_number_effect(), FxAnchor.position3d(Vector3.ZERO), {"text": "1"})
		spots[_label(service).position] = true
	check(spots.size() > 6, "each number spawns at its own spot around the target")


func test_number_without_a_label_hides_the_tag() -> void:
	var service := _service()
	service.play(_number_effect(), FxAnchor.position3d(Vector3.ZERO), {"text": "5"})
	check(not (_label(service).get_child(0) as Label3D).visible, "no label parameter: no tag line")


func _label(service: FxService) -> Label3D:
	var handles := service.live()
	return handles[handles.size() - 1].instance.nodes[0] as Label3D


# --- Flipbook fields ------------------------------------------------------------------------------------------------

func test_flipbook_and_depth_bias_reach_the_material() -> void:
	var layer := FxParticles3DLayer.new()
	layer.h_frames = 8
	layer.v_frames = 4
	layer.anim_cycles = 1.0
	layer.random_frame = true
	layer.additive = false
	layer.depth_bias = 0.8
	var node := layer.build() as GPUParticles3D
	var draw := (node.draw_pass_1 as QuadMesh).material as ShaderMaterial
	eq(draw.get_shader_parameter("h_frames"), 8, "the sheet's columns")
	eq(draw.get_shader_parameter("v_frames"), 4, "and rows")
	eq(draw.get_shader_parameter("additive"), 0.0, "normal blending")
	eq(draw.get_shader_parameter("depth_bias"), 0.8, "the depth bias that keeps a unit's mesh from cutting the quad")
	var process := node.process_material as ParticleProcessMaterial
	eq(process.anim_speed_min, 1.0, "the sheet plays once over a particle's life")
	eq(process.anim_offset_max, 1.0, "random_frame starts each particle on its own frame")
	node.free()
	var plain := FxParticles3DLayer.new().build() as GPUParticles3D
	eq(((plain.draw_pass_1 as QuadMesh).material as ShaderMaterial).get_shader_parameter("h_frames"), 1, "a plain texture is not a flipbook")
	plain.free()


func test_bias_binds_to_an_effect_parameter() -> void:
	var service := _service()
	var layer := FxParticles3DLayer.new()
	layer.id = &"p"
	layer.bindings = [_bind("draw_pass_1:material:shader_parameter/depth_bias", &"depth_bias")]
	var definition := FxDefinition.new()
	definition.id = &"fx.test_bias"
	definition.space = FxDefinition.Space.WORLD_3D
	definition.layers.assign([layer])
	definition.params.assign([_param(&"depth_bias", FxParam.Kind.FLOAT, 0.0)])
	service.play(definition, FxAnchor.position3d(Vector3.ZERO), {"depth_bias": 0.9})
	var particles := service.live()[0].instance.nodes[0] as GPUParticles3D
	eq(((particles.draw_pass_1 as QuadMesh).material as ShaderMaterial).get_shader_parameter("depth_bias"), 0.9, "a play sets the bias")


func test_fresnel_overlay_sets_and_restores() -> void:
	var service := _service()
	var layer := FxFresnelLayer.new()
	layer.id = &"rim"
	layer.seconds = 0.5
	layer.color = Color.ORANGE
	layer.power = 3.0
	layer.bindings = [_bind("color", &"color")]
	var definition := FxDefinition.new()
	definition.id = &"fx.test_fresnel"
	definition.space = FxDefinition.Space.WORLD_3D
	definition.layers.assign([layer])
	definition.params.assign([_param(&"color", FxParam.Kind.COLOR, Color.ORANGE)])
	var unit := Node3D.new()
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	unit.add_child(mesh)
	host.add_child(unit)
	_nodes.append(unit)
	var handle := service.play(definition, FxAnchor.node3d(unit), {"color": Color.CYAN})
	var overlay := mesh.material_overlay as ShaderMaterial
	check(overlay != null and overlay.shader != null, "the mesh gets a rim-glow overlay")
	service.advance(0.05)
	eq(overlay.get_shader_parameter("color"), Color.CYAN, "the bound colour reaches the shader")
	eq(overlay.get_shader_parameter("power"), 3.0, "and the rim power")
	check(float(overlay.get_shader_parameter("strength")) > 0.5, "it starts strong")
	service.advance(0.6)
	check(not handle.is_playing() and mesh.material_overlay == null, "it ends and puts the mesh's overlay back")


# --- Rule set and the shipped slice ---------------------------------------------------------------------------------

func test_rule_set_attaches_every_rule() -> void:
	var service := _service()
	var rules := FxRuleSet.new()
	var a := _listener(&"Message.Test.VcRulesA", _number_effect())
	var b := _listener(&"Message.Test.VcRulesB", _number_effect())
	rules.rules.assign([a, b])
	var owner_node := _owner()
	eq(rules.attach(owner_node).size(), 2, "one handle per rule")
	GameplayMessages.broadcast(&"Message.Test.VcRulesA", VerbMessage.make(&"Verb.Damage", &"", &"E1", 100))
	GameplayMessages.broadcast(&"Message.Test.VcRulesB", VerbMessage.make(&"Verb.Damage", &"", &"E1", 100))
	eq(service.live().size(), 2, "both rules played")
	owner_node.free()
	eq(GameplayMessages.listener_count(&"Message.Test.VcRulesA"), 0, "the rules left with the node")


func test_shipped_slice_validates() -> void:
	if skip_in_export():
		return
	check(ResourceLoader.exists("res://presentation/demo/fx/battle_fx_rules.tres"), "the rule set exists (build_vfx_slice.tscn)")
	var rules := load("res://presentation/demo/fx/battle_fx_rules.tres") as FxRuleSet
	check(rules != null and rules.rules.size() >= 4, "the battle rules load")
	# Lyra's way (the user, 2026-11-09): the numbers are a cue, Cue.Fx.Number, styled by its FxNumberStyles.
	var number_rules := rules.rules.filter(func(rule) -> bool: return rule != null and rule.cue == &"Cue.Fx.Number")
	eq(number_rules.map(func(rule): return rule.channel), [&"Message.Battle.Damage", &"Message.Battle.HpChanged"],
		"hits and HP changes both pop the number cue")
	for rule in rules.rules:
		check((rule.effect != null and rule.effect.id != &"") or rule.cue != &"", "every rule names an effect or a cue")
		if rule.cue != &"":
			check(GameplayCueManager.has_cue(rule.cue), "%s is in the cue registry" % rule.cue)
		check(rule.channel == &"Message.Battle.Damage" or rule.channel == &"Message.Battle.HpChanged", "on a battle channel")
	var service := _service()
	for effect_id in [&"fx.damage_number", &"fx.fire_hit", &"fx.ice_hit", &"fx.explosion", &"fx.poison_tick"]:
		var definition := load("res://presentation/demo/fx/%s.tres" % String(effect_id).trim_prefix("fx.")) as FxDefinition
		check(definition != null and definition.id == effect_id, "%s loads" % effect_id)
		var handle := service.play(definition, FxAnchor.position3d(Vector3.ZERO), {})
		check(handle != null, "%s plays at every default" % effect_id)
		service.stop_all()


# --- Sockets, radius, surface emission (spec vfx-content-pass 3.6) -----------------------------------------------------

## A view built in memory: a box body (size `size`) under a Node3D, kept so after_each frees it.
func _view(size: Vector3) -> Node3D:
	var view := Node3D.new()
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	body.mesh = box
	body.name = "Body"
	view.add_child(body)
	host.add_child(view)
	_nodes.append(view)
	return view


func test_sockets_derive_from_the_mesh_bounds() -> void:
	var view := _view(Vector3(1, 2, 1))
	eq(FxAttach.socket_position(view, FxSocket.CENTER), Vector3.ZERO, "Center is the middle of the box")
	eq(FxAttach.socket_position(view, FxSocket.HIT), Vector3.ZERO, "Hit is the middle too")
	eq(FxAttach.socket_position(view, FxSocket.TOP), Vector3(0, 1, 0), "Top is the middle of the top face")
	eq(FxAttach.socket_position(view, FxSocket.BASE), Vector3(0, -1, 0), "Base is the middle of the bottom face")
	check(is_equal_approx(FxAttach.radius(view), sqrt(6.0) * 0.5), "the radius is the bounding sphere's")
	eq(FxAttach.socket_position(Node3D.new(), FxSocket.TOP), Vector3.ZERO, "a plain node: the effect sits on its origin, as before")


func test_an_explicit_socket_wins_and_the_radius_can_be_set() -> void:
	var view := _view(Vector3.ONE)
	var marker := FxSocket.new()
	marker.role = FxSocket.TOP
	marker.position = Vector3(0, 3, 0)
	view.add_child(marker)
	eq(FxAttach.socket_position(view, FxSocket.TOP), Vector3(0, 3, 0), "the marker, not the box")
	eq(FxAttach.socket_position(view, FxSocket.BASE), Vector3(0, -0.5, 0), "the other roles still derive")
	var script := GDScript.new()
	script.source_code = "extends Node3D
var fx_radius: float = 2.5
"
	script.reload()
	var sized := Node3D.new()
	sized.set_script(script)
	host.add_child(sized)
	_nodes.append(sized)
	eq(FxAttach.radius(sized), 2.5, "a view's own fx_radius wins")


func _socket_effect(socket: StringName, layer_socket: StringName = &"") -> FxDefinition:
	var layer := FxParticles3DLayer.new()
	layer.id = &"p"
	layer.socket = layer_socket
	layer.bindings = [_bind("draw_pass_1:material:shader_parameter/depth_bias", &"depth_bias")]
	var definition := FxDefinition.new()
	definition.id = &"fx.test_socket"
	definition.space = FxDefinition.Space.WORLD_3D
	definition.socket = socket
	definition.layers.assign([layer])
	definition.params.assign([_param(&"depth_bias", FxParam.Kind.FLOAT, 0.1)])
	return definition


func test_an_effect_attaches_at_its_socket_and_a_layer_can_move_off_it() -> void:
	var service := _service()
	var view := _view(Vector3(1, 2, 1))
	var handle := service.play(_socket_effect(FxSocket.TOP), FxAnchor.node3d(view))
	eq(handle.instance.holder_3d.position, Vector3(0, 1, 0), "the effect sits on the Top socket")
	service.stop_all()
	handle = service.play(_socket_effect(FxSocket.TOP), FxAnchor.node3d(view, Vector3.ZERO, FxSocket.BASE))
	eq(handle.instance.holder_3d.position, Vector3(0, -1, 0), "the anchor can name another socket")
	service.stop_all()
	handle = service.play(_socket_effect(FxSocket.CENTER, FxSocket.BASE), FxAnchor.node3d(view))
	eq(handle.instance.holder_3d.position, Vector3.ZERO, "the effect stays on its own socket")
	eq(handle.instance.nodes[0].position, Vector3(0, -1, 0), "and the layer moves itself to Base")


func test_the_unit_radius_is_the_default_depth_bias() -> void:
	var service := _service()
	var view := _view(Vector3(1, 2, 1))
	var handle := service.play(_socket_effect(FxSocket.CENTER), FxAnchor.node3d(view))
	check(is_equal_approx(float(handle.params[&"depth_bias"]), sqrt(6.0) * 0.5), "no bias passed: the unit's radius")
	var explicit := service.play(_socket_effect(FxSocket.CENTER), FxAnchor.node3d(view), {"depth_bias": 0.2})
	eq(explicit.params[&"depth_bias"], 0.2, "an explicit value wins")
	var plain := service.play(_socket_effect(FxSocket.CENTER), FxAnchor.position3d(Vector3.ZERO))
	eq(plain.params[&"depth_bias"], 0.1, "an anchor with no radius keeps the effect's own default")
	var anchor := FxAnchor.node3d(view)
	service.play(_socket_effect(FxSocket.TOP), anchor)
	eq(anchor.socket_offset, Vector3.ZERO, "the caller's anchor is left alone, so it can be reused")


func test_surface_points_lie_on_the_mesh_and_the_emitter_follows_it() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(1, 1, 1)
	var points := FxParticles3DLayer.points_for(box, 64)
	eq(points.get_width(), 64, "one point per slot")
	var image := points.get_image()
	var on_surface := 0
	for slot in 64:
		var point := image.get_pixel(slot, 0)
		if is_equal_approx(maxf(maxf(absf(point.r), absf(point.g)), absf(point.b)), 0.5):
			on_surface += 1
	eq(on_surface, 64, "every point is on one of the box's faces")
	check(FxParticles3DLayer.points_for(box, 64) == points, "the points are cached per mesh")
	var upward := FxParticles3DLayer.points_for(box, 64, 0.9).get_image()
	var on_top := 0
	for slot in 64:
		if is_equal_approx(upward.get_pixel(slot, 0).g, 0.5):
			on_top += 1
	eq(on_top, 64, "a minimum upward normal keeps only the top face (nothing is born under the unit)")
	var service := _service()
	var view := _view(Vector3.ONE)
	view.position = Vector3(2, 0, 0)
	var layer := FxParticles3DLayer.new()
	layer.id = &"emit"
	layer.emit_from_mesh = true
	var definition := FxDefinition.new()
	definition.id = &"fx.test_emit"
	definition.space = FxDefinition.Space.WORLD_3D
	definition.layers.assign([layer])
	service.play(definition, FxAnchor.node3d(view))
	var particles := service.live()[0].instance.nodes[0] as GPUParticles3D
	var material := particles.process_material as ParticleProcessMaterial
	eq(material.emission_shape, ParticleProcessMaterial.EMISSION_SHAPE_POINTS, "the layer emits from points")
	eq(particles.global_position, view.global_position, "from the mesh's own place")
	view.position = Vector3(5, 0, 0)
	service.advance(0.05)
	eq(particles.global_position, view.global_position, "and it follows the mesh as the unit moves")


func test_soft_distance_and_shell_reach_their_shaders() -> void:
	var layer := FxParticles3DLayer.new()
	layer.soft_distance = 0.4
	var node := layer.build() as GPUParticles3D
	eq(((node.draw_pass_1 as QuadMesh).material as ShaderMaterial).get_shader_parameter("soft_distance"), 0.4, "the soft fade distance")
	node.free()
	var shell := FxFresnelLayer.new()
	shell.fill = 0.3
	shell.grow = 0.02
	shell.erosion = 0.4
	shell.scroll = 1.5
	var overlay := shell.make_overlay() as ShaderMaterial
	var holder := shell.build()
	shell.set_strength(overlay, holder, 0.8)
	eq(overlay.get_shader_parameter("grow"), 0.02, "the shell grows out along the normal")
	eq(overlay.get_shader_parameter("erosion"), 0.4, "and the noise eats it")
	eq(overlay.get_shader_parameter("scroll"), 1.5, "scrolling up the body")
	holder.free()


# --- Status cues (spec vfx-content-pass, group 2: DoTs and controls) ----------------------------------------------------

## status effect file -> [persistent cue, periodic cue or ""]
const STATUS_CUES: Dictionary = {
	"poison": ["Cue.Fx.Status.Poison", "Cue.Fx.Tick.Poison"], "poison_2": ["Cue.Fx.Status.Poison", "Cue.Fx.Tick.Poison"],
	"bleed": ["Cue.Fx.Status.Bleed", "Cue.Fx.Tick.Bleed"], "burn": ["Cue.Fx.Status.Burn", "Cue.Fx.Tick.Burn"],
	"freeze": ["Cue.Fx.Status.Freeze", ""], "stun": ["Cue.Fx.Status.Stun", ""], "entangle": ["Cue.Fx.Status.Entangle", ""],
	"slow": ["Cue.Fx.Status.Slow", ""]}


func test_dot_and_control_statuses_name_their_cues_and_the_cues_exist() -> void:
	if skip_in_export():
		return
	var registry := load("res://godot_gas/cue_registry.tres") as GameplayCueRegistry
	var registered := {}
	for entry in registry.entries:
		registered[entry.tag] = entry
	for file in STATUS_CUES:
		var status := load("res://content/demo/effects/%s.tres" % file) as GameplayEffect
		var wanted: Array = STATUS_CUES[file]
		eq(status.persistent_cue_tags, [StringName(wanted[0])], "%s shows its look while it lasts" % file)
		eq(status.periodic_cue_tags, [StringName(wanted[1])] if wanted[1] != "" else [], "%s ticks as intended" % file)
		for tag in [wanted[0], wanted[1]]:
			if tag == "":
				continue
			check(registered.has(StringName(tag)), "%s is in the cue registry" % tag)
			var scene := load(registered[StringName(tag)].scene_ref) as PackedScene
			check(scene != null, "%s has a cue scene" % tag)
			var cue := scene.instantiate() as FxCueNotify
			check(cue != null and cue.fx != null and cue.fx.id != &"", "%s plays an effect" % tag)
			if cue != null:
				check(cue.auto_destroy == (tag == wanted[1]), "%s: a status look persists, a tick is a one-shot" % tag)
				if wanted[1] == "" or tag == wanted[0]:
					check(cue.fx.is_looping(), "%s: a persistent look is a looping effect" % tag)
				cue.free()


func test_status_effects_play_at_every_tier() -> void:
	if skip_in_export():
		return
	var service := _service()
	var view := _view(Vector3(0.8, 0.8, 0.8))
	for effect_id in ["status_skin", "burning", "frozen", "stun_stars", "bleed_tick"]:
		var definition := load("res://presentation/demo/fx/%s.tres" % effect_id) as FxDefinition
		check(definition != null, "%s loads" % effect_id)
		for tier in [FxQuality.LOW, FxQuality.MEDIUM, FxQuality.HIGH]:
			service.quality = tier
			var handle := service.play(definition, FxAnchor.node3d(view))
			check(handle.is_playing(), "%s plays at tier %d" % [effect_id, tier])
			service.advance(0.3)
			service.stop_all()


func test_status_cues_play_through_the_real_cue_manager() -> void:
	if skip_in_export():
		return
	var service := _service()
	var was_suppressed: bool = GameplayCueManager.suppress_cues
	GameplayCueManager.suppress_cues = false  # headless suppresses cues; this test wants the real path
	var target := _view(Vector3(0.8, 0.8, 0.8))
	for tag in ["Cue.Fx.Status.Poison", "Cue.Fx.Status.Burn", "Cue.Fx.Status.Freeze", "Cue.Fx.Status.Stun", "Cue.Fx.Status.Slow"]:
		var persistent := GameplayCueManager.add_persistent_cue(StringName(tag), target, {})
		check(persistent != null and service.live_count() == 1, "%s starts a looping look through GodotGAS" % tag)
		service.advance(5.0)
		eq(service.live_count(), 1, "%s lasts as long as the status" % tag)
		GameplayCueManager.remove_persistent_cue(persistent)
		service.advance(4.0)  # the fade, then the particles already in the air
		eq(service.live_count(), 0, "%s fades away when the status ends" % tag)
	for tag in ["Cue.Fx.Tick.Poison", "Cue.Fx.Tick.Bleed", "Cue.Fx.Tick.Burn"]:
		GameplayCueManager.execute_cue(StringName(tag), target, {})
		eq(service.live_count(), 1, "%s plays one tick" % tag)
		service.advance(3.0)
		eq(service.live_count(), 0, "%s ends by itself" % tag)
	GameplayCueManager.suppress_cues = was_suppressed


# --- Buffs, debuffs and support (spec vfx-content-pass, group 3) -------------------------------------------------------------

## status effect file -> [persistent cue, apply cue or ""]
const STAT_CUES: Dictionary = {
	"rally": ["Cue.Fx.Buff.AttackUp", "Cue.Fx.Apply.Buff"], "rally_2": ["Cue.Fx.Buff.AttackUp", "Cue.Fx.Apply.Buff"],
	"rally_3": ["Cue.Fx.Buff.AttackUp", "Cue.Fx.Apply.Buff"], "breakers_fury": ["Cue.Fx.Buff.AttackUp", "Cue.Fx.Apply.Buff"],
	"corrupted_oath_fury": ["Cue.Fx.Buff.AttackUp", "Cue.Fx.Apply.Buff"], "interrupt_fury": ["Cue.Fx.Buff.AttackUp", "Cue.Fx.Apply.Buff"],
	"defense_up": ["Cue.Fx.Buff.DefenseUp", "Cue.Fx.Apply.Buff"], "defense_up_2": ["Cue.Fx.Buff.DefenseUp", "Cue.Fx.Apply.Buff"],
	"defense_up_3": ["Cue.Fx.Buff.DefenseUp", "Cue.Fx.Apply.Buff"], "haste": ["Cue.Fx.Buff.Haste", "Cue.Fx.Apply.Buff"],
	"haste_2": ["Cue.Fx.Buff.Haste", "Cue.Fx.Apply.Buff"], "haste_3": ["Cue.Fx.Buff.Haste", "Cue.Fx.Apply.Buff"],
	"regen": ["Cue.Fx.Buff.Regen", "Cue.Fx.Apply.Buff"], "ward": ["Cue.Fx.Buff.Ward", "Cue.Fx.Apply.Buff"],
	"taunt": ["Cue.Fx.Buff.Taunt", "Cue.Fx.Apply.Buff"], "fury": ["Cue.Fx.Buff.Fury", "Cue.Fx.Apply.Buff"],
	"enrage": ["Cue.Fx.Buff.Enrage", ""], "finale": ["Cue.Fx.Buff.Finale", "Cue.Fx.Apply.Buff"],
	"fracture": ["Cue.Fx.Buff.Fracture", "Cue.Fx.Apply.Buff"], "malady": ["Cue.Fx.Buff.Malady", "Cue.Fx.Apply.Buff"],
	"combustion": ["Cue.Fx.Buff.Combustion", "Cue.Fx.Apply.Buff"],
	"attack_down": ["Cue.Fx.Debuff.AttackDown", "Cue.Fx.Apply.Debuff"], "defense_down": ["Cue.Fx.Debuff.DefenseDown", "Cue.Fx.Apply.Debuff"],
	"weaken": ["Cue.Fx.Debuff.Weaken", "Cue.Fx.Apply.Debuff"], "vulnerable": ["Cue.Fx.Debuff.Vulnerable", "Cue.Fx.Apply.Debuff"],
	"exhaustion": ["Cue.Fx.Debuff.Exhausted", ""], "exposed_fire": ["Cue.Fx.Debuff.Exposed", "Cue.Fx.Apply.Debuff"],
	"exposed_physical": ["Cue.Fx.Debuff.Exposed", "Cue.Fx.Apply.Debuff"], "seared": ["Cue.Fx.Debuff.Exposed", "Cue.Fx.Apply.Debuff"]}


func test_stat_statuses_and_cleanse_name_their_cues_and_the_cues_exist() -> void:
	if skip_in_export():
		return
	var registry := load("res://godot_gas/cue_registry.tres") as GameplayCueRegistry
	var registered := {}
	for entry in registry.entries:
		registered[entry.tag] = entry
	for file in STAT_CUES:
		var status := load("res://content/demo/effects/%s.tres" % file) as GameplayEffect
		var wanted: Array = STAT_CUES[file]
		eq(status.persistent_cue_tags, [StringName(wanted[0])], "%s wears its look while it lasts" % file)
		eq(status.application_cue_tags, [StringName(wanted[1])] if wanted[1] != "" else [], "%s pulses when it lands as intended" % file)
	for file in ["cleanse", "dispel"]:
		eq((load("res://content/demo/effects/%s.tres" % file) as GameplayEffect).application_cue_tags, [&"Cue.Fx.Cleanse"], "%s sparkles" % file)
	var tags := {}
	for file in STAT_CUES:
		tags[STAT_CUES[file][0]] = true
		if STAT_CUES[file][1] != "":
			tags[STAT_CUES[file][1]] = true
	tags["Cue.Fx.Cleanse"] = true
	for tag in tags:
		check(registered.has(StringName(tag)), "%s is in the cue registry" % tag)
		var scene := load(registered[StringName(tag)].scene_ref) as PackedScene
		var cue := scene.instantiate() as FxCueNotify
		check(cue != null and cue.fx != null, "%s plays an effect" % tag)
		if cue != null:
			var persistent: bool = String(tag).begins_with("Cue.Fx.Buff.") or String(tag).begins_with("Cue.Fx.Debuff.")
			check(cue.auto_destroy != persistent, "%s: a look persists, a pulse is a one-shot" % tag)
			if persistent:
				check(cue.fx.is_looping(), "%s: a persistent look is a looping effect" % tag)
			cue.free()


func test_buff_and_debuff_cues_differ_by_parameters_not_by_effect() -> void:
	if skip_in_export():
		return
	var up := (load("res://presentation/demo/cues/cue_buff_attack_up.tscn") as PackedScene).instantiate() as FxCueNotify
	var down := (load("res://presentation/demo/cues/cue_debuff_attack_down.tscn") as PackedScene).instantiate() as FxCueNotify
	eq(up.fx, down.fx, "buff and debuff arrows are one effect")
	var drift := {}
	for binding in down.bindings:
		drift[binding.param] = binding.value
	eq(drift[&"drift"], Vector3(0, -1.1, 0), "the debuff sinks")
	eq(drift[&"angle"], 180.0, "and turns the chevrons over")
	up.free()
	down.free()


func test_the_caster_ring_is_coloured_by_the_abilitys_role() -> void:
	if skip_in_export():
		return
	var service := _service()
	var view := _view(Vector3(0.8, 0.8, 0.8))
	service.unit_resolver = func(_unit_id: StringName) -> Node3D: return view
	var owner_node := _owner()
	for rules in (load("res://presentation/demo/fx/fx_registry.tres") as FxRegistry).all_rule_sets():
		rules.attach(owner_node)
	GameplayMessages.broadcast(&"Message.Battle.AbilityUsed", VerbMessage.make(&"Verb.Use", &"P1", &"P2", 0, [&"Ability.Role.Buff"]))
	eq(service.live_count(&"fx.cast_ring"), 1, "a buff cast draws a ring under the caster")
	var colour: Color = service.live()[service.live().size() - 1].params[&"color"]
	check(colour.r > 0.9 and colour.g > 0.7 and colour.b < 0.5, "gold for a buff (%s)" % colour)
	GameplayMessages.broadcast(&"Message.Battle.AbilityUsed", VerbMessage.make(&"Verb.Use", &"P1", &"P2", 0, [&"Ability.Role.Damage"]))
	eq(service.live_count(&"fx.cast_ring"), 1, "a damage cast draws no ring: its hits speak for it")


## Lyra's way: the damage message becomes a GameplayCue (its parameters are the message), and the cue notify plays the hit effect.
func test_hit_messages_execute_the_per_type_hit_cues() -> void:
	if skip_in_export():
		return
	var service := _service()
	var view := _view(Vector3(0.8, 0.8, 0.8))
	service.unit_resolver = func(_unit_id: StringName) -> Node3D: return view
	var was_suppressed: bool = GameplayCueManager.suppress_cues
	GameplayCueManager.suppress_cues = false
	var owner_node := _owner()
	for rules in (load("res://presentation/demo/fx/fx_registry.tres") as FxRegistry).all_rule_sets():
		rules.attach(owner_node)
	GameplayMessages.broadcast(&"Message.Battle.Damage", VerbMessage.make(&"Verb.Damage", &"P1", &"E1", 8700, [&"Damage.Type.Physical"]))
	eq(service.live_count(&"fx.slash_hit"), 1, "a physical hit executes the slash cue")
	GameplayMessages.broadcast(&"Message.Battle.Damage", VerbMessage.make(&"Verb.Damage", &"P1", &"E1", 8700, [&"Damage.Type.Fire"]))
	eq(service.live_count(&"fx.fire_hit"), 1, "a fire hit executes the fire cue")
	eq(service.live_count(&"fx.slash_hit"), 1, "and not the slash")
	GameplayMessages.broadcast(&"Message.Battle.Damage", VerbMessage.make(&"Verb.Damage", &"P1", &"E1", 8700, [&"Damage.Type.Ice"]))
	eq(service.live_count(&"fx.ice_hit"), 1, "an ice hit executes the ice cue")
	GameplayMessages.broadcast(&"Message.Battle.AbilityUsed",
		VerbMessage.make(&"Verb.Use", &"P1", &"P2", 0, [&"Ability.Type.Ultimate", &"Ability.Role.Buff"]))
	eq(service.live_count(&"fx.cast_ring"), 0, "an ultimate has its own cast cue, not the role ring")
	GameplayCueManager.suppress_cues = was_suppressed


func test_message_cue_params_carry_the_message() -> void:
	var params := MessageCueParams.from_message(VerbMessage.make(&"Verb.Damage", &"P1", &"E1", 4500, [&"Damage.Type.Fire", &"Hit.Critical"]))
	eq(params["verb"], &"Verb.Damage", "the verb")
	eq(params["instigator"], &"P1", "who")
	eq(params["target"], &"E1", "to whom")
	eq(params["magnitude"], 4500, "how much (x100)")
	eq(params["tags"], [&"Damage.Type.Fire", &"Hit.Critical"], "and the tags, crit and weakness included (the message is made after the effect has run)")
	eq(MessageCueParams.from_message(GameplayMessage.new()), {}, "a message that is no verb message has no parameters")


func test_heals_and_revives_are_cues_on_their_effects() -> void:
	if skip_in_export():
		return
	var heals := ["heal", "heal_2", "holy_heal", "medic_heal", "potion_heal", "stew_heal", "hourglass_heal", "heartstring_heal", "encore_heal",
		"glass_heart_heal", "vampire_heal", "corrupted_vampire_heal", "mirror_heal", "mimic_mend", "sanctuary_heal", "food_heal_15", "food_heal_25", "food_heal_30"]
	for file in heals:
		eq((load("res://content/demo/effects/%s.tres" % file) as GameplayEffect).application_cue_tags, [&"Cue.Fx.Heal"], "%s glows" % file)
	for file in ["revive", "resurrection_revive", "salts_revive", "second_heart_revive"]:
		eq((load("res://content/demo/effects/%s.tres" % file) as GameplayEffect).application_cue_tags, [&"Cue.Fx.Revive"], "%s rises" % file)
	eq((load("res://content/demo/effects/regen.tres") as GameplayEffect).periodic_cue_tags, [&"Cue.Fx.Heal"], "regen glows on every tick")
	for tag in [&"Cue.Fx.Heal", &"Cue.Fx.Revive", &"Cue.Fx.Hit.Fire", &"Cue.Fx.Hit.Ice", &"Cue.Fx.Hit.Physical"]:
		check(GameplayCueManager.has_cue(tag), "%s is in the cue registry" % tag)


# --- Ultimates (spec vfx-content-pass, group 4) -----------------------------------------------------------------------------

func test_every_ultimate_has_its_own_cast_cue() -> void:
	if skip_in_export():
		return
	var registry := load("res://godot_gas/cue_registry.tres") as GameplayCueRegistry
	var registered := {}
	for entry in registry.entries:
		registered[entry.tag] = entry
	var seen := {}
	var signatures := {}
	var ultimates := 0
	for file in DirAccess.get_files_at("res://content/demo/abilities/"):
		if not file.ends_with(".tscn"):
			continue
		var ability := (load("res://content/demo/abilities/" + file) as PackedScene).instantiate() as BattleAbility
		if ability == null:
			continue
		if ability.is_ultimate():
			ultimates += 1
			check(ability.cast_cue_tags.size() == 1 and String(ability.cast_cue_tags[0]).begins_with("Cue.Fx.Ult."), "%s names its own ultimate cue" % file)
			for tag in ability.cast_cue_tags:
				check(registered.has(tag), "%s is in the cue registry" % tag)
				check(not seen.has(tag), "%s is used by one ultimate only" % tag)
				seen[tag] = true
				var cue := (load(registered[tag].scene_ref) as PackedScene).instantiate() as FxCueNotify
				check(cue != null and cue.fx != null and cue.fx.id == &"fx.ult_flourish", "%s plays the ultimate flourish" % tag)
				if cue != null:
					check(cue.target_fx != null and cue.target_fx.id != &"fx.ult_flourish", "%s also plays its own signature effect on each target" % tag)
					if cue.target_fx != null:
						check(not signatures.has(cue.target_fx.id), "%s: no two ultimates share a signature effect (%s)" % [tag, cue.target_fx.id])
						signatures[cue.target_fx.id] = true
				cue.free()
		else:
			check(ability.cast_cue_tags.is_empty() or not String(ability.cast_cue_tags[0]).begins_with("Cue.Fx.Ult."), "%s is no ultimate" % file)
		ability.free()
	check(ultimates >= 24, "all the demo's ultimates were checked (%d)" % ultimates)


func test_a_quad_layer_disappears_when_its_time_is_up() -> void:
	var service := _service()
	var view := _view(Vector3(0.8, 0.8, 0.8))
	var quad := FxShaderQuadLayer.new()
	quad.id = &"streak"
	quad.space = FxLayer.Space.WORLD_3D
	quad.shader = load("res://game/fx/shaders/glow_3d.gdshader")
	quad.duration = 0.2
	quad.shader_params = {"fade_out": 0.0}  # a shader that never fades itself out
	var hold := _particles_layer_lasting(1.0)
	var definition := FxDefinition.new()
	definition.id = &"fx.test_quad_end"
	definition.space = FxDefinition.Space.WORLD_3D
	definition.layers.assign([quad, hold])
	var handle := service.play(definition, FxAnchor.node3d(view))
	var node := handle.instance.nodes[0] as Node3D
	check(node.visible, "the quad shows while it runs")
	service.advance(0.4)
	check(handle.is_playing() and not node.visible, "it is gone once its own time is up, though a longer layer keeps the effect alive")


func _particles_layer_lasting(seconds: float) -> FxParticles3DLayer:
	var layer := FxParticles3DLayer.new()
	layer.id = &"hold"
	layer.lifetime = seconds
	layer.amount = 2
	return layer


func test_an_ability_passes_its_targets_to_its_cast_cue() -> void:
	if skip_in_export():
		return
	var service := _service()
	var view := _view(Vector3(0.8, 0.8, 0.8))
	service.unit_resolver = func(_unit_id: StringName) -> Node3D: return view
	var tag := &"Cue.Test.TargetFlourish"
	var cue := FxCueNotify.new()
	cue.target_fx = _socket_effect(FxSocket.CENTER)
	var scene := PackedScene.new()
	scene.pack(cue)
	cue.free()
	var was_suppressed: bool = GameplayCueManager.suppress_cues
	GameplayCueManager.suppress_cues = false
	GameplayCueManager.register_cue(tag, scene)
	var snapshots := preload("res://tests/combat/test_item_pass_combat.gd")
	var battle := new_battle(snapshots.break_snapshot())
	var duelist := battle.unit_by_id(&"P1")
	var ability := duelist.ability_by_tag(&"Fixture.Ability.FireSlash")
	ability.cast_cue_tags = [tag]
	await battle._activate(duelist, ability, battle.unit_by_id(&"E1"))
	eq(service.live_count(&"fx.test_socket"), 1, "the cue played its effect on the one unit the ability reaches (the payload's target_ids)")
	GameplayCueManager.unregister_cue(tag)
	GameplayCueManager.suppress_cues = was_suppressed


func test_a_cue_plays_its_target_effect_once_per_target_and_the_caster_effect_once() -> void:
	var service := _service()
	var views := {&"P2": _view(Vector3.ONE), &"P3": _view(Vector3.ONE)}
	service.unit_resolver = func(unit_id: StringName) -> Node3D: return views.get(unit_id)
	var caster := _view(Vector3.ONE)
	var cue := FxCueNotify.new()
	var caster_effect := _socket_effect(FxSocket.CENTER)
	caster_effect.id = &"fx.test_caster"
	cue.fx = caster_effect
	cue.target_fx = _socket_effect(FxSocket.CENTER)
	cue.auto_destroy = false
	host.add_child(cue)
	_nodes.append(cue)
	cue.execute_cue(caster, {"target_ids": [&"P2", &"P3"]})
	eq(service.live_count(&"fx.test_caster"), 1, "the caster's effect plays once, on the cue's own target")
	eq(service.live_count(&"fx.test_socket"), 2, "the target effect plays on each unit in target_ids")
	var empty := FxCueNotify.new()
	empty.target_fx = _socket_effect(FxSocket.CENTER)
	host.add_child(empty)
	_nodes.append(empty)
	empty.execute_cue(caster, {})
	eq(service.live_count(&"fx.test_socket"), 2, "a cue with no target_ids plays no target effect")


func test_a_mesh_layer_shows_a_mesh_with_its_own_material_and_goes_away() -> void:
	var service := _service()
	var view := _view(Vector3(0.8, 0.8, 0.8))
	var layer := FxMeshLayer.new()
	layer.id = &"rock"
	layer.mesh = SphereMesh.new()
	var material := ShaderMaterial.new()
	material.shader = load("res://game/fx/shaders/material/lava_rock.gdshader")
	layer.material = material
	layer.seconds = 0.3
	layer.bindings = [_bind("material_override:shader_parameter/color", &"color")]
	var hold := _particles_layer_lasting(1.0)
	var definition := FxDefinition.new()
	definition.id = &"fx.test_mesh"
	definition.space = FxDefinition.Space.WORLD_3D
	definition.layers.assign([layer, hold])
	definition.params.assign([_param(&"color", FxParam.Kind.COLOR, Color.WHITE)])
	var first := service.play(definition, FxAnchor.node3d(view), {"color": Color.RED})
	var second := service.play(definition, FxAnchor.node3d(view), {"color": Color.BLUE})
	var a := first.instance.nodes[0] as MeshInstance3D
	var b := second.instance.nodes[0] as MeshInstance3D
	check(a.mesh is SphereMesh and a.visible, "the layer shows its mesh")
	eq((a.material_override as ShaderMaterial).get_shader_parameter("color"), Color.RED, "with the bound parameter")
	eq((b.material_override as ShaderMaterial).get_shader_parameter("color"), Color.BLUE, "each play has its own copy of the material")
	service.advance(0.5)
	check(not a.visible, "the mesh is gone once its time is up")
	var empty := FxMeshLayer.new()
	empty.id = &"none"
	check(empty.extra_problems(definition, null).size() == 1, "a mesh layer with no mesh is reported to the validator")


# --- Battle moments (spec vfx-content-pass, the last group) -----------------------------------------------------------------------

func _moments_setup() -> Dictionary:
	var service := _service()
	var view := _view(Vector3(0.8, 0.8, 0.8))
	service.unit_resolver = func(_unit_id: StringName) -> Node3D: return view
	var was_suppressed: bool = GameplayCueManager.suppress_cues
	GameplayCueManager.suppress_cues = false
	return {"service": service, "view": view, "was_suppressed": was_suppressed}


func test_tag_cues_follow_a_units_state_tags() -> void:
	if skip_in_export():
		return
	var setup := _moments_setup()
	var service: FxService = setup["service"]
	var asc := AbilitySystemComponent.new()
	(setup["view"] as Node3D).add_child(asc)
	var binder := FxTagCues.new()
	binder.attach_unit(asc, &"P1", (load("res://presentation/demo/fx/fx_registry.tres") as FxRegistry).all_tag_cues())
	asc.add_tag(&"State.Broken")
	eq(service.live_count(&"fx.break_shatter"), 1, "becoming Broken shatters once")
	eq(service.live_count(&"fx.broken_state"), 1, "and starts the look that lasts while it is Broken")
	service.advance(5.0)
	eq(service.live_count(&"fx.broken_state"), 1, "which stays as long as the tag does")
	asc.clear_tag(&"State.Broken")
	eq(service.live_count(&"fx.recover_flash"), 1, "recovering from Broken plays the recovery")
	service.advance(5.0)
	eq(service.live_count(&"fx.broken_state"), 0, "and the look is gone")
	asc.add_tag(&"State.Downed")
	eq(service.live_count(&"fx.status_skin"), 1, "a Downed unit wears its look")
	asc.clear_tag(&"State.Downed")
	asc.add_tag(&"State.Dead")
	eq(service.live_count(&"fx.death_fade"), 1, "a unit that dies fades")
	GameplayCueManager.suppress_cues = setup["was_suppressed"]


func test_moment_messages_become_cues_and_run_events_flash() -> void:
	if skip_in_export():
		return
	var setup := _moments_setup()
	var service: FxService = setup["service"]
	var owner_node := _owner()
	for rules in (load("res://presentation/demo/fx/fx_registry.tres") as FxRegistry).all_rule_sets():
		rules.attach(owner_node)
	GameplayMessages.broadcast(&"Message.Battle.Phase", VerbMessage.make(&"Verb.Phase", &"E1", &"E1", 2))
	eq(service.live_count(&"fx.phase_shift"), 1, "a boss entering a phase shakes the field")
	GameplayMessages.broadcast(&"Message.Battle.OneMore", VerbMessage.make(&"Verb.OneMore", &"P1", &"P1"))
	eq(service.live_count(&"fx.one_more"), 1, "One More shows its callout")
	# Lyra's way (the user, 2026-11-09): a crit, a weakness and a break accent every such hit, not only a passive that triggers on it.
	GameplayMessages.broadcast(&"Message.Battle.Damage", VerbMessage.make(&"Verb.Damage", &"P1", &"E1", 1200, [&"Hit.Critical", &"Damage.Type.Physical"]))
	eq(service.live_count(&"fx.proc_pulse"), 1, "a critical hit pulses")
	var colour: Color = service.live()[service.live().size() - 1].params[&"color"]
	check(colour.r > 0.9 and colour.g > 0.7 and colour.b < 0.5, "gold for a crit (%s)" % colour)
	GameplayMessages.broadcast(&"Message.Battle.Trigger", VerbMessage.make(&"Verb.Use", &"P1", &"P1", 0, [&"Ability.Passive.Test", &"Event.Damage.Dealt.Ice"]))
	eq(service.live_count(&"fx.proc_pulse"), 2, "a passive that triggers on an ice hit pulses, in its own colour")
	GameplayMessages.broadcast(&"Message.Battle.Trigger", VerbMessage.make(&"Verb.Use", &"P1", &"P1", 0, [&"Ability.Passive.Test", &"Event.Battle.Start"]))
	eq(service.live_count(&"fx.proc_pulse"), 2, "the battle-start passives (a dozen at once) stay quiet")
	GameplayMessages.broadcast(&"Message.Battle.Resisted", VerbMessage.make(&"Verb.Resist", &"E1", &"P1"))
	var resist: FxHandle = service.live()[service.live().size() - 1]
	eq(resist.params[&"text"], "RESIST", "a resisted status says so")
	GameplayMessages.broadcast(&"Message.Run.LevelUp", VerbMessage.make(&"Verb.LevelUp", &"", &"slot:1", 2))
	eq(service.live_count(&"fx.screen_flash"), 1, "a level-up flashes the screen (the phase shift's own flash starts a beat later)")
	GameplayCueManager.suppress_cues = setup["was_suppressed"]


## Lyra's number pops (the user, 2026-11-09): the number is a cue whose styles decide its look by the hit's tags, the first
## matching style per parameter (a crit's outline and label, the element's colour); a heal is green with a "+", a burn tick orange.
func test_the_number_cue_styles_each_number_by_its_tags() -> void:
	if skip_in_export():
		return
	var setup := _moments_setup()
	var service: FxService = setup["service"]
	var owner_node := _owner()
	for rules in (load("res://presentation/demo/fx/fx_registry.tres") as FxRegistry).all_rule_sets():
		rules.attach(owner_node)
	GameplayMessages.broadcast(&"Message.Battle.Damage", VerbMessage.make(&"Verb.Damage", &"P1", &"E1", 4285, [&"Hit.Critical", &"Hit.Weakness", &"Damage.Type.Fire"]))
	var crit: Dictionary = _last(service, &"fx.damage_number").params
	eq(crit[&"text"], "42", "the number is the damage, x100 divided")
	eq(crit[&"label"], "Crit!", "the crit style comes first and names it")
	eq(crit[&"outline_size"], 15, "with its outline")
	eq(crit[&"color"], Color(1, 0.45, 0.16, 1), "while the element still gives the colour")
	GameplayMessages.broadcast(&"Message.Battle.HpChanged", VerbMessage.make(&"Verb.Heal", &"", &"P1", 1500, [&"Status.Buff.Regen"]))
	var heal: Dictionary = _last(service, &"fx.damage_number").params
	eq([heal[&"text"], heal[&"color"]], ["+15", Color(0.45, 1, 0.55, 1)], "a heal is green with a plus")
	GameplayMessages.broadcast(&"Message.Battle.HpChanged", VerbMessage.make(&"Verb.Damage", &"", &"P1", 700, [&"Status.Debuff.Burn"]))
	var burn: Dictionary = _last(service, &"fx.damage_number").params
	eq([burn[&"text"], burn[&"color"]], ["7", Color(1, 0.45, 0.16, 1)], "a burn tick is orange, with no plus")
	GameplayCueManager.suppress_cues = setup["was_suppressed"]


func _last(service: FxService, id: StringName) -> FxHandle:
	var found: FxHandle = null
	for handle in service.live():
		if handle.definition.id == id:
			found = handle
	return found


func test_every_moment_cue_is_registered_and_plays_an_effect() -> void:
	if skip_in_export():
		return
	for tag in [&"Cue.Fx.Death", &"Cue.Fx.State.Broken", &"Cue.Fx.Recovered", &"Cue.Fx.State.Downed", &"Cue.Fx.PhaseShift", &"Cue.Fx.OneMore",
			&"Cue.Fx.Proc.Crit", &"Cue.Fx.Proc.Weakness", &"Cue.Fx.Proc.Fire", &"Cue.Fx.Proc.Ice", &"Cue.Fx.Proc.Break", &"Cue.Fx.Proc.Physical",
			&"Cue.Fx.Proc.Taken", &"Cue.Fx.Proc.Kill", &"Cue.Fx.Proc.Ult", &"Cue.Fx.Drain.Fire", &"Cue.Fx.Drain.Ice", &"Cue.Fx.Drain.Physical"]:
		check(GameplayCueManager.has_cue(tag), "%s is in the cue registry" % tag)
		var cue := (GameplayCueManager._scene_for(tag) as PackedScene).instantiate() as FxCueNotify
		check(cue != null and cue.fx != null, "%s plays an effect" % tag)
		if cue != null:
			cue.free()


## A drained hit (the target heals instead of taking damage) shows the element it absorbed, by damage type.
func test_a_drained_hit_shows_what_was_absorbed() -> void:
	if skip_in_export():
		return
	var setup := _moments_setup()
	var service: FxService = setup["service"]
	var owner_node := _owner()
	for rules in (load("res://presentation/demo/fx/fx_registry.tres") as FxRegistry).all_rule_sets():
		rules.attach(owner_node)
	GameplayMessages.broadcast(&"Message.Battle.Drained", VerbMessage.make(&"Verb.Drain", &"E1", &"P1", 4285, [&"Hit.Drained", &"Damage.Type.Fire"]))
	eq(service.live_count(&"fx.drain_absorb"), 1, "a drained fire hit plays the absorb effect")
	var colour: Color = service.live()[service.live().size() - 1].params[&"color"]
	check(colour.r > 0.9 and colour.g < 0.6, "in fire's colour (%s)" % colour)
	GameplayMessages.broadcast(&"Message.Battle.Drained", VerbMessage.make(&"Verb.Drain", &"E1", &"P1", 100, [&"Hit.Drained", &"Damage.Type.Ice"]))
	eq(service.live_count(&"fx.drain_absorb"), 2, "an ice one too")
	GameplayMessages.broadcast(&"Message.Battle.Drained", VerbMessage.make(&"Verb.Drain", &"E1", &"P1", 100, [&"Hit.Drained"]))
	eq(service.live_count(&"fx.drain_absorb"), 2, "a drain with no known element plays nothing")
	GameplayCueManager.suppress_cues = setup["was_suppressed"]
	var feed := load("res://presentation/demo/ui/battle_feed.tres") as UIToastSet
	check(feed.rules.any(func(rule) -> bool: return rule.channel == &"Message.Battle.Drained"), "the battle feed has a line for an absorbed hit")


# --- Gaps closed after the spec sync (what the first test plan promised and no test pinned) -------------------------------------------

## The generic spark is gone for good: the damage effect is the hit sound, and every look comes from the hit's own cue.
func test_the_damage_effect_lists_only_the_hit_sound() -> void:
	if skip_in_export():
		return
	var damage := load("res://content/demo/effects/damage.tres") as GameplayEffect
	eq(damage.application_cue_tags, [&"Cue.Sfx.Hit"], "damage.tres plays the hit sound and nothing else (no Cue.Fx.HitSpark)")


## A looping look dies with the unit: death drops every temporary effect, and a persistent cue ends with its effect.
func test_a_persistent_look_ends_when_its_unit_dies() -> void:
	var setup := _moments_setup()
	var service: FxService = setup["service"]
	var tag := &"Cue.Test.LookUntilDeath"
	var cue := FxCueNotify.new()
	var looping := _socket_effect(FxSocket.CENTER)
	looping.id = &"fx.test_look"
	(looping.layers[0] as FxParticles3DLayer).loop = true
	cue.fx = looping
	cue.auto_destroy = false
	var scene := PackedScene.new()
	scene.pack(cue)
	cue.free()
	GameplayCueManager.register_cue(tag, scene)
	var snapshots := preload("res://tests/combat/test_item_pass_combat.gd")
	var battle := new_battle(snapshots.break_snapshot())
	var unit := battle.unit_by_id(&"E1")
	var status := GameplayEffect.new()
	status.policy = GameplayEffect.DurationPolicy.TURN_BASED
	status.duration_turns = 3
	status.persistent_cue_tags = [tag]
	status.granted_tags = [&"Status.Debuff.Poison"]
	unit.asc.apply_effect_spec(GameplayEffectSpec.new(status, GameplayEffectContext.new(unit, unit), 1))
	eq(service.live_count(&"fx.test_look"), 1, "the status shows its look")
	service.advance(5.0)
	eq(service.live_count(&"fx.test_look"), 1, "which lasts")
	battle._lay_down(unit)  # death: every temporary effect is dropped
	service.advance(5.0)
	eq(service.live_count(&"fx.test_look"), 0, "and ends with the unit")
	GameplayCueManager.unregister_cue(tag)
	GameplayCueManager.suppress_cues = setup["was_suppressed"]


## Review fix: a tag a unit already has when the watcher attaches (a member carried over Broken or dead) starts its lasting look,
## without replaying the moment it was added; detach() ends the look and stops listening.
func test_tag_cues_start_looks_for_tags_already_there_and_detach_ends_them() -> void:
	if skip_in_export():
		return
	var setup := _moments_setup()
	var service: FxService = setup["service"]
	var asc := AbilitySystemComponent.new()
	(setup["view"] as Node3D).add_child(asc)
	asc.add_tag(&"State.Broken")   # before anyone watches
	var binder := FxTagCues.new()
	binder.attach_unit(asc, &"P1", (load("res://presentation/demo/fx/fx_registry.tres") as FxRegistry).all_tag_cues())
	eq(service.live_count(&"fx.broken_state"), 1, "the lasting Broken look starts at attach")
	eq(service.live_count(&"fx.break_shatter"), 0, "but the break moment, long past, does not replay")
	binder.detach()
	service.advance(5.0)
	eq(service.live_count(&"fx.broken_state"), 0, "detach ends the look")
	asc.clear_tag(&"State.Broken")
	eq(service.live_count(&"fx.recover_flash"), 0, "and nothing listens any more")
	GameplayCueManager.suppress_cues = setup["was_suppressed"]


## Review fix: GAS pauses a persistent cue whose effect is suppressed (set_cue_state); the look, which lives in the effects
## service, fades out while paused and comes back when the cue is enabled again.
func test_a_suppressed_persistent_cue_hides_its_look_until_enabled() -> void:
	var setup := _moments_setup()
	var service: FxService = setup["service"]
	var cue := FxCueNotify.new()
	var looping := _socket_effect(FxSocket.CENTER)
	looping.id = &"fx.test_suppressed_look"
	(looping.layers[0] as FxParticles3DLayer).loop = true
	cue.fx = looping
	cue.stop_fade = 0.0
	var scene := PackedScene.new()
	scene.pack(cue)
	cue.free()
	var tag := &"Cue.Test.Suppressed"
	GameplayCueManager.register_cue(tag, scene)
	var live := GameplayCueManager.add_persistent_cue(tag, setup["view"])
	eq(service.live_count(&"fx.test_suppressed_look"), 1, "the look plays")
	GameplayCueManager.set_cue_state(live, false)
	service.advance(5.0)   # the last particles fade out
	eq(service.live_count(&"fx.test_suppressed_look"), 0, "suppressed: the look is gone")
	GameplayCueManager.set_cue_state(live, true)
	eq(service.live_count(&"fx.test_suppressed_look"), 1, "enabled again: it is back")
	live.end_cue()
	GameplayCueManager.unregister_cue(tag)
	GameplayCueManager.suppress_cues = setup["was_suppressed"]


## Review fix: a persistent cue whose look is a one-shot plays once; a tier change does not play it (or its targets' looks) again.
func test_a_one_shot_persistent_cue_does_not_replay_on_a_tier_change() -> void:
	var setup := _moments_setup()
	var service: FxService = setup["service"]
	var cue := FxCueNotify.new()
	var once := _socket_effect(FxSocket.CENTER)
	once.id = &"fx.test_once_look"
	cue.fx = once
	var scene := PackedScene.new()
	scene.pack(cue)
	cue.free()
	var tag := &"Cue.Test.OnceLook"
	GameplayCueManager.register_cue(tag, scene)
	var live := GameplayCueManager.add_persistent_cue(tag, setup["view"])
	eq(service.stats()["plays"], 1, "played once")
	service.advance(10.0)   # the one-shot is over
	service.quality = FxQuality.LOW
	service.quality = FxQuality.HIGH
	eq(service.stats()["plays"], 1, "a tier change does not play it again")
	live.end_cue()
	GameplayCueManager.unregister_cue(tag)
	GameplayCueManager.suppress_cues = setup["was_suppressed"]


## Review fix: TARGET_TAGS reads the payload's ability system when the cue's target (a unit view) has none (tag cues pass it).
func test_a_target_tags_binding_reads_the_payloads_ability_system() -> void:
	var asc := AbilitySystemComponent.new()
	host.add_child(asc)
	asc.add_tag(&"Status.Debuff.Burn")
	var binding := FxCueBinding.new()
	binding.param = &"color"
	binding.source = FxCueBinding.Source.TARGET_TAGS
	binding.tag_values = {"Status.Debuff.Burn": Color.ORANGE}
	var view := Node3D.new()
	host.add_child(view)
	eq(binding.resolve(view, {"asc": asc}), Color.ORANGE, "the payload's ability system answers")
	eq(binding.resolve(view, {}), null, "no ability system anywhere: the default")
	view.free()
	asc.free()


## The battle scene is torn down (the battle ends, a new floor loads): looks on its unit views go with them, with no leak and no error.
func test_looks_are_released_when_their_views_are_freed() -> void:
	var service := _service()
	var view := Node3D.new()
	host.add_child(view)
	var looping := _socket_effect(FxSocket.CENTER)
	looping.id = &"fx.test_view_look"
	(looping.layers[0] as FxParticles3DLayer).loop = true
	var handle := service.play(looping, FxAnchor.node3d(view))
	check(handle.is_playing(), "the look plays")
	view.free()
	service.advance(0.2)
	eq(service.live_count(&"fx.test_view_look"), 0, "freeing the unit's view releases the look")


## The proof that effects are presentation only: a whole battle played with every rule set, tag cue and message bridge attached and the cues
## really running ends with the same log and the same final hash as the same battle played bare.
func test_a_battle_with_every_effect_attached_is_identical() -> void:
	if skip_in_export():
		return
	var snap := squad_snapshot("42")
	var bare := new_battle(snap)
	var bare_controller := ScriptedController.new()
	await bare.run(bare_controller)
	var setup := _moments_setup()
	var service: FxService = setup["service"]
	var dressed := new_battle(snap)
	var bridge := BattleMessages.new()
	bridge.attach(dressed, &"fixture.encounter.squad", GameplayMessages)
	var registry := load("res://presentation/demo/fx/fx_registry.tres") as FxRegistry
	var owner_node := _owner()
	for rules in registry.all_rule_sets():
		rules.attach(owner_node)
	var tag_cues := FxTagCues.new()
	tag_cues.attach(dressed, registry.all_tag_cues())
	var dressed_controller := ScriptedController.new()
	await dressed.run(dressed_controller)
	check(not bare_controller.entries.is_empty(), "the battle was played")
	eq(dressed_controller.entries, bare_controller.entries, "the same log")
	eq(dressed.final_hash, bare.final_hash, "the same final hash")
	eq(dressed.outcome, bare.outcome, "the same outcome")
	check(service.stats()["plays"] > 0, "and the effects really played (%s plays)" % service.stats()["plays"])
	GameplayCueManager.suppress_cues = setup["was_suppressed"]


## Review fix (the test gap of the proof above: the fixtures list no cue tags). The window client runs GAS cues the verifier suppresses:
## cue nodes are added under the BattleUnits, a cast cue fires on every activation, and persistent and periodic cues run with the
## statuses. Here every ability casts a test cue and every effect the abilities apply lists it as an application, persistent and periodic
## cue; the battle played with cues suppressed (the verifier) and with them running (the client) must keep the same log and final hash.
func test_gas_cues_on_battle_units_change_no_log_and_no_hash() -> void:
	if skip_in_export():
		return
	var setup := _moments_setup()
	var service: FxService = setup["service"]
	var tag := &"Cue.Test.EveryCast"
	var cue := FxCueNotify.new()
	cue.fx = _socket_effect(FxSocket.CENTER)
	cue.target_fx = _socket_effect(FxSocket.CENTER)
	var scene := PackedScene.new()
	scene.pack(cue)
	cue.free()
	GameplayCueManager.register_cue(tag, scene)
	var snap := squad_snapshot("42")
	var saved := {}  # GameplayEffect -> [application, persistent, periodic]: the fixture resources are shared, so they are put back
	var played: Array[Battle] = []
	var logs: Array = []
	for suppressed in [true, false]:
		GameplayCueManager.suppress_cues = suppressed
		var battle := new_battle(snap)
		for unit in battle.units():
			for ability in unit.abilities():
				ability.cast_cue_tags = [tag]
				for row in ability.executions:
					if row != null and row.effect != null and not saved.has(row.effect):
						saved[row.effect] = [row.effect.application_cue_tags.duplicate(), row.effect.persistent_cue_tags.duplicate(),
							row.effect.periodic_cue_tags.duplicate()]
						row.effect.application_cue_tags.append(tag)
						row.effect.persistent_cue_tags.append(tag)
						row.effect.periodic_cue_tags.append(tag)
		var controller := ScriptedController.new()
		await battle.run(controller)
		played.append(battle)
		logs.append(controller.entries)
	var cued_plays: int = service.stats()["plays"]
	for effect in saved:
		effect.application_cue_tags = saved[effect][0]
		effect.persistent_cue_tags = saved[effect][1]
		effect.periodic_cue_tags = saved[effect][2]
	GameplayCueManager.unregister_cue(tag)
	GameplayCueManager.suppress_cues = setup["was_suppressed"]
	check(not saved.is_empty(), "the abilities apply effects that now carry the cue")
	check(not (logs[0] as Array).is_empty(), "the battle was played")
	eq(logs[1], logs[0], "the same log with cues running as with cues suppressed")
	eq(played[1].final_hash, played[0].final_hash, "the same final hash")
	eq(played[1].outcome, played[0].outcome, "the same outcome")
	check(cued_plays > 0, "and the cues really played on the battle units (%d plays)" % cued_plays)


## The registries are edited by hand, so a forgotten line must fail loudly (user, 2026-11-09).
func test_registries_list_every_effect_rule_set_and_cue_scene() -> void:
	if skip_in_export():
		return
	var registry := load("res://presentation/demo/fx/fx_registry.tres") as FxRegistry
	var cues := load("res://godot_gas/cue_registry.tres") as GameplayCueRegistry
	var problems := FxValidator.sync_problems("res://presentation/demo/fx/", "res://presentation/demo/cues/", registry, cues)
	eq(problems.size(), 0, "the shipped registries are in sync: %s" % [problems.map(func(i): return i.message)])
	# A registry that lacks a file is caught.
	var empty := FxRegistry.new()
	var lagging := FxValidator.sync_problems("res://presentation/demo/fx/", "res://presentation/demo/cues/", empty, GameplayCueRegistry.new())
	var codes := lagging.map(func(i): return i.code)
	check(codes.has("fx_unregistered"), "an effect missing from the registry is reported")
	check(codes.has("fx_rule_set_unregistered"), "a rule set missing from the registry is reported")
	check(codes.has("cue_scene_unregistered"), "a cue scene without an entry is reported")
	# Review fix: the inspector and the dashboard save an entry's scene as a uid:// (GodotGAS patch 3); such an entry still counts.
	# The shipped cue scenes carry no uid yet (the builders saved them without one), so one is registered for the first scene here.
	var by_uid := GameplayCueRegistry.new()
	var uid := ResourceUID.create_id()
	ResourceUID.add_id(uid, cues.entries[0].scene_path())
	for entry in cues.entries:
		var copy := GameplayCueEntry.new()
		copy.tag = entry.tag
		copy.scene_ref = entry.scene_ref
		by_uid.entries.append(copy)
	by_uid.entries[0].scene_ref = ResourceUID.id_to_text(uid)
	var uid_problems := FxValidator.sync_problems("res://presentation/demo/fx/", "res://presentation/demo/cues/", registry, by_uid)
	eq(uid_problems.map(func(i): return i.message), [], "a registry that names its scenes by uid is in sync too")
	var gone := GameplayCueEntry.new()
	gone.tag = &"Cue.Test.Gone"
	gone.scene_ref = "uid://doesnotexist00"
	by_uid.entries.append(gone)
	var gone_codes := FxValidator.sync_problems("res://presentation/demo/fx/", "res://presentation/demo/cues/", registry, by_uid).map(func(i): return i.code)
	check(gone_codes.has("cue_scene_missing"), "a uid that resolves to nothing is a missing scene")
	ResourceUID.remove_id(uid)


## A builder's registry write is additive text: new entries appended, every existing line byte for byte, nothing listed twice.
func test_the_registry_patch_only_appends() -> void:
	if skip_in_export():
		return
	var dir := "user://registry_patch_test/"
	DirAccess.make_dir_recursive_absolute(dir)
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + file)
	var old_effect := FxDefinition.new()
	old_effect.id = &"fx.test.old"
	ResourceSaver.save(old_effect, dir + "old.tres")
	var registry := FxRegistry.new()
	registry.definitions = [load(dir + "old.tres")]
	ResourceSaver.save(registry, dir + "fx_registry.tres")
	var before := FileAccess.get_file_as_string(dir + "fx_registry.tres")
	var new_effect := FxDefinition.new()
	new_effect.id = &"fx.test.new"
	ResourceSaver.save(new_effect, dir + "new.tres")
	var new_rules := FxRuleSet.new()
	ResourceSaver.save(new_rules, dir + "new_rules.tres")
	var added := RegistryPatch.add_missing_effects(dir + "fx_registry.tres", dir)
	eq(added.size(), 2, "the new effect and the new rule set were added: %s" % [added])
	var after := FileAccess.get_file_as_string(dir + "fx_registry.tres")
	for line in before.split("\n"):
		if line.begins_with("[ext_resource") or line.begins_with("script =") or line.begins_with("[gd_resource"):
			check(after.contains(line), "an existing line is kept: " + line)
	var patched := ResourceLoader.load(dir + "fx_registry.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as FxRegistry
	check(patched.all().has(&"fx.test.old") and patched.all().has(&"fx.test.new"), "both effects are listed")
	eq(patched.all_rule_sets().size(), 1, "the rule set is listed")
	eq(RegistryPatch.add_missing_effects(dir + "fx_registry.tres", dir).size(), 0, "a second run adds nothing")
	# Review fix: subfolders are found, an effect with no id or with a listed effect's id is never added (and a second run
	# still adds nothing), and the sync check names both.
	DirAccess.make_dir_recursive_absolute(dir + "sub")
	var nested := FxDefinition.new()
	nested.id = &"fx.test.nested"
	ResourceSaver.save(nested, dir + "sub/nested.tres")
	var nameless := FxDefinition.new()
	ResourceSaver.save(nameless, dir + "nameless.tres")
	var copy := FxDefinition.new()
	copy.id = &"fx.test.old"
	ResourceSaver.save(copy, dir + "copy_of_old.tres")
	eq(RegistryPatch.add_missing_effects(dir + "fx_registry.tres", dir), PackedStringArray(["definitions += nested.tres"]),
		"only the effect in the subfolder is added")
	eq(RegistryPatch.add_missing_effects(dir + "fx_registry.tres", dir).size(), 0, "and a second run still adds nothing")
	var synced := ResourceLoader.load(dir + "fx_registry.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as FxRegistry
	check(synced.all().has(&"fx.test.nested"), "the nested effect is listed")
	var codes := FxValidator.sync_problems(dir, "res://presentation/demo/cues/", synced, GameplayCueRegistry.new()).map(func(i): return i.code)
	check(codes.has("fx_id_missing"), "an effect with no id is reported")
	check(codes.has("fx_id_taken"), "an effect with another effect's id is reported")
	check(not codes.has("fx_unregistered"), "nothing else is missing")
	DirAccess.remove_absolute(dir + "sub/nested.tres")
	DirAccess.remove_absolute(dir + "sub")
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + file)
