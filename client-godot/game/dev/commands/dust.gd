## Spec card-collection 2.3: dust a card for the flat rate. Refused while the active run was built from it.
extends DevCommand


func _init() -> void:
	name = "dust"
	usage = "dust <card id|first> [key]"
	help = "Server mode. Removes the card from the account for dust at the rarity's flat rate. A card you owned when the active run started is locked until the run ends (409 1403: the answer names the run; `abandon` cancels it). Pass the same key again to retry without paying twice."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode: cards and dust live on the server")
	if args.is_empty():
		return ctx.fail("usage: " + usage)
	var key := args[1] if args.size() > 1 else ServerLink.new_request_key()
	var card_id := args[0]
	if card_id == "first":  # a script does not know which card a pack gave it: the first one in the collection
		var collection: Dictionary = await ctx.game.server.get_collection()
		if not collection["ok"] or collection["data"]["owned"].is_empty():
			return ctx.fail("no collected card to dust")
		card_id = str(collection["data"]["owned"][0]["cardId"])
	var answer: Dictionary = await ctx.game.server.dust_card(card_id, key)
	if not answer["ok"]:
		var error: Dictionary = answer["error"]
		if int(error.get("errorCode", 0)) == 1403:
			return ctx.fail("locked (1403): run %s (%s) was built from %s; `abandon` cancels it (key %s)" % [error.get("runId", "?"),
				error.get("runStatus", "?"), card_id, key])
		return ctx.fail("POST cards/%s/dust: %s (key %s)" % [card_id, ServerLink.describe(error), key])
	var data: Dictionary = answer["data"]
	return "dusted %s: +%d dust (rate version %d), dust now %d [key %s]" % [data["cardId"], int(data["dustGained"]),
		int(data["rateVersion"]), int(data["dust"]), key]
