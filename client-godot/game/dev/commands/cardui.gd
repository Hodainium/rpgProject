## Spec card-ui 6 (dev-tools parity): drives the card screens headless. `cardui open shop` opens the Shop over the main menu;
## `cardui shop` prints what it shows; `cardui shop buy <pack id> [count]` presses its Buy (through the player's CardAccount,
## one key until answered); `cardui account` shows the account action on its way, `cardui giveup` stops waiting for it and stays
## online (the pop-up's Go offline gives it up and plays offline). The Collection, card detail and Open packs arrive with their screens.
extends DevCommand

const SCREENS: Dictionary = {"shop": "res://presentation/demo/ui/cards/shop.tscn",
	"collection": "res://presentation/demo/ui/cards/collection.tscn"}
const DETAIL: String = "res://presentation/demo/ui/cards/card_detail.tscn"
const FILTERS: Array[String] = ["set", "kind", "rarity", "pool", "owned", "missing", "text"]


func _init() -> void:
	name = "cardui"
	usage = "cardui [open shop|collection|detail <card id> | shop [buy <pack id> [count]] | collection | page <n> | filter <field> <value> | detail [dust|create] | bench [rarity] [seconds] | account | giveup | look [name]]"
	help = "The card screens. open shop: opens the Shop (Menu layer; local mode shows that it needs a server). shop: the offers on screen (pack, price, owned), the gems and the message line. shop buy <pack id> [count]: presses Buy on the Shop (opened first if needed) and waits for the server's answer, reconnecting as long as it takes; count 1 or 5 like the buttons, any whole number for a test. account: the account action on its way and how long it has been reconnecting (server mode). giveup: stop waiting for it but stay online (the connecting pop-up's Go offline also gives it up, then plays offline: server go-offline). open collection: the Collection (local mode: the core set and the local test pool, read-only). open detail <card id>: the card's detail over the Collection. collection: what the Collection shows (page, cards and their states, dust, gems, message). page <n>: turn to page n. filter <field> <value>: set, kind (all, character, item, equipment), rarity (all, or a list like epic,legendary), pool (any or a pool), owned / missing (on, off), text (a search; - clears). detail: what the open detail shows; detail dust / detail create press its button (the confirm and run-lock pop-ups are answered with ui press). bench [rarity] [seconds]: a full page of cards (12) of that rarity (default mythic, repeated when the content has fewer) and the frame time over that many seconds (default 5) with vsync off, against an empty page (spec 3.3: faces render live, no cache). look [name]: the card face in use (CardStyle.face_scenes; the demo has one, grimoire, the user's pick), switched in memory; the card gallery shows every card in it (res://game/dev/card_gallery.tscn)."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.ui == null:
		return ctx.fail("no game UI")
	if args.is_empty():
		return ctx.fail("usage: " + usage)
	match args[0]:
		"open":
			if args.size() < 2 or not (SCREENS.has(args[1]) or args[1] == "detail"):
				return ctx.fail("usage: cardui open shop|collection|detail <card id>")
			if ctx.game.mode != "menu":
				return ctx.fail("the card screens open from the main menu (mode is %s)" % ctx.game.mode)
			if args[1] == "detail":
				if args.size() < 3:
					return ctx.fail("usage: cardui open detail <card id>")
				var holder := await _open(ctx, "collection")
				if holder == null:
					return ctx.fail("could not open the Collection")
				if holder.entry_for(args[2]).is_empty():
					return ctx.fail("no card '%s' in the Collection" % args[2])
				var detail: UIScreen = holder.open_detail(args[2])
				if detail == null:
					return ctx.fail("could not open the detail of %s" % args[2])
				return "opened detail %s\n%s" % [args[2], JSON.stringify(detail.shown())]
			var screen := await _open(ctx, args[1])
			if screen == null:
				return ctx.fail("could not open %s: %s" % [args[1], "; ".join(ctx.game.ui.problems)])
			if args[1] == "collection":
				return "opened collection\n%s" % _describe_collection(screen.shown())
			return "opened %s\n%s" % [args[1], _describe(screen.shown())]
		"collection":
			var shown_collection := _top(ctx, "collection")
			if shown_collection == null:
				return ctx.fail("the Collection is not open (cardui open collection)")
			if shown_collection.loading:
				await shown_collection.loaded
			return _describe_collection(shown_collection.shown())
		"page":
			var paged := _top(ctx, "collection")
			if paged == null:
				return ctx.fail("the Collection is not open (cardui open collection)")
			if args.size() < 2 or not args[1].is_valid_int():
				return ctx.fail("usage: cardui page <n>")
			paged.go_to_page(int(args[1]) - 1)
			return _describe_collection(paged.shown())
		"filter":
			var filtered := _top(ctx, "collection")
			if filtered == null:
				return ctx.fail("the Collection is not open (cardui open collection)")
			if args.size() < 3 or not FILTERS.has(args[1]):
				return ctx.fail("usage: cardui filter %s <value>" % "|".join(FILTERS))
			var problem := _filter(filtered, args[1], " ".join(args.slice(2)))
			if problem != "":
				return ctx.fail(problem)
			return _describe_collection(filtered.shown())
		"detail":
			var open_detail: UIScreen = ctx.game.ui.top(&"UI.Layer.Modal")
			if open_detail == null or open_detail.scene_file_path != DETAIL:
				return ctx.fail("no card detail is open (cardui open detail <card id>)")
			if args.size() == 1:
				return JSON.stringify(open_detail.shown())
			if not args[1] in ["dust", "create"]:
				return ctx.fail("usage: cardui detail [dust|create]")
			if ctx.game.server == null:
				return ctx.fail("not in server mode: dust and cards live on the server")
			var before: Dictionary = open_detail.shown()
			if not before["dust_enabled" if args[1] == "dust" else "create_enabled"]:
				return ctx.fail("%s is not possible on this card now: %s" % [args[1], JSON.stringify(before)])
			var answer: Dictionary
			if args[1] == "dust":
				answer = await open_detail.dust()
			else:
				answer = await open_detail.create()
			if answer.is_empty():
				return ctx.fail(args[1] + " was not sent (cancelled)")
			var text := "%s: %s" % [args[1], JSON.stringify(open_detail.shown()) if is_instance_valid(open_detail) else ""]
			return text if answer.get("ok", false) else ctx.fail(text)
		"bench":
			if ctx.game.mode != "menu":
				return ctx.fail("the bench opens the Collection from the main menu (mode is %s)" % ctx.game.mode)
			var rarity := args[1] if args.size() > 1 else "mythic"
			var seconds := float(args[2]) if args.size() > 2 and args[2].is_valid_float() else 5.0
			if not CardStyle.RARITY_ORDER.has(rarity):
				return ctx.fail("no rarity '%s' (%s)" % [rarity, ", ".join(CardStyle.RARITY_ORDER)])
			var benched := await _open(ctx, "collection")
			if benched == null:
				return ctx.fail("could not open the Collection")
			return await _bench(ctx, benched, rarity, seconds)
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


static func _describe_collection(shown: Dictionary) -> String:
	var lines := PackedStringArray(["page %d / %d, %d cards, dust %s, gems %s, actions %s" % [int(shown["page"]), int(shown["pages"]),
		int(shown["count"]), str(shown["dust"]) if int(shown["dust"]) >= 0 else "unknown",
		str(shown["gems"]) if int(shown["gems"]) >= 0 else "unknown", "on" if shown["actions"] else "off"]])
	for card in shown["cards"]:
		lines.append("  %s (%s): %s%s%s" % [card["id"], card["rarity"], card["state"], ", in your run" if card["locked"] else "",
			", NEW" if card["new"] else ""])
	if str(shown["message"]) != "":
		lines.append("  message: %s" % shown["message"])
	return "\n".join(lines)


## One filter of the Collection from the console; "" or the problem.
static func _filter(screen: UIScreen, field: String, value: String) -> String:
	match field:
		"rarity":
			var wanted: Array = CardStyle.RARITY_ORDER.duplicate() if value == "all" else Array(value.split(",", false))
			for rarity in wanted:
				if not CardStyle.RARITY_ORDER.has(rarity):
					return "no rarity '%s' (%s, or all)" % [rarity, ", ".join(CardStyle.RARITY_ORDER)]
			screen.set_filter("rarities", wanted)
		"owned", "missing":
			if not value in ["on", "off"]:
				return "%s takes on or off" % field
			screen.set_filter(field, value == "on")
		"pool":
			screen.set_filter("pool", "" if value == "any" else value)
		"text":
			screen.set_filter("text", "" if value == "-" else value)
		"kind":
			if not value in ["all", CardFace.KIND_CHARACTER, CardFace.KIND_ITEM, CardFace.KIND_EQUIPMENT]:
				return "kind is all, character, item or equipment"
			screen.set_filter("kind", value)
		_:
			screen.set_filter(field, value)
	return ""


## Spec card-ui 3.3: the frame time of a full page of cards of `rarity` against an empty page, vsync off while it measures.
static func _bench(ctx: DevContext, screen: UIScreen, rarity: String, seconds: float) -> String:
	var cards: Array[Dictionary] = []
	for entry in screen.all_entries:
		if entry["face"].rarity == rarity:
			cards.append(entry)
	if cards.is_empty():
		return ctx.fail("no %s card in the Collection" % rarity)
	var page: Array[Dictionary] = []
	while page.size() < screen.per_page():
		var copy: Dictionary = cards[page.size() % cards.size()].duplicate()
		copy["id"] = "%s#%d" % [copy["id"], page.size()]
		page.append(copy)
	var tree := ctx.game.get_tree()
	var page_node: CardPage = screen.get_node("%Page")
	var vsync := DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var empty: Array[Dictionary] = []
	page_node.show_entries(empty, screen.style, screen.style.face_scene())
	var base := await _measure(tree, seconds)
	page_node.show_entries(page, screen.style, screen.style.face_scene())
	var full := await _measure(tree, seconds)
	DisplayServer.window_set_vsync_mode(vsync)
	var live := 0
	var face_size := Vector2i.ZERO
	for view in page_node.views.values():
		face_size = view.viewport.size
		if view.live():
			live += 1
	var line := "bench %s x%d (%d live, faces %dx%d px), %.0f s each, vsync off\n  empty page: %s\n  full page:  %s" % [rarity,
		page.size(), live, face_size.x, face_size.y, seconds, _times(base), _times(full)]
	screen.go_to_page(screen.page_index)
	return line


static func _measure(tree: SceneTree, seconds: float) -> Dictionary:
	for i in 10:
		await tree.process_frame   # let the page settle (still faces draw once)
	var root := tree.root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(root, true)
	var frames: Array[float] = []
	var gpu := 0.0
	var start := Time.get_ticks_usec()
	var last := start
	while Time.get_ticks_usec() - start < int(seconds * 1000000.0):
		await tree.process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(root)
		Watchdog.beat("cardui bench")
	RenderingServer.viewport_set_measure_render_time(root, false)
	if frames.is_empty():
		return {"frames": 0, "avg": 0.0, "p95": 0.0, "max": 0.0, "gpu": 0.0}
	frames.sort()
	var total := 0.0
	for frame in frames:
		total += frame
	return {"frames": frames.size(), "avg": total / frames.size(), "p95": frames[mini(int(frames.size() * 0.95), frames.size() - 1)],
		"max": frames.back(), "gpu": gpu / frames.size()}


static func _times(times: Dictionary) -> String:
	return "%d frames, avg %.2f ms (%.0f fps), p95 %.2f ms, max %.2f ms, main viewport GPU %.2f ms" % [int(times["frames"]),
		times["avg"], 1000.0 / maxf(times["avg"], 0.001), times["p95"], times["max"], times["gpu"]]


static func _describe(shown: Dictionary) -> String:
	var lines := PackedStringArray(["gems %s" % (str(shown["gems"]) if int(shown["gems"]) >= 0 else "unknown")])
	for offer in shown["offers"]:
		lines.append("  %s: %d gems, %d cards, owned %s" % [offer["packId"], int(offer["price"]), int(offer["cardCount"]),
			str(offer["owned"]) if int(offer["owned"]) >= 0 else "unknown"])
	if str(shown["message"]) != "":
		lines.append("  message: %s" % shown["message"])
	return "\n".join(lines)
