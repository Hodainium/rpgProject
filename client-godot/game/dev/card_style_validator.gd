## Spec card-ui 6: checks the card style against the content (validate_content.tscn and the tests). Errors: a rarity the catalog uses
## with no look (card_style_rarity_missing), no face scene for the active look (card_style_face_missing). Warnings: an item or armor
## card with no glyph (card_icon_missing: it shows the default), and as an error two cards sharing a glyph (card_icon_shared; only a
## Void card may share the glyph of the item it corrupts, user 2026-11-18), a character with no portrait (card_portrait_missing), a portrait
## older than its character's look file (card_portrait_stale: re-run game/tools/build_card_portraits.tscn -- --force --only <id>).
class_name CardStyleValidator
extends RefCounted


static func validate(style: CardStyle, content: ContentIndex, registry: StyleRegistry = null) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if style == null:
		return issues
	var where := CardStyle.DEFAULT_PATH
	if style.face_scene() == null:
		issues.append(ValidationIssue.new(ValidationIssue.ERROR, "card_style_face_missing", where + ".face_scenes",
			"no face scene for the active look '%s'" % style.face))
	var rarities := {}
	var holders := {}  # glyph path → item and armor card ids drawn with it (Void twins left out)
	for card in CardCatalog.cards(content):
		if card["kind"] != CardCatalog.KIND_CHARACTER and CardIconPass.twin_of(content, card["id"]) == "":
			var glyph := style.art_for(StringName(card["id"]))
			if glyph != null and glyph.resource_path != "":
				holders[glyph.resource_path] = holders.get(glyph.resource_path, []) + [card["id"]]
	var paths: Array[String] = []
	paths.assign(holders.keys())
	paths.sort()
	for path in paths:
		if holders[path].size() > 1:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "card_icon_shared", ", ".join(holders[path]),
				"these cards share the glyph %s; every card has its own (only a Void card may share its item's): give each a NAME_ICONS entry in game/cards/card_icon_pass.gd and re-run build_card_icon_pass.tscn -- --apply --force" % path.get_file()))
	for card in CardCatalog.cards(content):
		rarities[card["rarity"]] = true
		var id := StringName(card["id"])
		var art := style.art_for(id)
		if card["kind"] == CardCatalog.KIND_CHARACTER:
			if art == null:
				issues.append(ValidationIssue.new(ValidationIssue.WARNING, "card_portrait_missing", String(id),
					"no portrait: run game/tools/build_card_portraits.tscn (a window tool)"))
			elif registry != null:
				var stale := _stale(art, registry, content.characters.get(id))
				if stale != "":
					issues.append(ValidationIssue.new(ValidationIssue.WARNING, "card_portrait_stale", String(id), stale))
		elif art == null:
			issues.append(ValidationIssue.new(ValidationIssue.WARNING, "card_icon_missing", String(id),
				"no glyph: the card shows the default icon (game/tools/build_card_icon_pass.tscn proposes one)"))
	var names := rarities.keys()
	names.sort()  # sort-ok: rarity names are Strings
	for rarity in names:
		if rarity != "" and not style.rarities.has(StringName(rarity)):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "card_style_rarity_missing", where + ".rarities",
				"the catalog uses rarity '%s' and the style has no look for it" % rarity))
	return issues


## Why the portrait is older than the character's look file, or "".
static func _stale(portrait: Texture2D, registry: StyleRegistry, definition: UnitDefinition) -> String:
	if definition == null or portrait.resource_path == "":
		return ""
	var look := registry.look_for(definition)
	var look_path := look.resource_path if look != null else ""
	if look_path == "" or look_path.contains("::"):  # a look inside the registry: its file is the registry
		look_path = registry.resource_path
	if look_path == "" or not FileAccess.file_exists(look_path):
		return ""
	if FileAccess.get_modified_time(look_path) > FileAccess.get_modified_time(portrait.resource_path):
		return "the portrait is older than %s: re-run game/tools/build_card_portraits.tscn -- --force --only %s" % [
			look_path, definition.id]
	return ""
