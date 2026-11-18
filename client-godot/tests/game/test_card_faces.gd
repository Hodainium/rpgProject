## Spec card-ui 3.3 / 3.5 / 6 (the first gate): the card face data (type lines, element resolution order, the character tie rule,
## art, catalog drift), the icon pass's pick, and both face scenes filled without an error. Card fixtures (card_world.gd) and a
## style built here: the user's content and style cannot fail these.
extends TestCase

var _nodes: Array[Node] = []


func after_each() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	super()


static func _query(tags: Array) -> GameplayTagQuery:
	var query := GameplayTagQuery.new()
	var typed: Array[StringName] = []
	for tag in tags:
		typed.append(StringName(tag))
	query.require_any_tags = typed
	return query


static func _rule(tags: Array, element: StringName, in_abilities: bool) -> CardElementRule:
	var rule := CardElementRule.new()
	rule.query = _query(tags)
	rule.element = element
	rule.look_in_abilities = in_abilities
	return rule


## The seed rules of spec 3.2.
static func _style() -> CardStyle:
	var style := CardStyle.new()
	style.element_rules.assign([_rule(["Item.Corrupted"], &"void", false), _rule(["Item.Food", "Pool.Food"], &"food", false),
		_rule(["Damage.Type.Fire"], &"fire", true), _rule(["Damage.Type.Ice"], &"ice", true),
		_rule(["Damage.Type.Physical"], &"physical", true)])
	return style


## A packed "ability" whose node carries `tags` (what the face reads from an ability scene: any tag stored inside it).
static func _ability(tags: Array) -> PackedScene:
	var node := Node.new()
	var typed: Array[StringName] = []
	for tag in tags:
		typed.append(StringName(tag))
	node.set_meta(&"tags", typed)
	var scene := PackedScene.new()
	scene.pack(node)
	node.free()
	return scene


func _faces(list: Array, style: CardStyle = null) -> Dictionary:
	var by_id := {}
	for face in CardFaces.build(CardWorld.content(list), style if style != null else _style()):
		by_id[face.id] = face
	return by_id


func test_type_lines() -> void:
	var list := CardWorld.resources()
	var usable := CardWorld.item("card.item.lens", "Rare", CardWorld.DESCENT, ["Shop"])
	usable.kind = ItemDefinition.Kind.USABLE
	usable.use_mode = ItemDefinition.UseMode.COOLDOWN
	usable.cooldown_battles = 2
	var potion := CardWorld.item("card.item.potion", "Common", CardWorld.DESCENT, ["Shop"])
	potion.kind = ItemDefinition.Kind.USABLE
	var tank := CardWorld.hero("card.hero.tank", CardWorld.DESCENT)
	tank.role = "Damage dealer: magic"
	list.append_array([usable, potion, tank])
	var faces := _faces(list)
	eq(faces["card.item.c2"].type_line, "Item — Passive · Treasure", "a passive item names its first pool")
	eq(faces["card.item.food"].type_line, "Item — Food", "food")
	eq(faces["card.item.lens"].type_line, "Item — Usable · 2 battles", "usable with a cooldown")
	eq(faces["card.item.potion"].type_line, "Item — Consumable", "consumable")
	eq([faces["card.gear.sword"].type_line, faces["card.gear.sword"].kind, faces["card.gear.sword"].slot],
		["Armor — Weapon", "equipment", "Weapon"], "armor names its slot")
	eq(faces["card.hero.tank"].type_line, "Character — Damage dealer", "a character's role, up to the colon")
	eq(faces["card.hero.a"].type_line, "Character — Hero", "a character with no role")
	eq([faces["card.hero.a"].kind, faces["card.hero.a"].rarity, faces["card.hero.a"].core], ["character", "mythic", true], "kind, rarity, core")
	eq(faces["card.item.c2"].pools, ["Treasure"] as Array[String], "pools without the prefix")


func test_element_resolution_order() -> void:
	var list := CardWorld.resources()
	var burning := CardWorld.item("card.item.burning", "Rare", CardWorld.DESCENT, ["Treasure"])
	burning.grants = AbilitySet.new()
	burning.grants.abilities.append(_ability(["Damage.Type.Fire"]))
	var icy_void := CardWorld.item("card.item.icy_void", "Rare", CardWorld.DESCENT, ["Treasure"])
	icy_void.tags.append(&"Item.Corrupted")
	icy_void.grants = AbilitySet.new()
	icy_void.grants.abilities.append(_ability(["Damage.Type.Ice"]))
	var overridden := CardWorld.item("card.item.overridden", "Rare", CardWorld.DESCENT, ["Treasure"])
	overridden.grants = AbilitySet.new()
	overridden.grants.abilities.append(_ability(["Damage.Type.Fire"]))
	list.append_array([burning, icy_void, overridden])
	var style := _style()
	style.element_overrides[&"card.item.overridden"] = &"ice"
	var faces := _faces(list, style)
	eq(faces["card.item.overridden"].element, &"ice", "the override comes first")
	eq(faces["card.item.icy_void"].element, &"void", "then the rules in order (corrupted before ice)")
	check(faces["card.item.icy_void"].corrupted, "and it is corrupted")
	eq(faces["card.item.burning"].element, &"fire", "a rule that looks in the abilities")
	eq(faces["card.item.food"].element, &"food", "a tag rule")
	eq(faces["card.item.c2"].element, &"neutral", "nothing matches: the default")


func test_a_character_takes_its_most_common_damage_type() -> void:
	var list := CardWorld.resources()
	var frost := CardWorld.hero("card.hero.frost", CardWorld.DESCENT)
	frost.abilities.assign([_ability(["Damage.Type.Ice"]), _ability(["Damage.Type.Ice"]), _ability(["Damage.Type.Fire"])])
	var even := CardWorld.hero("card.hero.even", CardWorld.DESCENT)
	even.abilities.assign([_ability(["Damage.Type.Ice"]), _ability(["Damage.Type.Fire"])])
	list.append_array([frost, even])
	var faces := _faces(list)
	eq(faces["card.hero.frost"].element, &"ice", "two ice, one fire: ice (the fire rule does not decide for a character)")
	eq(faces["card.hero.even"].element, &"fire", "a tie goes physical, then fire, then ice")
	eq(faces["card.hero.a"].element, &"neutral", "no damage type: the default")


func test_art_and_catalog_drift() -> void:
	var style := _style()
	var icons := CardArtSet.new()
	var glyph := PlaceholderTexture2D.new()
	icons.textures[&"card.item.c2"] = glyph
	var portraits := CardArtSet.new()
	var still := PlaceholderTexture2D.new()
	portraits.textures[&"card.hero.a"] = still
	style.art_sets.assign([icons, portraits])
	var content := CardWorld.content()
	var rows := CardCatalog.cards(content)
	rows.append({"id": "server.only.card", "kind": "item", "rarity": "rare", "setId": "descent", "core": false, "pools": ["Pool.Shop"]})
	var by_id := {}
	for face in CardFaces.build(content, style, rows):
		by_id[face.id] = face
	check(by_id["card.item.c2"].icon == glyph, "an item's glyph from the art sets")
	check(by_id["card.hero.a"].portrait == still, "a character's portrait")
	check(by_id["card.item.c3"].icon == null, "no glyph: null (the face falls back to the default icon)")
	var unknown: CardFace = by_id["server.only.card"]
	eq([unknown.unknown, unknown.name, unknown.type_line], [true, "server.only.card", "Unknown card"], "a card the content lacks")


func test_icon_pick() -> void:
	var stems := {"lantern-flame": {}, "tooth": {}, "broadsword": {}, "swap-bag": {}}
	eq(CardIconPass.pick_icon("Frost Lantern", "", stems), {"stem": "lantern-flame", "by": "keyword"}, "a keyword, last word first")
	eq(CardIconPass.pick_icon("Mimic Tooth", "", stems), {"stem": "tooth", "by": "word"}, "a glyph named like a word")
	eq(CardIconPass.pick_icon("Old Thing", "Weapon", stems), {"stem": "broadsword", "by": "slot"}, "an armor slot")
	eq(CardIconPass.pick_icon("Old Thing", "", stems), {"stem": "swap-bag", "by": "fallback"}, "the fallback")


func test_cardui_look_switches_in_memory() -> void:
	var style := CardStyle.current()
	var was := style.face
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	_nodes.append(game)
	console.attach(game)
	var shown: Dictionary = await console.execute("cardui look")
	check(shown["ok"] and shown["text"].contains("grimoire"), "names the look: " + shown["text"])
	var switched: Dictionary = await console.execute("cardui look grimoire")
	check(switched["ok"] and style.face == &"grimoire", "switches to Look B")
	var refused: Dictionary = await console.execute("cardui look nowhere")
	check(not refused["ok"], "an unknown look is refused")
	style.face = was


func test_the_face_fills_every_card() -> void:
	var style := CardStyle.current()
	eq(style.face, &"grimoire", "Look B is the active look (the user's pick)")
	var scene := style.face_scene()
	check(scene != null, "the style has its face scene")
	if scene == null:
		return
	var faces := _faces(CardWorld.resources())
	for face in faces.values():
		var view: CardFaceView = scene.instantiate()
		view.animate = false
		host.add_child(view)
		_nodes.append(view)
		view.show_face(face, style)
	await host.get_tree().process_frame
	var by_rarity := {}
	for rarity in ["common", "legendary", "mythic"]:
		var face := CardFace.new()
		face.id = "card.test." + rarity
		face.name = rarity
		face.rarity = rarity
		var view: CardFaceView = scene.instantiate()
		view.animate = false
		host.add_child(view)
		_nodes.append(view)
		view.show_face(face, style)
		by_rarity[rarity] = view
	eq([by_rarity["common"].get_node("%Foil").visible, by_rarity["common"].get_node("%Mythic").visible], [false, false],
		"Common: no effect")
	eq([by_rarity["legendary"].get_node("%Foil").visible, by_rarity["legendary"].get_node("%Mythic").visible], [true, false],
		"Legendary: the gold sheen")
	eq([by_rarity["mythic"].get_node("%Mythic").visible, by_rarity["mythic"].get_node("%Prism").visible], [true, true],
		"Mythic: glitter over the opal frame")
	var hero: CardFace = faces["card.hero.a"]
	var named: CardFaceView = scene.instantiate()
	host.add_child(named)
	_nodes.append(named)
	named.show_face(hero, style)
	eq(named.get_node("%Name").text, "card.hero.a", "the name bar")


## Spec card-ui 6: the gallery builds every page headless with no error.
func test_card_gallery_builds_headless() -> void:
	var gallery: Control = load("res://game/dev/card_gallery.tscn").instantiate()
	host.add_child(gallery)
	_nodes.append(gallery)
	await host.get_tree().process_frame
	check(gallery.screens.size() >= 2, "a showcase and the catalog pages: %d" % gallery.screens.size())
	for index in gallery.screens.size():
		gallery.page = index
		gallery._show_page()
	await host.get_tree().process_frame


## Spec card-ui 6: the card style validator.
func test_card_style_validator() -> void:
	var content := CardWorld.content()
	var style := _style()
	style.rarities[&"common"] = CardRarityLook.new()
	var icons := CardArtSet.new()
	icons.textures[&"card.item.c2"] = PlaceholderTexture2D.new()
	style.art_sets.assign([icons])
	var codes := {}
	for issue in CardStyleValidator.validate(style, content):
		codes[issue.code] = codes.get(issue.code, 0) + 1
	check(codes.has("card_style_face_missing"), "no face scene: an error")
	check(codes.has("card_style_rarity_missing"), "a rarity with no look: an error")
	check(codes.get("card_portrait_missing", 0) == 5, "every character without a portrait: %s" % codes)
	check(codes.has("card_icon_missing"), "an item without a glyph: a warning")
	var demo := CardStyleValidator.validate(CardStyle.current(), ContentIndex.new("res://content/"))
	var errors := demo.filter(func(issue: ValidationIssue) -> bool: return issue.is_error())
	eq(errors.size(), 0, "the demo style has no errors: %s" % ", ".join(errors.map(func(issue: ValidationIssue) -> String: return issue.code)))
	eq(demo.filter(func(issue: ValidationIssue) -> bool: return issue.code in ["card_icon_missing", "card_portrait_missing"]).size(), 0,
		"every demo card has its art")
