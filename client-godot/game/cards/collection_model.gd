## Spec card-ui 3.3: what the Collection shows (pure, testable headless): the card faces × the server's CollectionResponse (or the
## local test pool) × the catalog's rates × the NEW set → one entry per card with its state, then filters, Hearthstone's sort
## (characters first, then rarity, then name) and pages (12 on the Collection: 6 x 2 since the playtest of 2026-11-18). The screen
## draws the entries; it never decides ownership itself.
##
## Ownership has three sources (spec card-ui 2.1 and account-session 2.3):
##   - a collection (server mode, with a session): owned = core + the collection's `owned`; a card the active run holds is locked;
##   - the local test pool (local mode): owned = core + the pool, read-only;
##   - neither (server mode with no session or no answer): ownership is unknown, nothing shows as owned or missing.
class_name CollectionModel
extends RefCounted

## The default page size (the screen passes its own: columns x rows).
const PER_PAGE: int = 12
const STATE_OWNED: String = "owned"
const STATE_MISSING: String = "missing"
const STATE_CORE: String = "core"
const STATE_UNKNOWN: String = "unknown"
const KIND_ORDER: Array[String] = [CardFace.KIND_CHARACTER, CardFace.KIND_ITEM, CardFace.KIND_EQUIPMENT]


## The default filters: everything shown.
static func default_filters() -> Dictionary:
	return {"set": "all", "kind": "all", "rarities": CardStyle.RARITY_ORDER.duplicate(), "pool": "", "owned": true,
		"missing": true, "text": ""}


## One entry per card: {id, face, state, locked, new, dust, craft, retired}. `collection` is a CollectionResponse (or null),
## `local_owned` the local test pool's ids (an Array, or null), `rates` card id → {dustValue, craftCost, retired} from the
## server's catalog, `seen` the NEW set (id → true). A retired card shows only while it is owned (it can no longer be crafted).
static func entries(faces: Array, collection: Variant, seen: Dictionary, rates: Dictionary = {},
		local_owned: Variant = null) -> Array[Dictionary]:
	var owned := {}
	var locked := {}
	var known := collection is Dictionary or local_owned is Array
	if collection is Dictionary:
		var active_run: Variant = collection.get("activeRunId")
		for card in collection.get("owned", []):
			var id := str(card.get("cardId", ""))
			owned[id] = true
			var holder: Variant = card.get("lockedByRunId")
			if holder != null and str(holder) != "" and (active_run == null or str(holder) == str(active_run)):
				locked[id] = true
	elif local_owned is Array:
		for id in local_owned:
			owned[str(id)] = true
	var result: Array[Dictionary] = []
	for face in faces:
		if not face is CardFace:
			continue
		var rate: Dictionary = rates.get(face.id, {})
		var retired := bool(rate.get("retired", false))
		var state := STATE_UNKNOWN
		if face.core:
			state = STATE_CORE
		elif known:
			state = STATE_OWNED if owned.has(face.id) else STATE_MISSING
		if retired and state != STATE_OWNED:
			continue
		result.append({"id": face.id, "face": face, "state": state, "locked": locked.has(face.id),
			"new": state == STATE_OWNED and not seen.has(face.id), "dust": int(rate.get("dustValue", 0)),
			"craft": int(rate.get("craftCost", 0)), "retired": retired})
	return result


## True when the entry counts as the player's (owned or core).
static func is_owned(entry: Dictionary) -> bool:
	return entry["state"] == STATE_OWNED or entry["state"] == STATE_CORE


## The entries the filters let through, sorted (characters first, then rarity lowest first, then name).
static func filtered(all: Array[Dictionary], filters: Dictionary) -> Array[Dictionary]:
	var set_id := str(filters.get("set", "all"))
	var kind := str(filters.get("kind", "all"))
	var rarities: Array = filters.get("rarities", CardStyle.RARITY_ORDER)
	var pool := str(filters.get("pool", ""))
	var show_owned := bool(filters.get("owned", true))
	var show_missing := bool(filters.get("missing", true))
	var text := str(filters.get("text", "")).strip_edges().to_lower()
	var result: Array[Dictionary] = []
	for entry in all:
		var face: CardFace = entry["face"]
		if set_id != "all" and face.set_id != set_id:
			continue
		if kind != "all" and face.kind != kind:
			continue
		if not rarities.has(face.rarity):
			continue
		if pool != "" and not face.pools.has(pool):
			continue
		if entry["state"] != STATE_UNKNOWN and not (show_owned if is_owned(entry) else show_missing):
			continue
		if text != "" and not (face.name + " " + face.text + " " + face.type_line).to_lower().contains(text):
			continue
		result.append(entry)
	result.sort_custom(_before)
	return result


static func _before(a: Dictionary, b: Dictionary) -> bool:
	var fa: CardFace = a["face"]
	var fb: CardFace = b["face"]
	var kind_a := KIND_ORDER.find(fa.kind)
	var kind_b := KIND_ORDER.find(fb.kind)
	if kind_a != kind_b:
		return kind_a < kind_b
	var rarity_a := CardStyle.RARITY_ORDER.find(fa.rarity)
	var rarity_b := CardStyle.RARITY_ORDER.find(fb.rarity)
	if rarity_a != rarity_b:
		return rarity_a < rarity_b
	var by_name := fa.name.naturalnocasecmp_to(fb.name)
	return by_name < 0 if by_name != 0 else fa.id < fb.id


static func page_count(list: Array, per_page: int = PER_PAGE) -> int:
	return maxi(1, ceili(list.size() / float(maxi(per_page, 1))))


## The entries of page `index` (clamped into range).
static func page(list: Array[Dictionary], index: int, per_page: int = PER_PAGE) -> Array[Dictionary]:
	var start := clampi(index, 0, page_count(list, per_page) - 1) * per_page
	return list.slice(start, start + per_page)


## The sets, kinds and pools the faces use, for the filter controls: {sets: [set ids in first-seen order], pools: [sorted]}.
static func facets(faces: Array) -> Dictionary:
	var sets: Array[String] = []
	var pools: Array[String] = []
	for face in faces:
		if not face is CardFace:
			continue
		if face.set_id != "" and not sets.has(face.set_id):
			sets.append(face.set_id)
		for pool in face.pools:
			if not pools.has(pool):
				pools.append(pool)
	pools.sort()
	return {"sets": sets, "pools": pools}


## The owned and total counts of `all` (core cards count as owned), for the side window.
static func counts(all: Array[Dictionary]) -> Dictionary:
	var owned := 0
	for entry in all:
		if is_owned(entry):
			owned += 1
	return {"owned": owned, "total": all.size()}


## Catalog rows (CatalogResponse.cards) → card id → {dustValue, craftCost, retired}.
static func rates_of(catalog: Variant) -> Dictionary:
	var rates := {}
	if catalog is Dictionary:
		for card in catalog.get("cards", []):
			rates[str(card.get("id", ""))] = {"dustValue": int(card.get("dustValue", 0)), "craftCost": int(card.get("craftCost", 0)),
				"retired": bool(card.get("retired", false))}
	return rates
