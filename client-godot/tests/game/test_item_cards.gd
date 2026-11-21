## Spec item-cards: floor items as their cards. The look's tiers (by rarity, the corrupted override), the label modes, an item's
## view (the card with its back, the rim and the aura by tier, the label), the room view drawing items, keys and armor through the
## registry (labels like the cards' at the cards' height, armor on the items' aura, today's cube with no item look), pickups turning
## around their middle, labels risen along the camera's up, baked faces reused, the aura's tier gates, the console, and the new
## classes kept out of combat, the run and the verifier. Built on the in-memory card fixtures (card_world.gd) and looks made here:
## the user's content and style cannot fail these.
extends TestCase

const ROOM_VIEW: String = "res://presentation/demo/room_view_3d.gd"
const AURA: String = "res://presentation/demo/fx/item_aura.tres"

var _nodes: Array[Node] = []


func after_each() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	ItemPropView.override_label = -1
	ItemPropView.bake_faces = true
	CardStyle.use(null)
	UnitStyle.reset()
	super()


func _keep(node: Node) -> Node:
	_nodes.append(node)
	return node


## A card style whose face scene is a bare CardFaceView (draws nothing, needs no art).
static func _card_style() -> CardStyle:
	var face := CardFaceView.new()
	var scene := PackedScene.new()
	scene.pack(face)
	face.free()
	var style := CardStyle.new()
	style.face_scenes[&"plain"] = scene
	style.face = &"plain"
	return style


static func _aura() -> FxDefinition:
	var effect := FxDefinition.new()
	effect.id = &"fx.test_item_aura"
	for spec in [[&"color", FxParam.Kind.COLOR], [&"tier", FxParam.Kind.FLOAT]]:
		var param := FxParam.new()
		param.name = spec[0]
		param.kind = spec[1]
		effect.params.append(param)
	var light := FxLightLayer.new()
	light.id = &"light"
	light.loop = true
	effect.layers.append(light)
	return effect


static func _look() -> ItemCardLook:
	var look := ItemCardLook.new()
	look.aura = _aura()
	return look


static func _shape(offset := Vector3.ZERO) -> AttachmentShape:
	var part := AttachmentPart.new()
	part.kind = AttachmentPart.Kind.BOX
	part.position = offset
	var shape := AttachmentShape.new()
	shape.parts.append(part)
	return shape


static func _registry(item_look: ItemCardLook) -> StyleRegistry:
	var registry := StyleRegistry.new()
	registry.props = PropStyle.new()
	registry.props.item = item_look
	registry.props.rarity_colors[&"Item.Rarity.Common"] = Color.WHITE
	registry.props.rarity_colors[&"Item.Rarity.Rare"] = Color.BLUE
	registry.props.rarity_colors[&"Item.Rarity.Legendary"] = Color.ORANGE
	var key := PropLook.new()
	key.shape = _shape()
	registry.props.key = key
	var armor := PropLook.new()
	armor.shape = _shape()
	registry.props.armor_default = armor
	return registry


static func _world() -> ContentIndex:
	var dark := CardWorld.item("t.void", "epic", CardWorld.CORE, ["Void"])
	dark.tags.append(&"Item.Corrupted")
	return CardWorld.content([CardWorld.item("t.common", "common", CardWorld.CORE, ["Treasure"]),
		CardWorld.item("t.rare", "rare", CardWorld.CORE, ["Treasure"]),
		CardWorld.item("t.legend", "legendary", CardWorld.CORE, ["Treasure"]), dark,
		CardWorld.piece("t.blade", "legendary", CardWorld.CORE, ["Treasure"])])


func test_tiers_follow_rarity_and_corrupted_overrides_it() -> void:
	var look := _look()
	eq(look.tier_of([&"Item.Rarity.Common"]), 0, "Common")
	eq(look.tier_of([&"Item.Rarity.Rare"]), 1, "Rare")
	eq(look.tier_of([&"Item.Rarity.Epic"]), 2, "Epic")
	eq(look.tier_of([&"Card.Set.Core", &"Item.Rarity.Legendary"]), 3, "Legendary, whatever comes first")
	eq(look.tier_of([&"Item.Rarity.Common", &"Item.Corrupted"]), look.void_tier, "corrupted takes the void tier over its rarity")
	eq(look.tier_of([]), 0, "no rarity: tier 0")
	check(look.rim_energy(3) > look.rim_energy(0), "the rim glows brighter at a higher tier")
	eq(look.rim_energy(9), look.rim_energy(3), "a tier past the table takes the last value")


func test_label_modes() -> void:
	var name_mode := ItemCardLook.LabelMode.NAME_AND_PRICE
	eq(ItemCardLook.label_text(name_mode, "Horn", 5), "Horn (5)", "name and price for sale")
	eq(ItemCardLook.label_text(name_mode, "Horn", 0), "Horn", "a free pickup: its name")
	eq(ItemCardLook.label_text(ItemCardLook.LabelMode.PRICE_ONLY, "Horn", 5), "5 Gold", "price only")
	eq(ItemCardLook.label_text(ItemCardLook.LabelMode.PRICE_ONLY, "Horn", 0), "", "price only and free: no label")
	eq(ItemCardLook.label_text(ItemCardLook.LabelMode.NONE, "Horn", 5), "", "no label")
	var look := _look()
	eq(look.label, ItemCardLook.LabelMode.NAME_AND_PRICE, "name and price by default (user, 2026-11-21)")
	eq(ItemPropView.label_for(look, "Key", 5), "Key (5)", "a key labels like a card")
	ItemPropView.override_label = ItemCardLook.LabelMode.NONE
	eq(ItemPropView.label_for(look, "Key", 5), "", "the session's override wins")


func test_an_item_is_its_card_with_rim_aura_and_label() -> void:
	var style := _card_style()
	CardStyle.use(style)
	var registry := _registry(_look())
	var content := _world()
	var view: ItemPropView = _keep(ItemPropView.for_item(registry.item_look(), content, &"t.rare", registry, 15))
	check(view.card != null and view.card.face != null and view.card.face.id == "t.rare", "the item's own card face")
	check(view.card.back_mesh != null, "the card back on the reverse (it spins)")
	eq(view.tier, 1, "a Rare item is tier 1")
	eq(view.colour, Color.BLUE, "its colour from the floor map (the armor icons' colours)")
	eq(view.card.material.get_shader_parameter(&"rim_color"), Color.BLUE, "the rim in that colour")
	check(float(view.card.material.get_shader_parameter(&"rim_width")) > 0.0, "the rim is on")
	eq(view.effect(), registry.item_look().aura, "the item aura plays on it")
	eq(view.effect_params().get(&"tier"), 1.0, "at its tier")
	eq(view.effect_params().get("color"), Color.BLUE, "in its colour")
	eq(view.label_node.text, "t.rare (15)", "name and price")
	check(is_equal_approx(view.card.card_height, registry.item_look().size), "the card at the look's size")
	var dark: ItemPropView = _keep(ItemPropView.for_item(registry.item_look(), content, &"t.void", registry))
	check(dark.corrupted and dark.tier == registry.item_look().void_tier, "a corrupted item at the void tier")
	eq(dark.colour, registry.item_look().void_color, "in magenta, whatever its rarity")
	eq(dark.label_node.text, "t.void", "free: its name only")


func test_the_room_view_draws_items_keys_and_armor() -> void:
	CardStyle.use(_card_style())
	var item_look := _look()
	var registry := _registry(item_look)
	UnitStyle.use(registry, "test")
	var content := _world()
	var room: Node3D = _keep(load(ROOM_VIEW).new())
	var props := Node3D.new()
	room.add_child(props)
	room.set("_props_root", props)
	check(room._styled_prop(Vector2i(2, 2), {"item": &"t.legend", "price": 30}, null, " (30)", content), "an item is drawn")
	var card := props.get_child(0) as ItemPropView
	check(card != null and card.label_node.text == "t.legend (30)", "as its card, labelled with name and price")
	check(room._styled_prop(Vector2i(3, 2), {"item": FloorGenerator.KEYS_KIND, "kind": FloorGenerator.KEYS_KIND, "keys": 1,
		"price": 5}, null, " (5)", content), "a key is drawn")
	var key := props.get_child(1) as PropView
	eq(key.label_node.text, "Key (5)", "a key labels like the cards")
	check(is_equal_approx(key._label_height, item_look.label_height), "at the cards' label height")
	var blade: EquipmentDefinition = content.equipment[&"t.blade"]
	check(room._styled_prop(Vector2i(4, 2), {"item": &"t.blade", "price": 0}, blade, "", content), "armor is drawn")
	var armor := props.get_child(2) as PropView
	eq(armor.effect(), item_look.aura, "armor plays the items' aura (user Q2)")
	eq(armor.effect_params().get(&"tier"), 3.0, "at its rarity's tier")
	eq(armor.label_node.text, "t.blade", "free armor: its name")
	registry.props.item = null
	check(not room._styled_prop(Vector2i(5, 2), {"item": &"t.common", "price": 0}, null, "", content),
		"no item look: today's cube draws the item")


func test_a_pickup_turns_around_its_middle_and_its_label_rises_along_the_camera() -> void:
	var look := PropLook.new()
	look.shape = _shape(Vector3(0.4, 0, -0.2))  # a part off the origin, like the key's ring
	var view: PropView = _keep(PropView.pickup(look, "Key (5)", null, 1.6))
	var shape := view.holder.get_child(0).get_child(0) as Node3D
	var centre := PropView.bounds_centre(shape)
	check(absf(centre.x) < 0.001 and absf(centre.z) < 0.001, "the shape's middle is on the spin axis: %s" % centre)
	check(is_equal_approx(view._label_height, 1.6), "the label at the height asked for")
	host.add_child(view)
	var camera := Camera3D.new()
	host.add_child(camera)
	_nodes.append(camera)
	camera.position = Vector3(3, 9, 8)
	camera.rotation_degrees = Vector3(-50, 0, 0)
	camera.make_current()
	view._place_label()
	var base := view.global_position + Vector3(0, view._rest.y, 0)
	var rise := view.label_node.global_position - base
	var up := camera.global_basis.y.normalized()
	check(rise.normalized().dot(up) > 0.999, "the label rises along the camera's up, so it stays above the shape on screen")
	check(is_equal_approx(rise.length(), (1.6 - view._rest.y) * up.y), "as high on screen as a straight rise: %s" % rise)
	view.scale = Vector3.ONE * 0.2  # an item still small as it pops out of a chest
	view._place_label()
	var small := view.label_node.global_position - (view.global_position + Vector3(0, view._rest.y * 0.2, 0))
	check(is_equal_approx(small.length(), rise.length() * 0.2), "the label stays with an item that is still growing")


func _shown_card(style: CardStyle, name: String) -> CardView3D:
	var face := CardFace.new()
	face.id = "test.card"
	face.name = name
	var card := CardView3D.new()
	_keep(card)
	host.add_child(card)
	card.show_face(face, style, style.face_scene(), 0.7, 1.0)
	return card


func test_a_baked_face_is_reused_and_keyed_by_what_it_shows() -> void:
	CardView3D.clear_baked()
	var style := _card_style()
	var card := _shown_card(style, "Horn")
	var texture := ImageTexture.create_from_image(Image.create(4, 4, true, Image.FORMAT_RGBA8))
	CardView3D._baked[card.baked_face_key()] = texture
	card.bake()
	eq(card.material.get_shader_parameter(&"face_baked"), texture, "the cached face is used, nothing rendered again")
	eq(card.material.get_shader_parameter(&"use_baked"), 1.0, "and drawn instead of the live viewport")
	eq(card.viewport.render_target_update_mode, SubViewport.UPDATE_DISABLED, "the face's viewport stops")
	var renamed := _shown_card(style, "Horn of Plenty")
	check(renamed.baked_face_key() != card.baked_face_key(), "another face (a content change) bakes anew")
	var restyled := _shown_card(_card_style(), "Horn")
	check(restyled.baked_face_key() != card.baked_face_key(), "another style (a style reload) bakes anew")
	var bigger := _shown_card(style, "Horn")
	bigger.set_render_scale(2.0)
	check(bigger.baked_face_key() != card.baked_face_key(), "another render scale bakes anew")
	check(not card.baked_face_key().begins_with("back"), "faces and the back never share a key")
	CardView3D.clear_baked()
	check(CardView3D._baked.is_empty(), "clear_baked forgets them")


func test_a_card_freed_mid_bake_ends_the_bake_quietly() -> void:
	CardView3D.clear_baked()
	var card := _shown_card(_card_style(), "Gone")
	card.bake()   # waits for frames in a static coroutine that holds only a weak reference
	card.free()
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	check(CardView3D._baked.is_empty(), "nothing cached for a card that is gone (and no 'instance is gone' error)")


func test_the_bake_cache_drops_its_oldest_face_first() -> void:
	CardView3D.clear_baked()
	var texture := ImageTexture.create_from_image(Image.create(4, 4, true, Image.FORMAT_RGBA8))
	for i in CardView3D.BAKED_CAP:
		CardView3D._store_baked("face:%d" % i, texture)
	eq(CardView3D._baked.size(), CardView3D.BAKED_CAP, "full")
	CardView3D._store_baked("face:new", texture)
	eq(CardView3D._baked.size(), CardView3D.BAKED_CAP, "never past the cap, and never emptied at once")
	check(not CardView3D._baked.has("face:0") and CardView3D._baked.has("face:1") and CardView3D._baked.has("face:new"),
		"only the oldest entry goes")


func test_the_aura_gates_its_layers_by_tier() -> void:
	if skip_in_export():
		return
	var aura: FxDefinition = load(AURA)
	check(aura.param(&"color") != null and aura.param(&"tier") != null, "the aura takes color and tier")
	var by_id := {}
	for layer in aura.layers:
		by_id[layer.id] = layer
		check(layer.loop, "%s loops" % layer.id)
	for wanted in [&"pool", &"motes", &"sparks", &"ribbons"]:
		check(by_id.has(wanted), "a %s layer" % wanted)
	var gate := func(layer_id: StringName, property: String, tier: float) -> float:
		for binding in by_id[layer_id].bindings:
			if binding.property.ends_with(property):
				return float(binding.value_for(tier, aura.param(&"tier")))
		return -1.0
	check(gate.call(&"sparks", "amount_ratio", 1.0) < 0.01 and gate.call(&"sparks", "amount_ratio", 2.0) > 0.99,
		"sparks from Epic up")
	check(gate.call(&"ribbons", "strength", 2.0) < 0.01 and gate.call(&"ribbons", "strength", 3.0) > 0.99, "ribbons at Legendary")
	check(gate.call(&"pool", "intensity", 3.0) > gate.call(&"pool", "intensity", 0.0), "the glow pool brightest at Legendary")
	check(gate.call(&"motes", "amount_ratio", 0.0) > 0.0, "a few motes even on Common")


func test_style_items_console() -> void:
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	UnitStyle.use(_registry(_look()), "test")
	var shown: Dictionary = await console.execute("style items shop")
	check(not shown["ok"] and shown["text"].contains("headless"), "the showcase needs a window: %s" % shown["text"])
	var label: Dictionary = await console.execute("style items label price")
	check(label["ok"] and ItemPropView.override_label == ItemCardLook.LabelMode.PRICE_ONLY, "label price for the session")
	var bad: Dictionary = await console.execute("style items label huge")
	check(not bad["ok"], "an unknown label mode is refused")
	var typo: Dictionary = await console.execute("style items bake")
	check(not typo["ok"] and ItemPropView.bake_faces, "bake without on or off is refused and changes nothing")
	var bake: Dictionary = await console.execute("style items bake off")
	check(bake["ok"] and not ItemPropView.bake_faces, "faces live for the session")
	var unknown: Dictionary = await console.execute("style items glyph")
	check(not unknown["ok"] and unknown["text"].contains("usage"), "the deleted concepts are gone")
	UnitStyle.use(StyleRegistry.new(), "empty")
	var none: Dictionary = await console.execute("style items shop")
	check(not none["ok"] and none["text"].contains("no item look"), "a registry without an item look says so")


func test_combat_run_and_verifier_never_name_the_item_cards() -> void:
	if skip_in_export():
		return
	var names := ["ItemPropView", "ItemCardLook", "item_card_look", "item_aura"]
	var found: Array[String] = []
	for root in ["res://combat/", "res://game/verify/"]:
		_scan(root, names, found)
	for file in ["res://game/run_controller.gd", "res://game/run_state.gd", "res://game/run_snapshot.gd", "res://game/run_wire.gd",
			"res://game/floor_generator.gd"]:
		var text := FileAccess.get_file_as_string(file)
		for name in names:
			if text.contains(name):
				found.append("%s names %s" % [file, name])
	eq(found, [] as Array[String], "presentation only")


func _scan(directory: String, names: Array, found: Array[String]) -> void:
	for sub in DirAccess.get_directories_at(directory):
		_scan(directory + sub + "/", names, found)
	for file in DirAccess.get_files_at(directory):
		if file.ends_with(".gd"):
			var text := FileAccess.get_file_as_string(directory + file)
			for name in names:
				if text.contains(name):
					found.append("%s names %s" % [directory + file, name])
