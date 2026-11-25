## Spec card-ui 3.5: proposes a game-icons glyph for every item and armor card from a keyword table (the words of its name, last
## word first; then a glyph named like a word; then its armor slot; then the fallback) and, with an explicit apply, copies only
## the glyphs used into presentation/demo/cards/icons/<author>/ and writes card_icons.tres, both as new files only (an existing
## file is left as it is unless forced). Characters need no icon: their art is a portrait. Deterministic: the same content and
## icon folder give the same proposal. The keyword table is the approved prototype's (specs/design/card-ui-prototype/build_data.py).
class_name CardIconPass
extends RefCounted

## The icon folder: game-icons.net's white-on-transparent 512 px set, one folder per author (outside the repo).
const DEFAULT_SOURCE: String = "H:/assets/game-icons/ffffff/transparent/1x1"
const DEST_DIR: String = "res://presentation/demo/cards/icons"
## The first author that has a glyph wins (the rest follow in name order).
const AUTHOR_ORDER: Array[String] = ["lorc", "delapouite", "skoll", "carl-olsen"]
const FALLBACK: String = "swap-bag"
## The style's own glyphs: the set marks, the crest, the fallback and the lock of a locked card.
const STYLE_GLYPHS: Array[String] = ["cube", "stairs", "crown", "padlock", FALLBACK]

## A word of a card's name → a glyph's file stem (the prototype's table, approved 2026-11-15).
const KEYWORDS: Dictionary = {
	"lantern": "lantern-flame", "seal": "wax-seal", "fang": "fangs", "fangs": "fangs", "sigil": "pentacle", "rations": "meat",
	"haunch": "meat", "cake": "cake-slice", "feast": "hot-meal", "lens": "magnifying-glass", "loupe": "magnifying-glass",
	"bell": "ringing-bell", "horn": "hunting-horn", "drum": "drum", "coil": "electrical-resistance", "heart": "heart-organ",
	"totem": "totem-head", "thorns": "thorny-vine", "thorn": "thorny-vine", "mail": "chain-mail", "vest": "leather-vest",
	"charm": "gem-pendant", "pendant": "gem-pendant", "band": "ring", "ring": "ring", "halo": "crowned-heart",
	"mark": "target-arrows", "bounty": "wanted-reward", "oath": "scroll-unfurled", "fleece": "sheep", "pact": "blood",
	"breaker": "hammer-break", "maul": "warhammer", "blade": "broadsword", "dagger": "plain-dagger", "crown": "crown",
	"greaves": "leg-armor", "bracers": "bracer", "hide": "animal-hide", "potion": "potion-ball", "tonic": "potion-ball",
	"bomb": "unlit-bomb", "salve": "medicines", "ether": "magic-potion", "salts": "powder", "water": "holy-water",
	"metronome": "metronome", "fork": "tuning-fork", "loop": "ouroboros", "tome": "book-cover", "hourglass": "hourglass",
	"edge": "sword-wound", "gloves": "gloves", "mirror": "mirror-mirror", "censer": "smoking-orb", "key": "key",
	"lockpick": "padlock", "rod": "lightning-helix", "fob": "pocket-watch", "skeleton": "skeleton-key", "ember": "flame",
	"frost": "snowflake-1", "bellows": "bellows", "dynamo": "electric", "eye": "eyeball", "quiver": "quiver",
	"bow": "pocket-bow", "staff": "wizard-staff", "shield": "checked-shield", "helm": "visored-helm", "cap": "pointy-hat",
	"brand": "flaming-claw", "amulet": "gem-pendant", "glove": "gloves", "coin": "two-coins", "purse": "coins",
	"idol": "medal", "flask": "round-bottom-flask", "crystal": "crystal-growth", "core": "fire-ring", "shard": "crystal-shine",
	"skin": "stone-block", "banner": "flag-objective", "whetstone": "stone-sphere", "ledger": "book-cover", "satchel": "knapsack",
	"wing": "angel-wings", "badge": "rank-3", "stew": "hot-meal", "heartstring": "harp", "rites": "tombstone",
	"shatterpoint": "shatter", "toxic": "poison-bottle", "box": "present",
}
## A card's whole name (lower case) → its glyph, checked before the words (user, 2026-11-18: every card its own glyph; the
## keyword table gave one glyph to whole families, ten rings, eleven charms). Only a Void card may share, with the item it corrupts.
const NAME_ICONS: Dictionary = {
	"slag plate": "breastplate", "vestment": "robe", "dynamo coil": "tesla-coil", "cinder glove": "fire-punch",
	"hearty stew": "bubbling-bowl", "duelist's band": "diamond-ring", "mana locket": "double-necklace",
	"quickstep anklet": "running-shoe", "tactician's ring": "big-diamond-ring", "tuning fork": "musical-notes",
	"warding talisman": "ankh", "scar ring": "double-ringed-orb", "skeleton ring": "skeleton-key", "ledger": "notebook",
	"headsman's blade": "battle-axe", "war axe": "war-axe", "hunting knife": "bowie-knife", "keen rapier": "piercing-sword",
	"witch's eye": "evil-eyes", "sunforged brand": "sun", "ember pendant": "fire-gem", "iron charm": "charm",
	"cadence charm": "music-spell", "frost ember charm": "frozen-orb", "frostfire charm": "frostfire",
	"frostguard charm": "snowflake-2", "hexbreaker charm": "magic-shield", "lucid charm": "crystal-eye",
	"momentum charm": "whirlwind", "swift charm": "wingfoot", "heart locket": "heart-necklace", "ember heart": "burning-passion",
	"glass heart": "glass-heart", "second heart": "heart-plus", "rally horn": "mighty-horn", "appraiser's loupe": "spectacle-lenses",
	"glass lens": "microscope-lens", "rations": "bread-slice", "gilded idol": "trophy", "clarion bell": "windchimes",
	"purifying bell": "bell-shield", "plague flask": "bubbling-flask", "oath stone": "rune-stone", "shatter hammer": "thor-hammer",
	"kindled edge": "burning-embers", "serrated edge": "serrated-slash", "tempered edge": "anvil-impact", "bounty mark": "wanted-reward",
	"fire bomb": "fire-bomb", "frost bomb": "ice-bomb", "seer's circlet": "jewel-crown", "predator's fang": "saber-tooth",
	"siphon sigil": "heart-drop", "thrift sigil": "piggy-bank", "corrupted sigil": "cursed-star", "thornbark mail": "scale-mail",
	# Spec item-power (the user's OK, 2026-11-23).
	"chain bell": "crossed-chains", "feast knife": "meat-cleaver", "vengeful aegis": "shield-reflect", "sun heart": "sun-priest",
	"undying ember": "fire-silhouette", "shatter covenant": "cracked-shield", "philosopher's coin": "gold-bar",
	"twin soul": "double-face-mask", "plague crown": "virus", "echo crown": "echo-ripples", "void heart": "broken-heart",
	"hollow crown": "queen-crown", "void tether": "linked-rings", "null lens": "sight-disabled",
	"starving maw": "carnivore-mouth", "echo of nothing": "vortex", "chain hook": "hook", "reaper's mark": "grim-reaper",
	"guardian's vow": "heart-shield", "venom spur": "scorpion-tail", "second wind": "lungs", "lifebloom seed": "sprout",
	"battle hymn": "lyre", "bulwark sigil": "castle", "static ring": "power-ring", "hunter's snare": "wolf-trap",
	"blood charm": "bleeding-wound", "thick hide": "rhinoceros-horn", "kindling": "campfire", "quick draw": "quick-slash",
	"focus stone": "meditation", "mender's bell": "healing", "executioner's greatsword": "guillotine",
	"storm spear": "thunder-blade", "bloodthirst blade": "bloody-sword", "runebound staff": "crystal-wand",
	"thornheart plate": "spiked-armor", "sentinel plate": "abdominal-armor", "mantle of haste": "cape",
	"warlord's crown": "crowned-skull",
}
## The id segment a Void card adds to the id of the item it corrupts (demo.item.corrupted_frost_lantern → demo.item.frost_lantern).
const CORRUPTED_PREFIX: String = "corrupted_"
## An armor slot's glyph when no word of the name matched.
const SLOT_ICONS: Dictionary = {"Weapon": "broadsword", "Body": "chest-armor", "Head": "visored-helm", "Arms": "gauntlet",
	"Legs": "leg-armor", "Accessory": "ring"}


## Glyph stem → its file under `source` (the first author in AUTHOR_ORDER, then the others by name, wins). {} when the folder
## is missing.
static func index(source: String) -> Dictionary:
	var stems := {}
	var dir := DirAccess.open(source)
	if dir == null:
		return stems
	var authors: Array[String] = AUTHOR_ORDER.duplicate()
	var others := Array(dir.get_directories())
	others.sort()  # sort-ok: folder, file and glyph names are Strings
	for author in others:
		if not authors.has(author):
			authors.append(author)
	for author in authors:
		var files := DirAccess.get_files_at(source.path_join(author))
		var names := Array(files)
		names.sort()  # sort-ok: folder, file and glyph names are Strings
		for file in names:
			if file.get_extension() == "svg" and not stems.has(file.get_basename()):
				stems[file.get_basename()] = {"author": author, "path": source.path_join(author).path_join(file)}
	return stems


## One row per item and armor card, by id: {id, name, stem, author, source, by}. `by`: name, keyword, word, slot, fallback or
## twin (a Void card takes the glyph of the item it corrupts). Every other card gets a glyph no other card has: a pick already
## taken falls to the card's next candidate, and one with none left is `by` "shared" (see clashes()). Cards are picked in catalog
## order, Void cards after the rest. A stem the folder lacks is reported with an empty source.
static func propose(content: ContentIndex, source: String = DEFAULT_SOURCE) -> Array[Dictionary]:
	var stems := index(source)
	var cards: Array[Dictionary] = []
	for card in CardCatalog.cards(content):
		if card["kind"] != CardCatalog.KIND_CHARACTER:
			cards.append(card)
	var picked := {}  # id → row
	var used := {}  # stem → the id that holds it
	for void_pass in [false, true]:
		for card in cards:
			var id := String(card["id"])
			var base := twin_of(content, id)
			if (base != "") != void_pass:
				continue
			var entry: Resource = content.items.get(StringName(id))
			if entry == null:
				entry = content.equipment.get(StringName(id))
			var name: String = entry.display_name if entry.display_name != "" else id
			var slot := CardFaces.slot_name(entry.slot) if entry is EquipmentDefinition else ""
			var pick := {}
			if base != "" and picked.has(base):
				pick = {"stem": picked[base]["stem"], "by": "twin"}
			else:
				pick = _unique_pick(name, slot, stems, used)
				used[pick["stem"]] = id
			var found: Dictionary = stems.get(pick["stem"], {})
			picked[id] = {"id": id, "name": name, "stem": pick["stem"], "by": pick["by"],
				"author": str(found.get("author", "")), "source": str(found.get("path", ""))}
	var rows: Array[Dictionary] = []
	for card in cards:
		rows.append(picked[String(card["id"])])
	return rows


## The id of the item a Void card corrupts (`demo.item.corrupted_x` → `demo.item.x`), when it is a corrupted card and that item is
## a card too; else "". Only such a pair may share a glyph.
static func twin_of(content: ContentIndex, id: String) -> String:
	var entry: Resource = content.items.get(StringName(id))
	if entry == null:
		entry = content.equipment.get(StringName(id))
	if entry == null or not TagMatch.has(entry.tags, CardFaces.CORRUPTED_TAG):
		return ""
	var dot := id.rfind(".")
	var last := id.substr(dot + 1)
	if not last.begins_with(CORRUPTED_PREFIX):
		return ""
	var base := id.substr(0, dot + 1) + last.trim_prefix(CORRUPTED_PREFIX)
	return base if content.items.has(StringName(base)) or content.equipment.has(StringName(base)) else ""


## Rows whose glyph another card holds too, other than a Void card and its item: "<id> shares <stem> with <ids>" lines.
static func clashes(rows: Array[Dictionary], content: ContentIndex) -> Array[String]:
	var holders := {}
	for row in rows:
		if row["by"] != "twin":
			holders[row["stem"]] = holders.get(row["stem"], []) + [row["id"]]
	var lines: Array[String] = []
	var stems: Array[String] = []
	stems.assign(holders.keys())
	stems.sort()
	for stem in stems:
		if holders[stem].size() > 1:
			lines.append("%s is shared by %s" % [stem, ", ".join(holders[stem])])
	return lines


## The card's candidates in order (its name, then pick_icon's chain word by word, then its slot, then the fallback); the first no
## other card holds wins, else the first with `by` "shared".
static func _unique_pick(name: String, slot: String, stems: Dictionary, used: Dictionary) -> Dictionary:
	var candidates: Array[Dictionary] = []
	var whole: String = NAME_ICONS.get(name.to_lower(), "")
	if whole != "" and stems.has(whole):
		candidates.append({"stem": whole, "by": "name"})
	var words: Array[String] = []
	for found in RegEx.create_from_string("[A-Za-z]+").search_all(name):
		words.append(found.get_string().to_lower())
	words.reverse()
	for word in words:
		var stem: String = KEYWORDS.get(word, "")
		if stem != "" and stems.has(stem):
			candidates.append({"stem": stem, "by": "keyword"})
	for word in words:
		if stems.has(word):
			candidates.append({"stem": word, "by": "word"})
	if slot != "" and SLOT_ICONS.has(slot):
		candidates.append({"stem": SLOT_ICONS[slot], "by": "slot"})
	candidates.append({"stem": FALLBACK, "by": "fallback"})
	for candidate in candidates:
		if not used.has(candidate["stem"]):
			return candidate
	return {"stem": candidates[0]["stem"], "by": "shared"}


## The glyph for a card name (and armor slot): {stem, by}.
static func pick_icon(name: String, slot: String, stems: Dictionary) -> Dictionary:
	var words: Array[String] = []
	var regex := RegEx.create_from_string("[A-Za-z]+")
	for found in regex.search_all(name):
		words.append(found.get_string().to_lower())
	words.reverse()  # the last word names the thing ("Frost Lantern" is a lantern)
	for word in words:
		var stem: String = KEYWORDS.get(word, "")
		if stem != "" and stems.has(stem):
			return {"stem": stem, "by": "keyword"}
	for word in words:
		if stems.has(word):
			return {"stem": word, "by": "word"}
	if slot != "" and SLOT_ICONS.has(slot):
		return {"stem": SLOT_ICONS[slot], "by": "slot"}
	return {"stem": FALLBACK, "by": "fallback"}


## The proposal as lines for the console and the tool: one per card, the unmatched (fallback) ones last.
static func report(rows: Array[Dictionary]) -> String:
	var lines := PackedStringArray()
	var fallback := PackedStringArray()
	for row in rows:
		var line := "%-34s %-28s %s (%s)%s" % [row["id"], row["name"], row["stem"], row["by"], "" if row["source"] != "" else "  [missing]"]
		if row["by"] == "fallback":
			fallback.append(line)
		else:
			lines.append(line)
	lines.append("unmatched (the fallback glyph): %d" % fallback.size())
	lines.append_array(fallback)
	var shared := rows.filter(func(row: Dictionary) -> bool: return row["by"] == "shared")
	lines.append("shared with another card (add a NAME_ICONS entry): %d" % shared.size())
	for row in shared:
		lines.append("  %s %s (%s)" % [row["id"], row["name"], row["stem"]])
	return "\n".join(lines)


## Copies the proposed glyphs and the style glyphs into `dest` (new files only) and writes `out` (a CardArtSet text resource)
## unless it exists and `force` is false. Returns {copied, skipped, wrote, problems}. Run `godot --import` afterwards so the SVGs
## become textures.
static func apply(rows: Array[Dictionary], source: String = DEFAULT_SOURCE, dest: String = DEST_DIR,
		out: String = CardArtSet.ICONS_PATH, force: bool = false) -> Dictionary:
	var stems := index(source)
	var result := {"copied": [], "skipped": [], "wrote": "", "problems": []}
	var wanted := {}
	for row in rows:
		wanted[row["stem"]] = true
	for stem in STYLE_GLYPHS:
		wanted[stem] = true
	var paths := {}  # stem → res:// path of its copy
	var ordered := wanted.keys()
	ordered.sort()  # sort-ok: folder, file and glyph names are Strings
	for stem in ordered:
		if not stems.has(stem):
			result["problems"].append("no glyph %s in %s" % [stem, source])
			continue
		var target: String = dest.path_join(stems[stem]["author"]).path_join(stem + ".svg")
		paths[stem] = target
		if FileAccess.file_exists(target):
			result["skipped"].append(target)
			continue
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
		var error := DirAccess.copy_absolute(stems[stem]["path"], ProjectSettings.globalize_path(target))
		if error != OK:
			result["problems"].append("can't copy %s (error %d)" % [target, error])
		else:
			result["copied"].append(target)
	if FileAccess.file_exists(out) and not force:
		result["wrote"] = ""
		result["kept"] = out  # an existing set is the user's: left as it is (--force rewrites it); not a problem
		return result
	var text := _art_set_text(rows, paths)
	var file := FileAccess.open(out, FileAccess.WRITE)
	if file == null:
		result["problems"].append("can't write " + out)
		return result
	file.store_string(text)
	file.close()
	result["wrote"] = out
	return result


## A CardArtSet .tres written as text (the SVGs are not imported yet, so ResourceSaver can't hold them as textures).
static func _art_set_text(rows: Array[Dictionary], paths: Dictionary) -> String:
	var used: Array[String] = []
	for row in rows:
		if paths.has(row["stem"]) and not used.has(paths[row["stem"]]):
			used.append(paths[row["stem"]])
	used.sort()
	var lines := PackedStringArray(['[gd_resource type="Resource" script_class="CardArtSet" load_steps=%d format=3]' % (used.size() + 2), "",
		'[ext_resource type="Script" path="res://game/cards/card_art_set.gd" id="1_set"]'])
	var ids := {}
	for index in used.size():
		ids[used[index]] = "%d_icon" % (index + 2)
		lines.append('[ext_resource type="Texture2D" path="%s" id="%s"]' % [used[index], ids[used[index]]])
	lines.append("")
	lines.append("[resource]")
	lines.append('script = ExtResource("1_set")')
	var entries := PackedStringArray()
	for row in rows:
		if paths.has(row["stem"]):
			entries.append('&"%s": ExtResource("%s")' % [row["id"], ids[paths[row["stem"]]]])
	lines.append('textures = Dictionary[StringName, Texture2D]({\n%s\n})' % ",\n".join(entries))
	return "\n".join(lines) + "\n"
