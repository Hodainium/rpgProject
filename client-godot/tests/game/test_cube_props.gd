## Spec cube-style 6a Set K: the pickups' looks. A registry's key, armor icons (by slot tag, a default, rarity colours) and chest looks
## resolve through the base chain field by field; a PropView builds a pickup (tint, outline, label, a Base socket on the floor, the
## effect coloured by the prop and following visibility) and a chest in its three states; the validator's prop codes. Built in code.
extends TestCase


func after_each() -> void:
	UnitStyle.reset()
	super()


func _shape(color := Color.WHITE, tintable := true) -> AttachmentShape:
	var part := AttachmentPart.new()
	part.kind = AttachmentPart.Kind.BOX
	part.color = color
	part.tintable = tintable
	var shape := AttachmentShape.new()
	shape.display_name = "test"
	shape.parts.append(part)
	return shape


func _prop_look(outline: float = 0.0) -> PropLook:
	var look := PropLook.new()
	look.shape = _shape()
	look.outline = outline
	return look


func _chest_look() -> ChestLook:
	var look := ChestLook.new()
	look.body = _shape(Color.BROWN)
	look.lid = _shape(Color.BROWN)
	look.filled_inside = _shape(Color.GOLD, false)
	look.empty_inside = _shape(Color.BLACK, false)
	look.filled_effect = _looping_effect()
	return look


func _looping_effect() -> FxDefinition:
	var effect := FxDefinition.new()
	effect.id = &"fx.test_prop"
	var colour := FxParam.new()
	colour.name = &"color"
	colour.kind = FxParam.Kind.COLOR
	effect.params.append(colour)
	var light := FxLightLayer.new()
	light.id = &"light"
	light.loop = true
	effect.layers.append(light)
	return effect


func _meshes(node: Node) -> Array[Node]:
	return node.find_children("*", "MeshInstance3D", true, false)


func test_prop_looks_resolve_through_the_base_chain_field_by_field() -> void:
	var main := StyleRegistry.new()
	main.props = PropStyle.new()
	var key := _prop_look()
	var helm := _prop_look()
	var bag := _prop_look()
	main.props.key = key
	main.props.armor_by_slot[&"Equipment.Slot.Head"] = helm
	main.props.rarity_colors[&"Item.Rarity.Rare"] = Color.BLUE
	main.props.chests[&"c.wood"] = _chest_look()
	var variant := StyleRegistry.new()
	variant.base = main
	variant.props = PropStyle.new()
	variant.props.armor_default = bag
	eq(variant.key_look(), key, "a variant without a key look uses its base's")
	eq(variant.armor_look(&"Equipment.Slot.Head"), helm, "a base's slot look wins over a variant's default (code review)")
	eq(variant.armor_look(&"Equipment.Slot.Legs"), bag, "a slot with no look anywhere takes the nearest default")
	eq(main.armor_look(&"Equipment.Slot.Legs"), null, "no look for the slot and no default: today's cube")
	eq(variant.rarity_color([&"Card.Set.Core", &"Item.Rarity.Rare"]), Color.BLUE, "the first mapped rarity tag, from the base")
	eq(variant.rarity_color([&"Item.Rarity.Mythic"], Color.RED), Color.RED, "an unmapped rarity takes the fallback")
	eq(variant.rarity_color([], null), null, "no rarity with a null fallback: null (the shape keeps its own colours)")
	var any_chest := _chest_look()
	variant.props.chest_default = any_chest
	check(variant.chest_look(&"c.wood") == main.props.chests[&"c.wood"], "a base's chest look wins over a variant's default")
	eq(variant.chest_look(&"c.other"), any_chest, "an unknown chest takes the default")
	eq(StyleRegistry.new().key_look(), null, "a registry without props has no prop looks")


func test_a_pickup_is_tinted_outlined_labelled_and_stands_on_the_floor() -> void:
	var look := _prop_look(0.02)
	look.shape.parts.append(_shape(Color.GREEN, false).parts[0])
	var view := PropView.pickup(look, "Helm (12)", Color.BLUE)
	var meshes := _meshes(view)
	eq(meshes.size(), 2, "one mesh per part")
	var tinted := (meshes[0] as MeshInstance3D).material_override as StandardMaterial3D
	var fixed := (meshes[1] as MeshInstance3D).material_override as StandardMaterial3D
	eq(tinted.albedo_color, Color.BLUE, "a tintable part takes the rarity colour")
	eq(fixed.albedo_color, Color.GREEN, "a fixed part keeps its own")
	var hull := tinted.next_pass as StandardMaterial3D
	check(hull != null and hull.grow and is_equal_approx(hull.grow_amount, 0.02) and hull.cull_mode == BaseMaterial3D.CULL_FRONT,
		"the outline is an inverted hull as the next pass")
	eq(hull.albedo_color, Color.BLUE, "in the prop's colour")
	eq((view.get_node(^"Label") as Label3D).text, "Helm (12)", "the label")
	var base := view.get_node(^"Base") as FxSocket
	check(base != null and base.role == FxSocket.BASE and base.position.y < 0.1, "the Base socket is on the floor, not under the shape")
	check(view.holder.position.y > 0.3, "the shape floats above the floor")
	var own := _prop_look()
	own.effect = _looping_effect()
	var uncoloured := PropView.pickup(own, "", null)
	eq(((_meshes(uncoloured)[0] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color, Color.WHITE,
		"no colour: the part keeps its own")
	check(not uncoloured.effect_params().has("color"), "no colour: the effect keeps its default")
	uncoloured.free()
	var plain := PropView.pickup(_prop_look(), "")
	check(((_meshes(plain)[0] as MeshInstance3D).material_override as StandardMaterial3D).next_pass == null, "no outline at width 0")
	check(not plain.has_node(^"Label"), "no label for an empty text")
	view.free()
	plain.free()


func test_a_pickup_spins_and_bobs() -> void:
	var look := _prop_look()
	look.spin_speed = 0.25
	look.bob_amount = 0.1
	look.bob_speed = 1.0
	var view := PropView.pickup(look, "")
	host.add_child(view)
	var rest := view.holder.position
	view._process(0.25)
	check(is_equal_approx(view.holder.rotation.y, 0.25 * 0.25 * TAU), "a quarter second turns it a sixteenth")
	check(is_equal_approx(view.holder.position.y, rest.y + 0.1), "at the top of its bob")
	view.free()


func test_a_chest_has_three_states() -> void:
	var look := _chest_look()
	var closed := PropView.chest(look, ChestLook.State.CLOSED, "Crate")
	var filled := PropView.chest(look, ChestLook.State.OPEN_FILLED, "")
	var empty := PropView.chest(look, ChestLook.State.OPEN_EMPTY, "")
	eq(closed.lid_pivot.rotation_degrees.x, 0.0, "closed: the lid down")
	check(is_equal_approx(filled.lid_pivot.rotation_degrees.x, -look.open_degrees), "open: the lid turned back on its hinge")
	eq(closed.lid_pivot.position, look.hinge, "the lid turns on the hinge")
	eq(_meshes(closed).size(), 2, "closed: body and lid only")
	var gold := _meshes(filled).filter(func(m: MeshInstance3D) -> bool: return (m.material_override as StandardMaterial3D).albedo_color == Color.GOLD)
	var dark := _meshes(empty).filter(func(m: MeshInstance3D) -> bool: return (m.material_override as StandardMaterial3D).albedo_color == Color.BLACK)
	check(gold.size() == 1 and dark.size() == 1, "filled shows its reward inside, empty its dark floor")
	check(filled.effect() == look.filled_effect and closed.effect() == null and empty.effect() == null, "only a filled chest glows")
	check(not filled.effect_params().has("color"), "a chest has no colour of its own: its effect keeps its default (code review)")
	eq(ChestLook.state_named("empty"), ChestLook.State.OPEN_EMPTY, "states by name")
	look.use_tint = true
	look.tint = Color.YELLOW
	var gilded := PropView.chest(look, ChestLook.State.CLOSED, "")
	eq(((_meshes(gilded)[0] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color, Color.YELLOW, "a tinted chest")
	for view in [closed, filled, empty, gilded]:
		view.free()


func test_a_pickups_effect_takes_its_colour_and_follows_visibility() -> void:
	var saved := {"enabled": FxManager.enabled, "manual": FxManager.manual_clock, "quality": FxManager.quality}
	FxManager.enabled = true
	FxManager.manual_clock = true
	FxManager.quality = FxQuality.HIGH
	var look := _prop_look()
	look.effect = _looping_effect()
	var view := PropView.pickup(look, "", Color.MAGENTA)
	eq(view.effect_params().get("color"), Color.MAGENTA, "the effect's colour parameter takes the prop's colour")
	var root := Node3D.new()
	host.add_child(root)
	root.add_child(view)
	await host.get_tree().process_frame
	var first: FxHandle = view.get("_fx")
	check(first != null and first.is_playing(), "it plays while shown")
	root.visible = false
	check(view.get("_fx") == null, "a hidden parent (a battle) stops it")
	root.visible = true
	check(view.get("_fx") != null, "shown again, it plays again")
	FxManager.quality = FxQuality.OFF
	FxManager.quality_changed.emit(FxQuality.OFF)
	check(view.get("_fx") == null, "quality off stops it")
	root.free()
	FxManager.quality = saved["quality"]
	FxManager.enabled = saved["enabled"]
	FxManager.manual_clock = saved["manual"]


func test_validator_prop_codes() -> void:
	var content := fixtures()
	var registry := StyleRegistry.new()
	registry.props = PropStyle.new()
	registry.props.key = PropLook.new()  # no shape
	registry.props.armor_by_slot[&"Slot.Head"] = _prop_look()
	registry.props.armor_by_slot[&"Equipment.Slot.Legs"] = null
	registry.props.rarity_colors[&"Rarity.Rare"] = Color.BLUE
	registry.props.chests[&"no.such.chest"] = _chest_look()
	var halfway := _chest_look()
	halfway.lid = null
	registry.props.chests[&"fixture.chest.crate"] = halfway
	var once := _prop_look()
	var light := FxLightLayer.new()
	once.effect = FxDefinition.new()
	once.effect.id = &"fx.once"
	once.effect.layers.append(light)
	registry.props.armor_default = once
	var codes: Array = []
	for issue in StyleValidator.validate(registry, content, "test"):
		codes.append(issue.code)
	for code in ["style_prop_shape_missing", "style_prop_slot_unknown", "style_prop_rarity_unknown", "style_prop_chest_unknown",
			"style_effect_not_looping"]:
		check(codes.has(code), "%s is reported: %s" % [code, codes])
	var clean := StyleRegistry.new()
	clean.props = PropStyle.new()
	clean.props.key = _prop_look()
	clean.props.chests[&"fixture.chest.crate"] = _chest_look()
	var errors := StyleValidator.validate(clean, content, "clean").filter(func(i: ValidationIssue) -> bool: return i.is_error())
	eq(errors.size(), 0, "a complete prop style is clean")


func test_style_props_command_needs_a_window() -> void:
	var registry := StyleRegistry.new()
	registry.props = PropStyle.new()
	UnitStyle.use(registry, "test")
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	var reply: Dictionary = await console.execute("style props")
	check(not reply["ok"] and reply["text"].contains("headless"), "headless there is no room view: %s" % reply["text"])
	UnitStyle.use(null)
	var none: Dictionary = await console.execute("style props")
	check(not none["ok"] and none["text"].contains("no style registry"), "no registry in use: %s" % none["text"])
