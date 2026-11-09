## Spec card-collection 2.4: craft a card for dust.
extends DevCommand


func _init() -> void:
	name = "craft"
	usage = "craft <card id> [key]"
	help = "Server mode. Spends dust on a card the account does not own (any set, any rarity; not core). Allowed during a run: a card acquired after the run started never affects it. Pass the same key again to retry without paying twice."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode: cards and dust live on the server")
	if args.is_empty():
		return ctx.fail("usage: " + usage)
	var key := args[1] if args.size() > 1 else ServerLink.new_request_key()
	var answer: Dictionary = await ctx.game.server.craft_card(args[0], key)
	if not answer["ok"]:
		return ctx.fail("POST cards/%s/craft: %s (key %s)" % [args[0], ServerLink.describe(answer["error"]), key])
	var data: Dictionary = answer["data"]
	return "crafted %s for %d dust (rate version %d), dust now %d [key %s]" % [data["cardId"], int(data["dustSpent"]),
		int(data["rateVersion"]), int(data["dust"]), key]
