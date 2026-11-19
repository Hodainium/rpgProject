## Spec card-ui 2.3: what the Open packs column shows, from the server's PackListResponse and CollectionResponse (pure, testable
## headless): each pack type the account holds unopened packs of, with its count, the pity countdowns ("Epic in 3": PityPacks -
## missed) and the odds in rarity order. Packs held for a support check (refundHeld) are left out, as on the main menu.
class_name OpenPacksModel
extends RefCounted


## Entries in the server's pack order, then pack types the list no longer carries (an owned pack of a retired type still opens).
## Each: {packId, name, count, pity: [{rarity, left}], odds: [{rarity, per10000}], minRarity}.
static func entries(packs: Variant, collection: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not collection is Dictionary:
		return result
	var owned := {}
	var order: Array[String] = []
	for entry in collection.get("ownedPacks", []):
		if entry.get("refundHeld", false) or int(entry.get("count", 0)) <= 0:
			continue
		var id := str(entry["packId"])
		owned[id] = int(entry["count"])
		order.append(id)
	var missed := {}   # pack id → its counters; none yet = a first open (the server starts it at pity - first guarantee)
	for row in collection.get("pity", []):
		missed[str(row["packId"])] = row.get("missedPacks", {})
	var types := {}
	var type_order: Array[String] = []
	if packs is Dictionary:
		for pack in packs.get("packs", []):
			types[str(pack["packId"])] = pack
			type_order.append(str(pack["packId"]))
	var ids: Array[String] = []
	for id in type_order:
		if owned.has(id):
			ids.append(id)
	for id in order:
		if not ids.has(id):
			ids.append(id)
	for id in ids:
		var pack: Dictionary = types.get(id, {})
		var pity: Array[Dictionary] = []
		var odds: Array[Dictionary] = []
		var pity_in: Dictionary = pack.get("pityPacks", {})
		var odds_in: Dictionary = pack.get("oddsPer10000", {})
		var first_in: Dictionary = pack.get("firstGuarantees", {})
		var first_open := not missed.has(id)
		var missed_in: Dictionary = missed.get(id, {})
		for rarity in CardStyle.RARITY_ORDER:
			if pity_in.has(rarity) and int(pity_in[rarity]) > 0:
				var packs_in := int(pity_in[rarity])
				var already := int(missed_in.get(rarity, 0))
				if first_open and int(first_in.get(rarity, 0)) > 0:
					already = maxi(packs_in - int(first_in[rarity]), 0)   # PackDrawer.InitialMissed
				pity.append({"rarity": rarity, "left": maxi(packs_in - already, 1)})
			if odds_in.has(rarity) and int(odds_in[rarity]) > 0:
				odds.append({"rarity": rarity, "per10000": int(odds_in[rarity])})
		result.append({"packId": id, "name": str(pack.get("name", readable_name(id))), "count": int(owned[id]), "pity": pity, "odds": odds,
			"minRarity": str(pack["minRarityPerPack"]) if pack.get("minRarityPerPack") != null else ""})
	return result


## A pack type's name when the server's list no longer carries it (a retired type: GET /packs leaves those out): its look's label,
## else the id made readable ("descent-pack" → "Descent Pack").
static func readable_name(pack_id: String) -> String:
	var look: CardPackLook = CardStyle.current().pack_looks.get(StringName(pack_id))   # its own look only, not the default's
	if look != null and look.label != "":
		return look.label
	return " ".join(Array(pack_id.replace("_", "-").split("-", false)).map(func(word: String) -> String: return word.capitalize()))


## The pity line: "Epic in 3 · Legendary in 12 · Mythic in 18 packs" (`entry` from entries()); "" when the pack has no pity.
static func pity_line(entry: Dictionary, part: String = "%s in %d", tail: String = " packs") -> String:
	var parts := PackedStringArray()
	for row in entry.get("pity", []):
		parts.append(part % [str(row["rarity"]).capitalize(), int(row["left"])])
	return " · ".join(parts) + tail if not parts.is_empty() else ""


## The odds as text lines ("Common 72.10%").
static func odds_lines(entry: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	for row in entry.get("odds", []):
		lines.append("%s %s" % [str(row["rarity"]).capitalize(), ShopModel.percent(int(row["per10000"]))])
	return lines
