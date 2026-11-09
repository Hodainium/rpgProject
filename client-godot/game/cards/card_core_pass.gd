## Proposes the core set for a content root (spec card-collection 3.6, "Core selection"). Deterministic, reads only:
##   - characters: the rules' starter characters are core, the rest belong to the expansion set;
##   - items whose every pool is plain (no target, not all-core: Food, Chest) are core, so those pools are never empty;
##   - items in an all-core pool (Boss, Void) are core, whatever their rarity;
##   - then, until every target pool is met: the remaining items that belong to at least one short pool are taken by
##     (rarity ascending, short pools they belong to descending, id ascending). An item counts in every pool it carries,
##     so a pool can overshoot; the proposal reports it.
## The proposal names a set tag per card (`Card.Set.Core`, or the expansion's). Applying it to the user's files is a separate,
## explicit step (`apply`), never done by `propose`.
class_name CardCorePass
extends RefCounted

const CORE_TAG: StringName = &"Card.Set.Core"


## {"tags": {id: set tag}, "core_items": [...], "core_characters": [...], "counts": {pool: [core count, target]},
##  "short": [pools under their target], "overshoot": {pool: surplus}}. Cards already carrying a set tag are left as they are
## (their tag is reported as is), so a second run proposes nothing new.
static func propose(content: ContentIndex, expansion_tag: StringName = &"Card.Set.Descent") -> Dictionary:
	var rules: CardRules = null
	if not content.card_rules.is_empty():
		rules = content.card_rules[content.card_rules.keys()[0]]
	var targets: Dictionary = rules.pool_targets if rules != null else {}
	var all_core: Array[StringName] = rules.all_core_pools if rules != null else []
	var tags := {}
	var core_items: Dictionary = {}
	var items: Array[Dictionary] = []
	for card in CardCatalog.cards(content):
		if card["kind"] == CardCatalog.KIND_CHARACTER:
			tags[card["id"]] = CORE_TAG if rules != null and rules.starter_characters.has(StringName(card["id"])) else expansion_tag
		else:
			items.append(card)
	for card in items:
		if _is_plain(card, targets, all_core) or _in_any(card, all_core):
			core_items[card["id"]] = true

	var counts := _counts(items, core_items, targets)
	var guard := items.size() + 1
	while guard > 0:
		guard -= 1
		var pick := _next(items, core_items, counts, targets)
		if pick.is_empty():
			break
		core_items[pick["id"]] = true
		counts = _counts(items, core_items, targets)
	for card in items:
		tags[card["id"]] = CORE_TAG if core_items.has(card["id"]) else expansion_tag
	# Cards that already carry a set keep it.
	for card in CardCatalog.cards(content):
		if card["setId"] != "":
			tags[card["id"]] = StringName(CardCatalog.SET_PREFIX + String(card["setId"]).capitalize())
	var report := {}
	var short: Array[String] = []
	var overshoot := {}
	for pool in counts:
		report[pool] = [counts[pool], int(targets[StringName(pool)])]
		if counts[pool] < int(targets[StringName(pool)]):
			short.append(pool)
		elif counts[pool] > int(targets[StringName(pool)]):
			overshoot[pool] = counts[pool] - int(targets[StringName(pool)])
	short.sort()
	var ids: Array = core_items.keys()
	ids.sort()
	var starters: Array = []
	if rules != null:
		for id in rules.starter_characters:
			starters.append(String(id))
	return {"tags": tags, "core_items": ids, "core_characters": starters, "counts": report, "short": short, "overshoot": overshoot}


## Appends each proposed set tag to its definition file with a text patch of the one `tags = …` line (a file without one gets the
## line), so nothing else in the file moves. Only for cards that have no set tag yet. Returns the paths changed.
## This edits the user's design files: the caller (build_card_pass --apply) runs only after the user's go-ahead.
static func apply(content: ContentIndex, proposal: Dictionary) -> Array[String]:
	var changed: Array[String] = []
	for id in proposal["tags"]:
		var resource: Resource = _definition(content, StringName(id))
		if resource == null:
			continue
		var has_set := false
		for tag in resource.tags:
			has_set = has_set or String(tag).begins_with(CardCatalog.SET_PREFIX)
		if has_set or resource.resource_path == "" or not resource.resource_path.begins_with("res://") and not resource.resource_path.begins_with("user://"):
			continue
		if _patch(resource.resource_path, String(proposal["tags"][id])):
			changed.append(resource.resource_path)
	changed.sort()
	return changed


# --- internals ----------------------------------------------------------------------------------------------------------

static func _definition(content: ContentIndex, id: StringName) -> Resource:
	for table in [content.items, content.equipment, content.characters]:
		if table.has(id):
			return table[id]
	return null


static func _patch(path: String, tag: String) -> bool:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return false
	var lines := text.split("\n")
	for index in lines.size():
		var line: String = lines[index]
		if line.begins_with("tags = Array[StringName]([") and line.ends_with("])"):
			var inner := line.trim_prefix("tags = Array[StringName]([").trim_suffix("])")
			lines[index] = "tags = Array[StringName]([%s&\"%s\"])" % [inner + ", " if inner != "" else "", tag]
			return _write(path, "\n".join(lines))
	# No tags line: add one at the end of the resource section.
	var out := text.rstrip("\n") + "\ntags = Array[StringName]([&\"%s\"])\n" % tag
	return _write(path, out)


static func _write(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	return true


static func _in_any(card: Dictionary, pools: Array[StringName]) -> bool:
	for pool in pools:
		if card["pools"].has(String(pool)):
			return true
	return false


## Every pool of the card is neither a target nor all-core (Food, Chest): the card is core so those pools are never empty.
static func _is_plain(card: Dictionary, targets: Dictionary, all_core: Array[StringName]) -> bool:
	for pool in card["pools"]:
		if targets.has(StringName(pool)) or all_core.has(StringName(pool)):
			return false
	return true


static func _counts(items: Array[Dictionary], core_items: Dictionary, targets: Dictionary) -> Dictionary:
	var counts := {}
	for pool in targets:
		counts[String(pool)] = 0
	for card in items:
		if core_items.has(card["id"]):
			for pool in card["pools"]:
				if counts.has(pool):
					counts[pool] += 1
	return counts


## The next item to make core: not core yet, in at least one short target pool; lowest rarity, then most short pools, then id.
static func _next(items: Array[Dictionary], core_items: Dictionary, counts: Dictionary, targets: Dictionary) -> Dictionary:
	var best := {}
	var best_key: Array = []
	for card in items:
		if core_items.has(card["id"]):
			continue
		var short_pools := 0
		for pool in card["pools"]:
			if counts.has(pool) and counts[pool] < int(targets[StringName(pool)]):
				short_pools += 1
		if short_pools == 0:
			continue
		var key := [CardCatalog.RARITIES.find(card["rarity"]), -short_pools, card["id"]]
		if best.is_empty() or _less(key, best_key):
			best = card
			best_key = key
	return best


static func _less(a: Array, b: Array) -> bool:
	for index in a.size():
		if a[index] != b[index]:
			return a[index] < b[index]
	return false
