## What is a card in content (spec card-collection 2.1, 3.6), read straight from the definitions' tags:
##   an item or a piece of equipment with at least one `Pool.*` tag is an item card; its rarity is `Item.Rarity.<X>`;
##   a character is a character card, always Mythic (a tier above Legendary); every card carries one `Card.Set.<Name>` tag.
## The core set is the cards whose set is `core`: owned by every account, always in the pools, never dusted or crafted.
## Pure: reads a ContentIndex, writes nothing. The server never reads item data; it receives this list (build_card_catalog).
class_name CardCatalog
extends RefCounted

const SET_PREFIX: String = "Card.Set."
const POOL_PREFIX: String = "Pool."
const RARITY_PREFIX: String = "Item.Rarity."
const CORE_SET: String = "core"
const KIND_ITEM: String = "item"
const KIND_CHARACTER: String = "character"
## Lowest to highest: the order the server's pack draw walks (Rpg.Contracts CardRarities.Order).
const RARITIES: Array[String] = ["common", "rare", "epic", "legendary", "mythic"]
const MYTHIC: String = "mythic"


## Every card of `content`, sorted by id: {"id", "kind", "rarity", "setId", "core", "pools"} (the server's CatalogFileCard).
## A card with no set tag has setId "" and a missing rarity is "" (problems() reports both).
static func cards(content: ContentIndex) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for table in [content.items, content.equipment]:
		for id in table:
			var entry: Resource = table[id]
			if TagMatch.has(entry.tags, FloorGenerator.DEV_TAG):
				continue
			var pools := _pools(entry.tags)
			if pools.is_empty():
				continue  # not in any pool: not collectible (loadout gear, event gifts, dev items)
			found.append(_card(String(id), KIND_ITEM, _rarity(entry.tags), entry.tags, pools))
	for id in content.characters:
		found.append(_card(String(id), KIND_CHARACTER, MYTHIC, content.characters[id].tags, []))
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["id"] < b["id"])
	return found


## The wire file `infra/economy/card_catalog.json` (the server's CardCatalogFile): the cards and a hash of them.
static func catalog_file(content: ContentIndex) -> Dictionary:
	var list := cards(content)
	return {"catalogHash": catalog_hash(list), "cards": list}


## SHA-256 of the canonical card list, so the server can tell a changed catalog from the same one.
static func catalog_hash(list: Array[Dictionary]) -> String:
	return StateHasher.sha256_hex(StateHasher.canonical(list))


## Ids of the item cards in the core set (what a run's pool holds before any card is collected).
static func core_item_ids(content: ContentIndex) -> Array[StringName]:
	var ids: Array[StringName] = []
	for card in cards(content):
		if card["kind"] == KIND_ITEM and card["core"]:
			ids.append(StringName(card["id"]))
	return ids


## The ids of every card in the core set, items and characters.
static func core_ids(content: ContentIndex) -> Array[StringName]:
	var ids: Array[StringName] = []
	for card in cards(content):
		if card["core"]:
			ids.append(StringName(card["id"]))
	return ids


## Problems that make the catalog unusable, as [code, id, message] triples (the validator turns them into issues). A content root
## with no CardRules resource gets none: card checks are opt-in, so older content and the fixtures are untouched.
static func problems(content: ContentIndex) -> Array:
	var found: Array = []
	if content.card_rules.is_empty():
		return found
	var rules: CardRules = content.card_rules[content.card_rules.keys()[0]]
	var core_characters: Array[StringName] = []
	for card in cards(content):
		var tags: Array[StringName] = _tags_of(content, card)
		var sets := _sets(tags)
		if sets.is_empty():
			found.append(["card_set_missing", card["id"], "%s is a card but has no %s<Name> tag" % [card["id"], SET_PREFIX]])
		elif sets.size() > 1:
			found.append(["card_set_unknown", card["id"], "%s has %d set tags (%s); a card is in one set" % [card["id"], sets.size(),
				", ".join(sets)]])
		if card["kind"] == KIND_ITEM and card["rarity"] == "":
			found.append(["card_rarity_missing", card["id"], "%s has no %s<X> tag" % [card["id"], RARITY_PREFIX]])
		if card["kind"] == KIND_ITEM and card["rarity"] == MYTHIC:
			found.append(["card_rarity_mismatch", card["id"], "%s is an item and cannot be Mythic (characters only)" % card["id"]])
		if card["kind"] == KIND_CHARACTER and card["core"]:
			core_characters.append(StringName(card["id"]))
	core_characters.sort()
	var starters := rules.starter_characters.duplicate()
	starters.sort()
	if core_characters != starters:
		found.append(["core_character_count", "", "the core characters are %s, the starter characters are %s" % [core_characters, starters]])
	for pool in _used_pools(content):
		var has_core := false
		for card in cards(content):
			if card["kind"] == KIND_ITEM and card["core"] and card["pools"].has(String(pool)):
				has_core = true
				break
		if not has_core:
			found.append(["core_pool_empty", String(pool), "%s has no core card: a new account would find the pool empty" % pool])
	return found


## Pool → [core count, target] for every pool with a target, to report how far the core set is from each (spec 3.6).
static func pool_counts(content: ContentIndex) -> Dictionary:
	var counts := {}
	if content.card_rules.is_empty():
		return counts
	var rules: CardRules = content.card_rules[content.card_rules.keys()[0]]
	for pool in rules.pool_targets:
		var held := 0
		for card in cards(content):
			if card["kind"] == KIND_ITEM and card["core"] and card["pools"].has(String(pool)):
				held += 1
		counts[String(pool)] = [held, int(rules.pool_targets[pool])]
	return counts


# --- internals ----------------------------------------------------------------------------------------------------------

static func _card(id: String, kind: String, rarity: String, tags: Array[StringName], pools: Array[String]) -> Dictionary:
	var sets := _sets(tags)
	var set_id: String = sets[0] if not sets.is_empty() else ""
	return {"id": id, "kind": kind, "rarity": rarity, "setId": set_id, "core": set_id == CORE_SET, "pools": pools}


## The pool tags of a tag list, sorted, as strings.
static func _pools(tags: Array[StringName]) -> Array[String]:
	var pools: Array[String] = []
	for tag in tags:
		if String(tag).begins_with(POOL_PREFIX):
			pools.append(String(tag))
	pools.sort()
	return pools


static func _rarity(tags: Array[StringName]) -> String:
	for tag in tags:
		if String(tag).begins_with(RARITY_PREFIX):
			return String(tag).trim_prefix(RARITY_PREFIX).to_lower()
	return ""


## The set names in the tags, lowercase ("Card.Set.Descent" → "descent").
static func _sets(tags: Array[StringName]) -> Array[String]:
	var sets: Array[String] = []
	for tag in tags:
		if String(tag).begins_with(SET_PREFIX):
			sets.append(String(tag).trim_prefix(SET_PREFIX).to_lower())
	return sets


static func _tags_of(content: ContentIndex, card: Dictionary) -> Array[StringName]:
	var id := StringName(card["id"])
	if card["kind"] == KIND_CHARACTER:
		return content.characters[id].tags
	var entry: Resource = content.items.get(id)
	if entry == null:
		entry = content.equipment.get(id)
	return entry.tags


## Every room pool tag some card carries.
static func _used_pools(content: ContentIndex) -> Array[StringName]:
	var seen := {}
	for card in cards(content):
		for pool in card["pools"]:
			seen[pool] = true
	var pools: Array[StringName] = []
	for pool in seen:
		pools.append(StringName(pool))
	pools.sort()
	return pools
