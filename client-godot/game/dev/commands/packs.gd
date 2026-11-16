## Spec card-collection 2.2, 3.4a and spec pack-shop: the packs on sale with the unopened ones owned, buying packs (gems),
## opening an owned one, and the pity counters.
extends DevCommand


func _init() -> void:
	name = "packs"
	usage = "packs [buy <pack id> [count] [key] | open <pack id> [key] | refunds | pity]"
	help = "Server mode. No argument: the packs on sale (price, size, odds, pity rules) and how many unopened ones the account owns. buy <pack id> [count] [key]: spends gems for unopened packs (1 to the server's Cards:MaxPacksPerBuy, 10 by default; the server checks the count); pass the same count and key again to retry without paying twice. open <pack id> [key]: spends one owned pack and shows the cards (a duplicate becomes dust); refused with 1411 when none is owned; the same key retries. refunds: what the Open packs page does when it opens: pays back unopened packs of a type retired with a refund and says what it paid. pity: the packs since each rarity last dropped (Hearthstone-style timers: the Nth pack holds one). The account lives on the server; local mode has none."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode: packs and currency live on the server")
	var link: ServerLink = ctx.game.server
	if args.size() > 0 and args[0] == "buy":
		if args.size() < 2:
			return ctx.fail("usage: " + usage)
		var count := 1
		if args.size() > 2:
			# Only the form is checked here: the range is the server's (Cards:MaxPacksPerBuy), so an out-of-range count gets its 1401.
			if not args[2].is_valid_int():
				return ctx.fail("count must be a whole number, not '%s'" % args[2])
			count = int(args[2])
		var buy_key := args[3] if args.size() > 3 else ServerLink.new_request_key()
		var bought: Dictionary = await link.buy_pack(args[1], count, buy_key)
		if not bought["ok"]:
			return ctx.fail("POST packs/%s/buy: %s (key %s)" % [args[1], ServerLink.describe(bought["error"]), buy_key])
		var data: Dictionary = bought["data"]
		return "bought %d x %s (version %d) for %d gems; gems %d, unopened %s %d [key %s]" % [int(data["count"]), data["packId"],
			int(data["packVersion"]), int(data["gemsSpent"]), int(data["gems"]), data["packId"], int(data["owned"]), buy_key]
	if args.size() > 0 and args[0] == "open":
		if args.size() < 2:
			return ctx.fail("usage: " + usage)
		var key := args[2] if args.size() > 2 else ServerLink.new_request_key()
		var answer: Dictionary = await link.open_pack(args[1], key)
		if not answer["ok"]:
			return ctx.fail("POST packs/%s/open: %s (key %s)" % [args[1], ServerLink.describe(answer["error"]), key])
		return _describe_opening(answer["data"], key)
	if args.size() > 0 and args[0] == "refunds":
		var refunds: Dictionary = await link.refund_packs()
		if not refunds["ok"]:
			return ctx.fail("POST packs/refunds: " + ServerLink.describe(refunds["error"]))
		var paid := PackedStringArray()
		for entry in refunds["data"].get("refunded", []):
			paid.append("refunded %d x %s: +%d gems" % [int(entry["count"]), entry["packId"], int(entry["gemsRefunded"])])
		return "\n".join(paid) if not paid.is_empty() else "no refunds due"
	if args.size() > 0 and args[0] == "pity":
		var collection: Dictionary = await link.get_collection()
		if not collection["ok"]:
			return ctx.fail("GET cards/collection: " + ServerLink.describe(collection["error"]))
		var lines := PackedStringArray()
		for state in collection["data"].get("pity", []):
			var missed: Dictionary = state["missedPacks"]
			var parts := PackedStringArray()
			for rarity in missed:
				parts.append("%s %d" % [rarity, int(missed[rarity])])
			lines.append("%s: packs since %s" % [state["packId"], ", ".join(parts)])
		return "\n".join(lines) if not lines.is_empty() else "no pity timers"
	var packs: Dictionary = await link.get_packs()
	if not packs["ok"]:
		return ctx.fail("GET packs: " + ServerLink.describe(packs["error"]))
	# The owned counts are extra: without the collection the packs on sale are still listed.
	var collection: Dictionary = await link.get_collection()
	var owned := {}
	if collection["ok"]:
		for entry in collection["data"].get("ownedPacks", []):
			owned[str(entry["packId"])] = int(entry["count"])
	var lines := PackedStringArray()
	for pack in packs["data"].get("packs", []):
		var odds: Dictionary = pack["oddsPer10000"]
		var parts := PackedStringArray()
		for rarity in odds:
			parts.append("%s %.2f%%" % [rarity, int(odds[rarity]) / 100.0])
		var pity: Dictionary = pack.get("pityPacks", {})
		var pity_parts := PackedStringArray()
		for rarity in pity:
			pity_parts.append("%s %d" % [rarity, int(pity[rarity])])
		lines.append("%s: %d gems, %d cards (%s)%s%s%s" % [pack["packId"], int(pack["priceGems"]), int(pack["cardCount"]),
			", ".join(parts), "; pity " + ", ".join(pity_parts) if not pity_parts.is_empty() else "",
			"; at least a %s" % pack["minRarityPerPack"] if pack.get("minRarityPerPack") != null else "",
			"; owned %d" % int(owned.get(str(pack["packId"]), 0)) if collection["ok"] else ""])
		owned.erase(str(pack["packId"]))
	# Owned packs of a type no longer on sale still open (spec pack-shop 2.2).
	var leftover: Array = owned.keys()
	leftover.sort()   # sort-ok: String keys (str() above), console output only
	for pack_id in leftover:
		lines.append("%s: no longer sold; owned %d" % [pack_id, owned[pack_id]])
	if not collection["ok"]:
		lines.append("(owned packs unknown: GET cards/collection: %s)" % ServerLink.describe(collection["error"]))
	return "\n".join(lines) if not lines.is_empty() else "no packs on sale"


static func _describe_opening(opening: Dictionary, key: String) -> String:
	var lines := PackedStringArray(["opened %s (version %d); unopened left %d; gems %d, dust %d [key %s]" % [opening["packId"],
		int(opening["packVersion"]), int(opening.get("packsLeft", 0)), int(opening["gems"]), int(opening["dust"]), key]])
	for card in opening["cards"]:
		lines.append("  %s %s%s%s" % [card["rarity"], card["cardId"],
			"  (duplicate: +%d dust)" % int(card["dustGained"]) if card["duplicate"] else "  NEW",
			"  [pity]" if card.get("pity", false) else ""])
	return "\n".join(lines)
