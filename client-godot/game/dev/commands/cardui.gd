## Spec card-ui 6 (dev-tools parity): drives the card screens headless. `cardui open shop` opens the Shop over the main menu;
## `cardui shop` prints what it shows; `cardui shop buy <pack id> [count]` presses its Buy (through the player's CardAccount,
## one key until answered); `cardui account` shows the account action on its way, `cardui giveup` stops waiting for it and stays
## online (the pop-up's Go offline gives it up and plays offline). The Collection, card detail and Open packs arrive with their screens.
extends DevCommand

const SCREENS: Dictionary = {"shop": "res://presentation/demo/ui/cards/shop.tscn"}


func _init() -> void:
	name = "cardui"
	usage = "cardui [open shop | shop [buy <pack id> [count]] | account | giveup | look [name]]"
	help = "The card screens. open shop: opens the Shop (Menu layer; local mode shows that it needs a server). shop: the offers on screen (pack, price, owned), the gems and the message line. shop buy <pack id> [count]: presses Buy on the Shop (opened first if needed) and waits for the server's answer, reconnecting as long as it takes; count 1 or 5 like the buttons, any whole number for a test. account: the account action on its way and how long it has been reconnecting (server mode). giveup: stop waiting for it but stay online (the connecting pop-up's Go offline also gives it up, then plays offline: server go-offline). look [name]: the card face in use (CardStyle.face_scenes; the demo has one, grimoire, the user's pick), switched in memory; the card gallery shows every card in it (res://game/dev/card_gallery.tscn)."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.ui == null:
		return ctx.fail("no game UI")
	if args.is_empty():
		return ctx.fail("usage: " + usage)
	match args[0]:
		"open":
			if args.size() < 2 or not SCREENS.has(args[1]):
				return ctx.fail("usage: cardui open shop")
			if ctx.game.mode != "menu":
				return ctx.fail("the card screens open from the main menu (mode is %s)" % ctx.game.mode)
			var screen := await _open(ctx, args[1])
			if screen == null:
				return ctx.fail("could not open %s: %s" % [args[1], "; ".join(ctx.game.ui.problems)])
			return "opened %s\n%s" % [args[1], _describe(screen.shown())]
		"shop":
			var shop := _top(ctx, "shop")
			if args.size() == 1:
				if shop == null:
					return ctx.fail("the Shop is not open (cardui open shop)")
				return _describe(shop.shown())
			if args[1] != "buy" or args.size() < 3:
				return ctx.fail("usage: cardui shop buy <pack id> [count]")
			if ctx.game.server == null:
				return ctx.fail("not in server mode: packs and gems live on the server")
			var count := 1
			if args.size() > 3:
				if not args[3].is_valid_int() or int(args[3]) < 1:
					return ctx.fail("count must be a whole number of at least 1, not '%s'" % args[3])
				count = int(args[3])
			if shop == null:
				if ctx.game.mode != "menu":
					return ctx.fail("the Shop opens from the main menu (mode is %s)" % ctx.game.mode)
				shop = await _open(ctx, "shop")
				if shop == null:
					return ctx.fail("could not open the Shop")
			var pack_id := args[2]
			if shop.offer_for(pack_id).is_empty():
				return ctx.fail("no pack '%s' on sale (%s)" % [pack_id, ", ".join(shop.shown()["offers"].map(
					func(offer: Dictionary) -> String: return offer["packId"]))])
			if shop.loading:
				await shop.loaded
			if ctx.game.server.card_account().busy():
				return ctx.fail("another account action is on its way (cardui account)")
			var answer: Dictionary = await shop.buy(pack_id, count)
			if answer.is_empty():
				return ctx.fail("the Shop is busy with a buy of its own")
			var line := "%s [key %s]\n%s" % [shop.shown()["message"], answer["key"], _describe(shop.shown())]
			return line if answer.get("ok", false) else ctx.fail(line)
		"account":
			if ctx.game.server == null:
				return ctx.fail("not in server mode")
			var account := ctx.game.server.card_account()
			var action := account.in_flight()
			if action.is_empty():
				return "nothing on its way"
			if action["givenUp"]:
				return "%s %s [key %s]: given up, the last try is still out" % [action["kind"], action["target"], action["key"]]
			var since := account.reconnecting_seconds()
			return "%s %s x%d [key %s]%s" % [action["kind"], action["target"], int(action.get("count", 1)), action["key"],
				", reconnecting for %.0f s" % since if since >= 0.0 else ""]
		"giveup":
			if ctx.game.server == null:
				return ctx.fail("not in server mode")
			var account := ctx.game.server.card_account()
			if account.in_flight().is_empty() or account.in_flight()["givenUp"]:
				return ctx.fail("no account action is on its way")
			account.give_up()
			return "stopped waiting; the screens show the server's state"
		"look":
			# Spec card-ui 7 q1: switch the card face live (in memory; the style file keeps its own until the user picks).
			var style := CardStyle.current()
			var looks := ", ".join(style.face_scenes.keys().map(func(key: StringName) -> String: return String(key)))
			if args.size() < 2:
				return "look: %s (of %s)" % [style.face, looks]
			if not style.face_scenes.has(StringName(args[1])):
				return ctx.fail("no look '%s' (%s)" % [args[1], looks])
			style.face = StringName(args[1])
			return "look: %s" % style.face
	return ctx.fail("usage: " + usage)


## Pushes the screen (or finds it on top) and waits until it has loaded.
static func _open(ctx: DevContext, which: String) -> UIScreen:
	var screen := _top(ctx, which)
	if screen == null:
		screen = ctx.game.ui.push(&"UI.Layer.Menu", load(SCREENS[which]))
	if screen == null:
		return null
	if screen.loading:
		await screen.loaded
	return screen


static func _top(ctx: DevContext, which: String) -> UIScreen:
	var screen: UIScreen = ctx.game.ui.top(&"UI.Layer.Menu")
	return screen if screen != null and screen.scene_file_path == SCREENS[which] else null


static func _describe(shown: Dictionary) -> String:
	var lines := PackedStringArray(["gems %s" % (str(shown["gems"]) if int(shown["gems"]) >= 0 else "unknown")])
	for offer in shown["offers"]:
		lines.append("  %s: %d gems, %d cards, owned %s" % [offer["packId"], int(offer["price"]), int(offer["cardCount"]),
			str(offer["owned"]) if int(offer["owned"]) >= 0 else "unknown"])
	if str(shown["message"]) != "":
		lines.append("  message: %s" % shown["message"])
	return "\n".join(lines)
