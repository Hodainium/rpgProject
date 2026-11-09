## Spec card-collection 2.2, 3.4a: the packs on sale, opening one (spends gems on the server), and the pity counters.
extends DevCommand


func _init() -> void:
	name = "packs"
	usage = "packs [open <pack id> [key] | pity]"
	help = "Server mode. No argument: the packs on sale (price, size, odds, pity rules). open <pack id> [key]: spends the pack's gems and shows the cards (a duplicate becomes dust); pass the same key again to retry without paying twice. pity: the packs since each rarity last dropped (Hearthstone-style timers: the Nth pack holds one). The account lives on the server; local mode has none."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode: packs and currency live on the server")
	var link: ServerLink = ctx.game.server
	if args.size() > 0 and args[0] == "open":
		if args.size() < 2:
			return ctx.fail("usage: " + usage)
		var key := args[2] if args.size() > 2 else ServerLink.new_request_key()
		var answer: Dictionary = await link.open_pack(args[1], key)
		if not answer["ok"]:
			return ctx.fail("POST packs/%s/open: %s (key %s)" % [args[1], ServerLink.describe(answer["error"]), key])
		return _describe_opening(answer["data"], key)
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
		lines.append("%s: %d gems, %d cards (%s)%s%s" % [pack["packId"], int(pack["priceGems"]), int(pack["cardCount"]),
			", ".join(parts), "; pity " + ", ".join(pity_parts) if not pity_parts.is_empty() else "",
			"; at least a %s" % pack["minRarityPerPack"] if pack.get("minRarityPerPack") != null else ""])
	return "\n".join(lines) if not lines.is_empty() else "no packs on sale"


static func _describe_opening(opening: Dictionary, key: String) -> String:
	var lines := PackedStringArray(["opened %s (version %d) for %d gems; gems %d, dust %d [key %s]" % [opening["packId"],
		int(opening["packVersion"]), int(opening["gemsSpent"]), int(opening["gems"]), int(opening["dust"]), key]])
	for card in opening["cards"]:
		lines.append("  %s %s%s%s" % [card["rarity"], card["cardId"],
			"  (duplicate: +%d dust)" % int(card["dustGained"]) if card["duplicate"] else "  NEW",
			"  [pity]" if card.get("pity", false) else ""])
	return "\n".join(lines)
