## Spec card-ui (slice 5b), the Shop sub-step: the Shop's model (offers, odds, affordability), the player's CardAccount (one
## action in flight, nothing on disk, the same key on every retry until the server answers, giving up, the 1403 cancel path,
## a reused key), the Shop screen over a fake bridge (offers, buy, refusals, offline, reconnecting, giving up), the main
## menu's three card buttons with the unopened count, the `cardui` command, and the isolation of the card presentation.
## Fixtures and a fake server only: the user's content cannot fail these.
extends TestCase

const FakeBridge = preload("res://tests/game/test_server_mode.gd").FakeBridge
const MENU: StringName = &"UI.Layer.Menu"
const SHOP_SCENE: String = "res://presentation/demo/ui/cards/shop.tscn"

const PACKS := {"packs": [{"packId": "descent-pack", "name": "Descent Pack", "version": 1, "priceGems": 100, "cardCount": 5,
	"oddsPer10000": {"mythic": 40, "common": 7210, "legendary": 100, "rare": 2200, "epic": 450}, "setIds": ["descent"],
	"cardIds": [], "pityPacks": {"legendary": 20, "epic": 10, "mythic": 30}, "firstGuarantees": {}, "minRarityPerPack": "rare"},
	{"packId": "mini-pack", "name": "Mini", "version": 1, "priceGems": 40, "cardCount": 5, "oddsPer10000": {"common": 10000},
	"setIds": ["descent"], "cardIds": [], "pityPacks": {}, "firstGuarantees": {}, "minRarityPerPack": null}]}
const COLLECTION := {"owned": [], "gems": 340, "dust": 0, "accountVersion": 3, "activeRunId": null, "activeRunStatus": null, "pity": [],
	"ownedPacks": [{"packId": "descent-pack", "count": 2}, {"packId": "old-pack", "count": 4, "refundHeld": true}]}

var _games: Array[GameMain] = []
var _nodes: Array[Node] = []


func after_each() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	for game in _games:
		if is_instance_valid(game):
			game.queue_free()
	_games.clear()
	super()


func _frames(count: int) -> void:
	for i in count:
		await host.get_tree().process_frame


func _link(bridge: FakeBridge) -> ServerLink:
	var link := ServerLink.new(bridge)
	link.retry_base_seconds = 0.01
	link.retry_max_seconds = 0.02
	link.player = "tester"
	link.url = "http://fake:5000"
	link.saves_dir = "user://test_card_ui/saves_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	return link


func _detached_link(bridge: FakeBridge) -> ServerLink:
	var link := _link(bridge)
	host.add_child(link)
	_nodes.append(link)
	return link


func _game(bridge: FakeBridge = null) -> GameMain:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	_games.append(game)
	game.content_root = FIXTURES
	game.load_content()
	game.local_saves = false
	if bridge != null:
		game.use_server(_link(bridge))
	return game


func _bridge() -> FakeBridge:
	var bridge := FakeBridge.new()
	bridge.answers["GetPacks"] = [[true, PACKS]]
	bridge.answers["GetCollection"] = [[true, COLLECTION]]
	bridge.answers["GetCurrentRun"] = [[true, null]]
	return bridge


func _open_shop(game: GameMain) -> UIScreen:
	await _frames(2)
	var shop := game.ui.push(MENU, load(SHOP_SCENE))
	if shop != null and shop.loading:
		await shop.loaded
	return shop


static func _buy_bodies(bridge: FakeBridge) -> Array:
	return bridge.calls.filter(func(call: Array) -> bool: return call[0] == "BuyPack").map(
		func(call: Array) -> Dictionary: return JSON.parse_string(call[2]))


# --- ShopModel ---------------------------------------------------------------------------------------------------------------

func test_offers_follow_the_server_with_odds_and_pity_in_rarity_order() -> void:
	var offers := ShopModel.offers(PACKS, COLLECTION)
	eq(offers.map(func(offer: Dictionary) -> String: return offer["packId"]), ["descent-pack", "mini-pack"], "the server's order")
	var descent: Dictionary = offers[0]
	eq([descent["name"], descent["price"], descent["cardCount"], descent["owned"], descent["minRarity"]],
		["Descent Pack", 100, 5, 2, "rare"], "the offer's facts")
	eq(descent["odds"].map(func(row: Dictionary) -> String: return row["rarity"]), ["common", "rare", "epic", "legendary", "mythic"],
		"odds lowest rarity first, whatever the JSON order")
	eq(descent["pity"].map(func(row: Dictionary) -> int: return row["packs"]), [10, 20, 30], "pity in rarity order")
	eq([offers[1]["owned"], offers[1]["minRarity"], offers[1]["pity"]], [0, "", []], "an unowned pack with no guarantee or pity")
	eq(ShopModel.offers(PACKS, null)[0]["owned"], -1, "without the collection the owned count is unknown")
	eq(ShopModel.gems(COLLECTION), 340, "the gems")
	eq(ShopModel.gems(null), -1, "unknown gems")


func test_affordability_and_percentages() -> void:
	var offer: Dictionary = ShopModel.offers(PACKS, COLLECTION)[0]
	check(ShopModel.affordable(offer, 1, 340) and ShopModel.affordable(offer, 3, 300), "enough gems")
	check(not ShopModel.affordable(offer, 5, 340), "five packs cost 500")
	check(ShopModel.affordable(offer, 5, -1), "an unknown total never disables: the server decides")
	eq([ShopModel.percent(7210), ShopModel.percent(40), ShopModel.percent(10000), ShopModel.percent(5)],
		["72.10%", "0.40%", "100.00%", "0.05%"], "two decimals, integer maths")


# --- CardAccount (spec 2.5, section 4 rows 1 to 9) -----------------------------------------------------------------------

## Waits up to `frames` frames for `condition`; true when it held.
func _until(condition: Callable, frames: int = 300) -> bool:
	for i in frames:
		if condition.call():
			return true
		await host.get_tree().process_frame
	return condition.call()


func test_one_action_in_flight() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [[true, {"packId": "descent-pack", "packVersion": 1, "count": 1, "gemsSpent": 100, "gems": 240, "owned": 3}]]
	var link := _detached_link(bridge)
	var account := link.card_account()
	var first := {}
	var start := func() -> void: first.merge(await account.run(CardAccount.BUY, "descent-pack", 1))
	start.call()  # not awaited: still on its way
	check(account.busy(), "busy while the first is on its way")
	eq(account.in_flight()["kind"], "buy", "the action on its way")
	var second: Dictionary = await account.run(CardAccount.OPEN, "descent-pack")
	check(not second["ok"] and second["error"].get("busy", false), "a second action is refused at once")
	check(not ServerLink.retryable(second["error"]) and not ServerLink.describe(second["error"]).begins_with("no connection"),
		"a local refusal is never retried nor called a lost connection")
	await _frames(3)
	check(not account.busy(), "the answer arrived")
	eq(bridge.count("BuyPack"), 1, "one buy reached the server")
	eq(bridge.count("OpenPack"), 0, "the refused open never did")
	check(first.get("ok", false), "the first call got its answer")
	check(not DirAccess.dir_exists_absolute(link.saves_dir), "nothing is written to disk")


func test_lost_buy_is_resent_with_its_key_until_the_server_answers() -> void:
	var bridge := _bridge()
	var link := _detached_link(bridge)
	await link.get_collection()  # signed in; then the connection drops
	bridge.offline = true
	var account := link.card_account()
	var heard := []
	account.reconnecting.connect(func() -> void: heard.append("reconnecting"))
	account.reconnected.connect(func() -> void: heard.append("reconnected"))
	var answer := {}
	var start := func() -> void: answer.merge(await account.run(CardAccount.BUY, "descent-pack", 5))
	start.call()
	check(await _until(func() -> bool: return bridge.count("BuyPack") >= 4), "it keeps trying while there is no answer")
	check(answer.is_empty() and account.busy(), "the caller still waits: an unanswered buy never returns")
	eq(heard, ["reconnecting"], "reconnecting once")
	check(account.reconnecting_seconds() >= 0.0, "and it knows for how long")
	bridge.offline = false
	bridge.answers["BuyPack"] = [[true, {"packId": "descent-pack", "packVersion": 1, "count": 5, "gemsSpent": 500, "gems": 0, "owned": 7}]]
	check(await _until(func() -> bool: return not answer.is_empty()), "the server answers")
	check(answer["ok"] and not answer["given_up"], "the buy went through")
	eq(heard, ["reconnecting", "reconnected"], "then reconnected")
	eq(account.reconnecting_seconds(), -1.0, "and no longer reconnecting")
	var keys := _buy_bodies(bridge).map(func(body: Dictionary) -> String: return body["requestKey"])
	check(keys.all(func(key: String) -> bool: return key == answer["key"]), "every try carried the same key")
	var last: Dictionary = _buy_bodies(bridge)[-1]
	eq([int(last["count"]), last.size(), int(last["session"]), int(last["expectedAccountVersion"])], [5, 4, 1, 3],
		"the very same request, with the session and the account version read before (the server answers a known key once)")
	check(not DirAccess.dir_exists_absolute(link.saves_dir), "nothing was written to disk")


func test_give_up_settles_at_once_and_ignores_a_late_answer() -> void:
	var bridge := _bridge()
	var link := _detached_link(bridge)
	await link.get_collection()
	bridge.offline = true
	var account := link.card_account()
	var answer := {}
	var start := func() -> void: answer.merge(await account.run(CardAccount.BUY, "descent-pack", 1))
	start.call()
	check(await _until(func() -> bool: return account.reconnecting_seconds() >= 0.0), "reconnecting")
	account.give_up()
	check(not answer.is_empty() and answer["given_up"] and not answer["ok"], "the caller hears given_up at once")
	check(account.busy() and account.in_flight()["givenUp"], "still busy while the last try is out: nothing overlaps it")
	var refused: Dictionary = await account.run(CardAccount.BUY, "descent-pack", 1)
	check(refused["error"].get("busy", false), "a new action waits for it")
	var freed := []
	account.busy_changed.connect(func() -> void: freed.append(account.busy()))
	var tries := bridge.count("BuyPack")
	bridge.offline = false
	check(await _until(func() -> bool: return not account.busy()), "free once the last try is back")
	eq(freed, [false], "busy_changed tells the screens to refetch")
	await _frames(10)
	check(bridge.count("BuyPack") <= tries + 1, "it stops re-sending (one try already out may still land)")
	eq(answer["given_up"], true, "a late answer changes nothing for the caller")
	bridge.answers["BuyPack"] = [[true, {"packId": "descent-pack", "packVersion": 1, "count": 1, "gemsSpent": 100, "gems": 240, "owned": 3}]]
	var next: Dictionary = await account.run(CardAccount.BUY, "descent-pack", 1)
	check(next["ok"], "a new press is a new buy")
	check(next["key"] != answer["key"], "with a new key")


func test_no_resume_after_restart() -> void:
	var bridge := _bridge()
	var link := _detached_link(bridge)
	await link.get_collection()
	bridge.offline = true
	var start := func() -> void: await link.card_account().run(CardAccount.BUY, "descent-pack", 1)
	start.call()
	check(await _until(func() -> bool: return link.card_account().reconnecting_seconds() >= 0.0), "a buy with no answer")
	link.card_account().give_up()  # the app quits (or crashes) here
	var tries := bridge.count("BuyPack")
	bridge.offline = false
	var again := _detached_link(bridge)
	again.saves_dir = link.saves_dir
	check(not again.card_account().busy() and again.card_account().in_flight().is_empty(), "a new start knows nothing")
	check(not DirAccess.dir_exists_absolute(link.saves_dir), "nothing on disk")
	await _frames(10)
	check(bridge.count("BuyPack") <= tries + 1, "and nothing is re-sent")


func test_reconnect_caps_a_long_retry_after() -> void:
	var bridge := _bridge()
	bridge.answers["DustCard"] = [[false, {"status": 429, "errorCode": 1201, "title": "slow down", "detail": "", "retryAfterSeconds": 600}],
		[true, {"cardId": "item.a", "dustGained": 20, "rateVersion": 1, "dust": 20}]]
	var account := _detached_link(bridge).card_account()
	account.reconnect_max_delay = 0.05
	var answer := {}
	var start := func() -> void: answer.merge(await account.run(CardAccount.DUST, "item.a"))
	start.call()
	check(await _until(func() -> bool: return not answer.is_empty(), 120), "a Retry-After of 600 s waits reconnect_max_delay at most")
	check(answer.get("ok", false), "and the retry went through")


func test_retry_keeps_key_through_server_errors() -> void:
	var bridge := _bridge()
	bridge.answers["OpenPack"] = [[false, {"status": 503, "errorCode": null, "title": "down", "detail": ""}],
		[false, {"status": 429, "errorCode": 1201, "title": "slow down", "detail": "", "retryAfterSeconds": 0.01}],
		[true, {"openingId": "o", "packId": "descent-pack", "packVersion": 1, "gemsSpent": 0, "gems": 340, "dust": 0, "drawSeed": "1",
			"packsLeft": 1, "cards": []}]]
	var account := _detached_link(bridge).card_account()
	var opened: Dictionary = await account.run(CardAccount.OPEN, "descent-pack")
	check(opened["ok"] and not opened["given_up"], "answered after a 503 and a 429")
	var keys := bridge.calls.filter(func(call: Array) -> bool: return call[0] == "OpenPack").map(
		func(call: Array) -> String: return JSON.parse_string(call[2])["requestKey"])
	eq(keys.size(), 3, "three tries")
	eq([keys[0] == keys[1], keys[1] == keys[2], keys[0] == opened["key"]], [true, true, true], "one key for all of them")


func test_refusals_are_answers() -> void:
	var bridge := _bridge()
	for code in [1402, 1404, 1405, 1406, 1408, 1411]:
		bridge.answers["CraftCard"] = [[false, {"status": 409, "errorCode": code, "title": "refused", "detail": ""}]]
		var account := _detached_link(bridge).card_account()
		var refused: Dictionary = await account.run(CardAccount.CRAFT, "item.a")
		eq([refused["ok"], refused["given_up"], CardAccount.code_of(refused)], [false, false, code], "%d is an answer" % code)
		check(not account.busy(), "%d leaves nothing on its way" % code)


func test_key_reused_is_an_error() -> void:
	var bridge := _bridge()
	bridge.answers["DustCard"] = [[false, {"status": 409, "errorCode": 1407, "title": "Request key reused", "detail": ""}]]
	var account := _detached_link(bridge).card_account()
	var refused: Dictionary = await account.run(CardAccount.DUST, "item.a")
	check(not refused["ok"] and not account.busy(), "treated as a refusal: the key is forgotten")


func test_dust_cancel_run_path() -> void:
	var bridge := _bridge()
	bridge.answers["DustCard"] = [[false, {"status": 409, "errorCode": 1403, "title": "Card locked by the run", "detail": "",
		"runId": "run-1", "runStatus": "Active"}], [true, {"cardId": "item.a", "dustGained": 20, "rateVersion": 1, "dust": 20}]]
	bridge.answers["AbandonRun"] = [[true, null]]
	var account := _detached_link(bridge).card_account()
	var locked: Dictionary = await account.run(CardAccount.DUST, "item.a")
	eq(CardAccount.code_of(locked), 1403, "the run lock")
	check(not account.busy(), "a refusal ends the action")
	var dusted: Dictionary = await account.cancel_run_and_retry(locked)
	check(dusted["ok"], "dusted after the cancel")
	eq(bridge.calls.filter(func(call: Array) -> bool: return call[0] == "AbandonRun")[0][1], "run-1", "that run was cancelled")
	var keys := bridge.calls.filter(func(call: Array) -> bool: return call[0] == "DustCard").map(
		func(call: Array) -> String: return JSON.parse_string(call[2])["requestKey"])
	eq([keys.size(), keys[0] == keys[1]], [2, true], "the same key re-sent (a refusal stored nothing under it)")


func test_abandon_refused_while_verifying_does_not_retry_the_dust() -> void:
	var bridge := _bridge()
	bridge.answers["DustCard"] = [[false, {"status": 409, "errorCode": 1403, "title": "Card locked by the run", "detail": "",
		"runId": "run-1", "runStatus": "Active"}]]
	bridge.answers["AbandonRun"] = [[false, {"status": 409, "errorCode": 1410, "title": "Run is being verified", "detail": ""}]]
	var account := _detached_link(bridge).card_account()
	var locked: Dictionary = await account.run(CardAccount.DUST, "item.a")
	var refused: Dictionary = await account.cancel_run_and_retry(locked)
	eq([refused["ok"], refused["kind"], CardAccount.code_of(refused)], [false, "abandon", 1410], "the abandon's refusal")
	eq(bridge.count("DustCard"), 1, "the dust is not retried")


# --- The Shop screen (spec 2.3a) ---------------------------------------------------------------------------------------------

func test_shop_shows_the_offers_and_the_gems() -> void:
	var game := _game(_bridge())
	var shop := await _open_shop(game)
	check(shop != null and shop.name == "Shop", "the Shop opens on the Menu layer")
	var shown: Dictionary = shop.shown()
	eq([shown["gems"], shown["offers"].size(), shown["message"]], [340, 2, ""], "gems and two offers, no message")
	eq(shop.get_node("%Gems").text, "340 gems", "the gems total")
	var entries: Array = shop.get_node("%Offers").get_children()
	var descent: Node = entries[0]
	eq(descent.get_node("%Name").text, "Descent Pack", "the pack name")
	eq([descent.get_node("%Buy1").text, descent.get_node("%Buy5").text], ["Buy 1 · 100 gems", "Buy 5 · 500 gems"], "the prices")
	eq([descent.get_node("%Buy1").disabled, descent.get_node("%Buy5").disabled], [false, true], "340 gems buy one, not five")
	eq(descent.get_node("%Owned").text, "You own 2 unopened.", "the owned count")
	eq(descent.get_node("%Guarantee").text, "At least one Rare or better in every pack.", "the guarantee")
	eq(descent.get_node("%Odds").get_child_count(), 10, "five rarities, a name and a value each")
	eq(descent.get_node("%Odds").get_child(1).text, "72.10%", "common's odds")
	check(not entries[1].get_node("%Guarantee").visible, "no guarantee line when the pack has none")
	eq(shop.get_node("%Description").get_node("%Name").text, "Descent Pack", "the first offer previews")
	game.ui.back()
	await _frames(2)
	eq(String(game.ui.top(MENU).name), "MainMenu", "Back returns to the main menu")


func test_shop_buy_updates_the_gems_and_the_owned_count() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [[true, {"packId": "descent-pack", "packVersion": 1, "count": 3, "gemsSpent": 300, "gems": 40, "owned": 5}]]
	var game := _game(bridge)
	var shop := await _open_shop(game)
	var answer: Dictionary = await shop.buy("descent-pack", 3)
	check(answer["ok"], "bought")
	eq(int(_buy_bodies(bridge)[0]["count"]), 3, "three packs asked for")
	eq(shop.shown()["message"], "Bought 3 packs. You have 5 waiting in Open packs.", "the line")
	eq(shop.shown()["gems"], 40, "the new total")
	eq(shop.shown()["offers"][0]["owned"], 5, "the new owned count")
	var entry: Node = shop.get_node("%Offers").get_child(0)
	await host.get_tree().create_timer(shop.gems_tween_seconds + 0.1).timeout
	eq(shop.get_node("%Gems").text, "40 gems", "the total counted down")
	eq([entry.get_node("%Owned").text, entry.get_node("%Buy1").disabled], ["You own 5 unopened.", true], "40 gems: nothing affordable")


func test_shop_double_press_buys_once() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [[true, {"packId": "descent-pack", "packVersion": 1, "count": 1, "gemsSpent": 100, "gems": 240, "owned": 3}]]
	var game := _game(bridge)
	var shop := await _open_shop(game)
	var entry: Node = shop.get_node("%Offers").get_child(0)
	entry.get_node("%Buy1").pressed.emit()
	check(entry.get_node("%Buy1").disabled, "the buttons disable while the confirm is up")
	entry.get_node("%Buy1").pressed.emit()
	check(await _answer(game, true), "Buy asks first")
	check(entry.get_node("%Buy1").disabled, "and stay disabled while the buy is on its way")
	entry.get_node("%Buy1").pressed.emit()
	await _frames(4)
	eq(bridge.count("BuyPack"), 1, "one purchase")


func test_shop_buy_asks_to_confirm_and_cancel_buys_nothing() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [[true, {"packId": "descent-pack", "packVersion": 1, "count": 5, "gemsSpent": 500, "gems": 40,
		"owned": 7}]]
	var game := _game(bridge)
	var shop := await _open_shop(game)
	var entry: Node = shop.get_node("%Offers").get_child(0)
	entry.get_node("%Buy5").pressed.emit()
	await _frames(2)
	var dialog: UIScreen = game.ui.top(MODAL)
	check(dialog is UIConfirm, "a confirm pop-up comes up")
	var texts := dialog.find_children("*", "Label", true, false).map(func(label: Label) -> String: return label.text)
	check(texts.any(func(text: String) -> bool: return text.begins_with("Buy 5 packs of ") and text.ends_with(" gems?")),
		"it names the count, the pack and the price: %s" % [texts])
	check(await _answer(game, false), "Cancel")
	await _frames(3)
	eq(bridge.count("BuyPack"), 0, "Cancel buys nothing")
	check(not entry.get_node("%Buy1").disabled, "and the buttons work again (Buy 1: five cost more than the account has)")
	entry.get_node("%Buy5").pressed.emit()
	check(await _answer(game, true), "Buy")
	await _frames(6)
	eq(bridge.count("BuyPack"), 1, "Buy buys")
	check(entry.get_node("%Pack").solid, "the Shop's pack is the 3D foil pack")


func test_shop_refusals_show_the_line_and_refetch() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [[false, {"status": 409, "errorCode": 1402, "title": "Not enough currency", "detail": ""}],
		[false, {"status": 404, "errorCode": 1408, "title": "Pack unavailable", "detail": "That pack is no longer sold."}]]
	var game := _game(bridge)
	var shop := await _open_shop(game)
	var before := bridge.count("GetPacks")
	await shop.buy("mini-pack", 1)
	if shop.loading:
		await shop.loaded
	eq(shop.shown()["message"], "Not enough gems (need 40, have 340).", "the 1402 line survives the refetch")
	eq(bridge.count("GetPacks"), before + 1, "the packs were fetched again")
	await shop.buy("descent-pack", 1)
	if shop.loading:
		await shop.loaded
	eq(shop.shown()["message"], "That pack is no longer sold.", "the server's line for a 1408")


const DOWN := [[false, {"status": 503, "errorCode": null, "title": "down", "detail": ""}]]


func _popup(game: GameMain) -> Node:
	for node in game.find_children("*", "", true, false):
		if node.scene_file_path == "res://presentation/demo/ui/connecting_popup.tscn":
			return node
	return null


func test_shop_reconnects_until_the_buy_is_answered() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = DOWN  # the last answer repeats: the server keeps failing
	var game := _game(bridge)
	var shop := await _open_shop(game)
	var answer := {}
	var press := func() -> void: answer.merge(await shop.buy("descent-pack", 1))
	press.call()
	var account := game.server.card_account()
	check(await _until(func() -> bool: return account.reconnecting_seconds() >= 0.0), "reconnecting")
	eq(game.server.waiting_text(), "Reconnecting to the server…", "the connecting pop-up says so")
	check(shop.get_node("%Offers").get_child(0).get_node("%Buy1").disabled, "no new buy meanwhile")
	game.ui.back()
	eq(game.ui.top(MENU), shop, "Back waits for the buy")
	bridge.answers["BuyPack"] = [[true, {"packId": "descent-pack", "packVersion": 1, "count": 1, "gemsSpent": 100, "gems": 240, "owned": 3}]]
	check(await _until(func() -> bool: return not answer.is_empty()), "the server answers")
	eq(shop.shown()["message"], "Bought 1 pack. You have 3 waiting in Open packs.", "the buy's line")
	eq(game.server.waiting_text(), "", "the pop-up is gone")
	var keys := _buy_bodies(bridge).map(func(body: Dictionary) -> String: return body["requestKey"])
	check(keys.size() >= 2 and keys.all(func(key: String) -> bool: return key == answer["key"]), "one key for every try")


func test_shop_stop_waiting_shows_the_server_state() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = DOWN
	var game := _game(bridge)
	var shop := await _open_shop(game)
	var popup := _popup(game)
	check(popup != null, "the connecting pop-up is in the layout")
	var answer := {}
	var press := func() -> void: answer.merge(await shop.buy("descent-pack", 1))
	press.call()
	check(await _until(func() -> bool: return popup.offers_go_offline(), 600),
		"the pop-up offers Go offline as soon as the account reconnects")
	var fetched := bridge.count("GetCollection")
	game.server.card_account().give_up()  # `cardui giveup`: stop waiting but stay online
	check(await _until(func() -> bool: return not answer.is_empty() and not shop.loading), "the buy settles")
	check(answer["given_up"], "given up")
	eq(shop.shown()["message"], "We couldn't confirm your purchase. Your gems and packs show what the server has.", "the line")
	check(bridge.count("GetCollection") > fetched, "the Shop fetched the server's state")
	var buy1: Button = shop.get_node("%Offers").get_child(0).get_node("%Buy1")
	check(await _until(func() -> bool: return not game.server.card_account().busy() and not shop.loading and not buy1.disabled),
		"once the last try is back, the Shop refetches and can buy again")
	eq(shop.shown()["message"], "We couldn't confirm your purchase. Your gems and packs show what the server has.", "the line stays")


## Card-ui playtest (user, 2026-11-18): a buy that went through says so in a blue window with one OK button.
func test_a_purchase_shows_a_notice() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [[true, {"packId": "descent-pack", "packVersion": 1, "count": 5, "gemsSpent": 500, "gems": 40,
		"owned": 7}]]
	var game := _game(bridge)
	var shop := await _open_shop(game)
	await shop.buy("descent-pack", 5)
	await _frames(2)
	var notice := game.ui.top(&"UI.Layer.Modal")
	check(notice is UIConfirm, "a notice on the Modal layer")
	eq(notice.get_node("%Text").text, "Purchased 5 packs!", "its text")
	eq([notice.get_node("%Yes").visible, notice.get_node("%Yes").text, notice.get_node("%No").visible], [true, "OK", false], "one OK button")
	notice.get_node("%Yes").pressed.emit()
	await _frames(2)
	eq(game.ui.top(&"UI.Layer.Modal"), null, "OK closes it")
	eq(game.ui.top(MENU), shop, "back on the Shop")


## Card-ui playtest (user, 2026-11-18): Go offline under the Reconnecting pop-up stops waiting, plays in local mode (the Settings
## keep their url) and returns to the main menu.
func test_go_offline_returns_to_the_main_menu_in_local_mode() -> void:
	var url_before: Variant = GameMain.load_setting(ServerLink.SETTINGS_SECTION, "url", "")
	var bridge := _bridge()
	bridge.answers["BuyPack"] = DOWN
	var game := _game(bridge)
	await _frames(2)
	var menu := game.ui.top(MENU)  # the main menu, under the Shop
	check(menu != null and menu.owned_by_rule, "the main menu is up")
	var shop := await _open_shop(game)
	var popup := _popup(game)
	popup.show_after_seconds = 0.0
	var answer := {}
	var press := func() -> void: answer.merge(await shop.buy("descent-pack", 1))
	press.call()
	check(await _until(func() -> bool: return popup.offers_go_offline(), 600), "Go offline shows under the pop-up")
	var button: Button = popup.get_node("%GoOffline")
	eq(button.text, "Go offline", "named so")
	check(button.get_parent() == popup.get_node("%Text").get_parent().get_parent(), "inside the window, under the text's row")
	check(button.theme_type_variation == &"" and not button.has_theme_stylebox_override(&"normal"), "a plain theme button")
	button.pressed.emit()
	check(await _until(func() -> bool: return not answer.is_empty()), "the buy settles")
	check(answer.get("given_up", false), "given up: nothing is re-sent")
	eq(game.server, null, "local mode")
	await _frames(3)
	eq(game.ui.top(MENU), menu, "back on the main menu")
	check(not popup.showing(), "the pop-up is gone")
	eq(GameMain.load_setting(ServerLink.SETTINGS_SECTION, "url", ""), url_before, "the Settings keep their server")


## The main menu's Go online: the same pop-up while it signs in again, retried until the server answers.
func test_go_online_retries_behind_the_pop_up_until_it_answers() -> void:
	var game := _game()
	game.go_online_retry_seconds = Vector2(0.02, 0.05)
	await _frames(2)
	var popup := _popup(game)
	popup.show_after_seconds = 0.0
	var bridge := _bridge()
	bridge.offline = true
	var result := {}
	var press := func() -> void: result["error"] = await game.go_online(_link(bridge))
	press.call()
	check(await _until(func() -> bool: return bridge.count("GetDevToken") >= 3, 3000), "it keeps trying")
	await _frames(2)
	check(popup.showing() and popup.offers_go_offline(), "behind the pop-up, with Go offline")
	eq(game.server.waiting_text(), "Connecting to the server…", "its text")
	bridge.offline = false
	check(await _until(func() -> bool: return result.has("error"), 3000), "the server answers")
	eq(result["error"], "", "online")
	check(game.server != null and game.server.connected(), "in server mode, signed in")
	await _frames(2)
	check(not popup.showing(), "the pop-up is gone")


func test_go_offline_while_going_online_stays_local() -> void:
	var game := _game()
	game.go_online_retry_seconds = Vector2(0.02, 0.05)
	await _frames(2)
	var popup := _popup(game)
	popup.show_after_seconds = 0.0
	var bridge := _bridge()
	bridge.offline = true
	var press := func() -> void: await game.go_online(_link(bridge))
	press.call()
	check(await _until(func() -> bool: return popup.offers_go_offline(), 600), "Go offline is offered")
	popup.get_node("%GoOffline").pressed.emit()
	eq(game.server, null, "local mode at once")
	var tries := bridge.count("GetDevToken")
	await _frames(10)
	check(bridge.count("GetDevToken") <= tries + 1, "and no more sign-in tries")
	check(not popup.showing(), "the pop-up is gone")
	# Review fix (round 3): the first Go online ended, so a second one works (it used to stay "stopped" for good).
	await _frames(10)
	eq(await game.go_online(_link(_bridge())), "", "Go online again: online")
	check(game.is_online(), "online")


## Review fixes (2026-11-18): a 503 or 429 is retried like no answer; a link that holds a session keeps it when it comes back.
func test_go_online_retries_server_errors_and_keeps_the_session() -> void:
	var game := _game()
	game.go_online_retry_seconds = Vector2(0.02, 0.05)
	await _frames(2)
	var bridge := _bridge()
	bridge.answers["GetDevToken"] = [[false, {"status": 503, "errorCode": null, "title": "Database unavailable", "detail": ""}],
		"default"]
	var result := {}
	var press := func() -> void: result["error"] = await game.go_online(_link(bridge))
	press.call()
	check(await _until(func() -> bool: return result.has("error"), 3000), "it answers in the end")
	eq(result["error"], "", "a 503 was retried, not taken as a refusal")
	check(bridge.count("GetDevToken") >= 2, "signed in again after the 503")
	check(await _until(func() -> bool: return game.server.account_session == 1), "a session")
	var sessions := bridge.count("StartAccountSession")
	bridge.offline = true
	await game.server.get_collection()  # a call goes unanswered: not online any more
	check(not game.is_online(), "not online")
	bridge.offline = false
	eq(await game.go_online(), "", "back online with the same link")
	eq([game.server.account_session, bridge.count("StartAccountSession")], [1, sessions], "no new session (it would fence its own calls)")


func test_go_online_once_at_a_time() -> void:
	var game := _game()
	game.go_online_retry_seconds = Vector2(0.02, 0.05)
	await _frames(2)
	var bridge := _bridge()
	bridge.offline = true
	var first := func() -> void: await game.go_online(_link(bridge))
	first.call()
	eq(await game.go_online(), GameMain.GO_ONLINE_STOPPED, "a second press while the first tries")
	game.go_offline()


func test_go_offline_answers_an_open_dialog_and_keeps_the_old_link_idle() -> void:
	var game := _game(_bridge())
	await _frames(3)
	var link := game.server
	var answer := {}
	var ask := func() -> void: answer["yes"] = await game.ui.confirm("Continue?")
	ask.call()
	await _frames(1)
	check(game.go_offline(), "Go offline on the main menu")
	eq(answer, {"yes": false}, "the dialog answered No, its caller went on")
	eq(game.ui.top(&"UI.Layer.Modal"), null, "and it is gone")
	check(is_instance_valid(link) and link.retired, "the old link stays (idle) so nothing resumes on a freed object")
	var retried: Dictionary = await link.start_account_session()
	check(not retried["ok"], "a retired link starts no session")


func test_go_offline_is_refused_during_a_run() -> void:
	var game := _game(_bridge())
	await _frames(2)
	game.set_mode("run")
	check(not game.go_offline(), "refused")
	check(game.server != null, "the run keeps its link")
	game.set_mode("menu")


func test_enter_closes_a_notice() -> void:
	var game := _game()
	await _frames(2)
	var closed := {}
	var show := func() -> void:
		await game.ui.notify("Purchased 1 pack!")
		closed["done"] = true
	show.call()
	await _frames(2)
	var press := InputEventAction.new()
	press.action = &"ui_accept"
	press.pressed = true
	Input.parse_input_event(press)
	check(await _until(func() -> bool: return closed.has("done")), "Enter closed it")


## Review fix: Enter on the purchase notice closes it and never presses the focused Buy again; notices never pile up.
func test_enter_on_the_purchase_notice_buys_nothing_more() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [[true, {"packId": "descent-pack", "packVersion": 1, "count": 1, "gemsSpent": 100, "gems": 240,
		"owned": 3}]]
	var game := _game(bridge)
	var shop := await _open_shop(game)
	var buy1: Button = shop.get_node("%Offers").get_child(0).get_node("%Buy1")
	buy1.grab_focus()
	await shop.buy("descent-pack", 1)
	await _frames(3)
	var owner := buy1.get_viewport().gui_get_focus_owner()
	check(owner != buy1 and owner != null and owner.name == "Yes", "the notice's OK took the focus from Buy")
	var press := InputEventAction.new()
	press.action = &"ui_accept"
	press.pressed = true
	Input.parse_input_event(press)
	await _frames(3)
	eq([bridge.count("BuyPack"), game.ui.top(&"UI.Layer.Modal")], [1, null], "Enter closed the notice, no second buy")
	game.ui.notify("one")
	game.ui.notify("two")
	await _frames(2)
	var modal: Array = game.ui.layout.stacks().filter(func(stack: UILayerStack) -> bool: return stack.layer == &"UI.Layer.Modal")
	eq(modal[0].screens().size(), 1, "a newer notice replaces the older one")


func test_go_online_only_from_the_main_menu() -> void:
	var game := _game()
	await _frames(2)
	game.set_mode("run")
	eq(await game.go_online(_link(_bridge())), "Go online from the main menu.", "refused during a run")
	eq(game.server, null, "nothing linked")
	game.set_mode("menu")


func test_back_while_the_shop_waits_for_the_server() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [[true, {"packId": "descent-pack", "packVersion": 1, "count": 1, "gemsSpent": 100, "gems": 240, "owned": 3}]]
	var game := _game(bridge)
	await _frames(2)
	game.ui.push(MENU, load(SHOP_SCENE))
	game.ui.back()  # before the packs arrive
	await _frames(8)
	var shop := await _open_shop(game)
	var press := func() -> void: await shop.buy("descent-pack", 1)
	press.call()
	game.ui.back()  # before the buy's answer: Back waits for it
	eq(game.ui.top(MENU), shop, "the Shop stays while the buy is on its way")
	await _frames(8)
	eq(bridge.count("BuyPack"), 1, "the buy went out once")
	check(not game.server.card_account().busy(), "and got its answer")
	check(game.ui.top(&"UI.Layer.Modal") is UIConfirm, "the purchase notice is up")
	game.ui.back()  # closes the notice first
	await _frames(2)
	eq([game.ui.top(&"UI.Layer.Modal"), game.ui.top(MENU)], [null, shop], "Back closes the notice")
	game.ui.back()
	await _frames(2)
	eq(String(game.ui.top(MENU).name), "MainMenu", "then Back returns to the main menu")


func test_offline_shop() -> void:
	var game := _game()
	var shop := await _open_shop(game)
	eq(shop.shown(), {"offers": [], "gems": -1, "message": "The Shop needs a server connection. Packs, gems and cards live on the server."},
		"local mode: no offers, the line")
	var down := _bridge()
	down.answers["GetPacks"] = [[false, {"status": 503, "errorCode": null, "title": "Database unavailable", "detail": ""}]]
	game.ui.back()
	game.use_server(_link(down))
	shop = await _open_shop(game)
	eq(shop.shown()["message"], "Can't reach the server: 503 Database unavailable", "a server error is shown")


# --- The main menu and the console --------------------------------------------------------------------------------------------

func test_main_menu_has_the_three_card_buttons_and_the_unopened_count() -> void:
	var game := _game()
	await _frames(3)
	var menu := game.ui.top(MENU)
	for node in ["Collection", "Shop", "OpenPacks"]:
		check(menu.has_node("%" + node), node + " exists")
	eq(menu.get_node("%OpenPacks").text, "Open packs", "local mode: no count")
	game.use_server(_link(_bridge()))
	await _frames(6)
	eq(menu.get_node("%OpenPacks").text, "Open packs (2)", "the unopened count (a held refund does not count)")
	menu.get_node("%Shop").pressed.emit()
	await _frames(2)
	eq(String(game.ui.top(MENU).name), "Shop", "Shop opens the Shop")


## Card-ui playtest (user, 2026-11-18): the Shop and Open packs need the server; offline, a dialog says so and offers Go online.
func test_shop_offline_asks_to_go_online() -> void:
	var game := _game()
	await _frames(3)
	var menu := game.ui.top(MENU)
	eq([menu.get_node("%Shop").needs_online, menu.get_node("%OpenPacks").needs_online], [true, true], "both need the server")
	eq(menu.get_node("%OpenPacks").offline_text, "You must be online to open packs.", "Open packs' line")
	menu.get_node("%Shop").pressed.emit()
	await _frames(2)
	var dialog := game.ui.top(&"UI.Layer.Modal")
	check(dialog is UIConfirm, "a dialog instead of the Shop")
	eq([dialog.get_node("%Text").text, dialog.get_node("%Yes").text, dialog.get_node("%No").text],
		["You must be online to access the Shop.", "Go online", "Back"], "its text and buttons")
	dialog.get_node("%No").pressed.emit()
	await _frames(2)
	eq([game.ui.top(&"UI.Layer.Modal"), game.ui.top(MENU)], [null, menu], "Back: still on the main menu, no Shop")


func test_shop_offline_go_online_then_opens_the_shop() -> void:
	var bridge := _bridge()
	bridge.offline = true
	var game := _game(bridge)  # linked, but the server does not answer: not online
	game.go_online_retry_seconds = Vector2(0.02, 0.05)
	await _frames(3)
	check(not game.is_online(), "not online")
	var menu := game.ui.top(MENU)
	menu.get_node("%Shop").pressed.emit()
	await _frames(2)
	var dialog := game.ui.top(&"UI.Layer.Modal")
	dialog.get_node("%Yes").pressed.emit()
	check(await _until(func() -> bool: return bridge.count("GetDevToken") >= 2, 3000), "Go online signs in, retrying")
	bridge.offline = false
	check(await _until(func() -> bool: return game.ui.top(MENU) != menu, 3000), "once online, the Shop opens")
	eq(String(game.ui.top(MENU).name), "Shop", "the Shop")
	check(game.is_online(), "online")


func _console(game: GameMain) -> DevConsole:
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	console.attach(game)
	return console


func test_cardui_command() -> void:
	var local := _game()
	await _frames(2)
	var console := _console(local)
	var opened: Dictionary = await console.execute("cardui open shop")
	check(opened["ok"] and opened["text"].contains("needs a server"), "local mode opens the offline Shop: %s" % opened["text"])
	for line in ["cardui", "cardui open", "cardui open nowhere", "cardui shop buy descent-pack", "cardui account", "cardui giveup"]:
		var refused: Dictionary = await console.execute(line)
		check(not refused["ok"], "'%s' is refused in local mode" % line)
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [[true, {"packId": "descent-pack", "packVersion": 1, "count": 2, "gemsSpent": 200, "gems": 140, "owned": 4}]]
	local.ui.back()
	local.use_server(_link(bridge))
	await _frames(2)
	var bought: Dictionary = await console.execute("cardui shop buy descent-pack 2")
	check(bought["ok"] and bought["text"].contains("Bought 2 packs. You have 4 waiting") and bought["text"].contains("gems 140")
		and bought["text"].contains("descent-pack: 100 gems, 5 cards, owned 4"), "a buy through the Shop: %s" % bought["text"])
	var shown: Dictionary = await console.execute("cardui shop")
	check(shown["ok"] and shown["text"].contains("mini-pack: 40 gems"), "the Shop on screen: %s" % shown["text"])
	for line in ["cardui shop buy nope", "cardui shop buy descent-pack zero", "cardui shop buy descent-pack 0"]:
		var refused: Dictionary = await console.execute(line)
		check(not refused["ok"], "'%s' is refused" % line)
	eq(bridge.count("BuyPack"), 1, "no call for the refused lines")
	var none: Dictionary = await console.execute("cardui account")
	check(none["ok"] and none["text"] == "nothing on its way", "nothing on its way: %s" % none["text"])
	check(not (await console.execute("cardui giveup"))["ok"], "nothing to give up")


# --- The Collection and card detail (spec 2.1, 2.2; gate 2) -----------------------------------------------------------------

const COLLECTION_SCENE: String = "res://presentation/demo/ui/cards/collection.tscn"
const DETAIL_SCENE: String = "res://presentation/demo/ui/cards/card_detail.tscn"
const MODAL: StringName = &"UI.Layer.Modal"
const RATES := {"common": [5, 40], "rare": [20, 100], "epic": [100, 400], "legendary": [400, 1600], "mythic": [1000, 3200]}


## The server's catalog of the card fixtures (CardWorld), with rates by rarity.
static func _catalog() -> Dictionary:
	var cards: Array = []
	for row in CardCatalog.cards(CardWorld.content()):
		var card: Dictionary = row.duplicate()
		var rate: Array = RATES[row["rarity"]]
		card["retired"] = false
		card["dustValue"] = rate[0]
		card["craftCost"] = rate[1]
		cards.append(card)
	return {"catalogVersion": 1, "catalogHash": "fixture", "cards": cards}


static func _owned_collection(dust: int = 120, run_status: Variant = null) -> Dictionary:
	var collection: Dictionary = COLLECTION.duplicate(true)
	collection["dust"] = dust
	collection["owned"] = [{"cardId": "card.item.r1", "acquiredAt": "2026-11-01T10:00:00+00:00", "source": "pack", "lockedByRunId": null},
		{"cardId": "card.item.e1", "acquiredAt": "2026-11-01T10:00:00+00:00", "source": "pack",
			"lockedByRunId": "run-1" if run_status != null else null}]
	collection["activeRunId"] = "run-1" if run_status != null else null
	collection["activeRunStatus"] = run_status
	return collection


func _card_bridge(collection: Dictionary = _owned_collection()) -> FakeBridge:
	var bridge := _bridge()
	bridge.answers["GetCardCatalog"] = [[true, _catalog()]]
	bridge.answers["GetCollection"] = [[true, collection]]
	return bridge


func _card_game(bridge: FakeBridge = null) -> GameMain:
	var game := _game(bridge)
	game.content = CardWorld.content()
	return game


func _open_collection(game: GameMain) -> UIScreen:
	await _frames(2)
	var screen := game.ui.push(MENU, load(COLLECTION_SCENE))
	if screen != null and screen.loading:
		await screen.loaded
	return screen


## Answers the confirm dialog that comes up on the Modal layer.
func _answer(game: GameMain, yes: bool) -> bool:
	for i in 60:
		var dialog := game.ui.top(MODAL)
		if dialog is UIConfirm:
			dialog.decided.emit(yes)
			return true
		await host.get_tree().process_frame
	return false


func _card_ids(shown: Dictionary) -> Array:
	return shown["cards"].map(func(card: Dictionary) -> String: return card["id"])


func test_collection_model_states_filters_sort_and_pages() -> void:
	var faces := CardFaces.build(CardWorld.content(), CardStyle.current())
	var all := CollectionModel.entries(faces, _owned_collection(120, "Active"), {"card.item.r1": true},
		CollectionModel.rates_of(_catalog()))
	var by_id := {}
	for entry in all:
		by_id[entry["id"]] = entry
	eq([by_id["card.item.c1"]["state"], by_id["card.item.r1"]["state"], by_id["card.item.c2"]["state"]],
		["core", "owned", "missing"], "core, owned, missing")
	eq([by_id["card.item.e1"]["locked"], by_id["card.item.e1"]["new"], by_id["card.item.r1"]["new"], by_id["card.item.c1"]["new"]],
		[true, true, false, false], "the run lock; NEW only for an owned non-core card not seen")
	eq([by_id["card.item.l1"]["dust"], by_id["card.item.l1"]["craft"]], [400, 1600], "the catalog's rates")
	var sorted := CollectionModel.filtered(all, CollectionModel.default_filters())
	eq(sorted[0]["face"].kind, CardFace.KIND_CHARACTER, "characters first")
	var items := sorted.filter(func(entry: Dictionary) -> bool: return entry["face"].kind == CardFace.KIND_ITEM)
	var ranks := items.map(func(entry: Dictionary) -> int: return CardStyle.RARITY_ORDER.find(entry["face"].rarity))
	var ordered := ranks.duplicate()
	ordered.sort()
	eq(ranks, ordered, "items by rarity, lowest first")
	eq(sorted.back()["face"].kind, CardFace.KIND_EQUIPMENT, "armor last")
	eq(CollectionModel.page_count(sorted, 8), ceili(sorted.size() / 8.0), "pages of the size asked")
	eq(CollectionModel.page(sorted, 99, 8).size(), sorted.size() - (CollectionModel.page_count(sorted, 8) - 1) * 8, "the last page, short")
	var filters := CollectionModel.default_filters()
	filters["set"] = "descent"
	filters["kind"] = "item"
	filters["missing"] = false
	eq(CollectionModel.filtered(all, filters).map(func(entry: Dictionary) -> String: return entry["id"]), ["card.item.r1", "card.item.e1"],
		"set, kind and owned only, combined")
	filters = CollectionModel.default_filters()
	filters["rarities"] = ["legendary"]
	filters["pool"] = "Boss"
	eq(CollectionModel.filtered(all, filters).map(func(entry: Dictionary) -> String: return entry["id"]), ["card.item.boss2"], "rarity and pool")
	filters = CollectionModel.default_filters()
	filters["text"] = "  CARD.GEAR "
	eq(CollectionModel.filtered(all, filters).size(), 1, "search: trimmed, any case (the fixtures' names are their ids)")
	var local := CollectionModel.entries(faces, null, {}, {}, ["card.item.c2"])
	eq(local.filter(func(entry: Dictionary) -> bool: return CollectionModel.is_owned(entry)).size(),
		local.filter(func(entry: Dictionary) -> bool: return entry["face"].core).size() + 1, "local: core + the test pool")
	var unknown := CollectionModel.entries(faces, null, {}, {})
	check(unknown.all(func(entry: Dictionary) -> bool: return entry["state"] in ["core", "unknown"] and not entry["new"]),
		"no collection and no pool: no ownership shows")
	filters = CollectionModel.default_filters()
	filters["owned"] = false
	filters["missing"] = false
	eq(CollectionModel.filtered(unknown, filters).size(), unknown.filter(func(e: Dictionary) -> bool: return e["state"] == "unknown").size(),
		"unknown cards ignore the owned / missing filter")
	var retired := CollectionModel.rates_of(_catalog())
	retired["card.item.c2"]["retired"] = true
	retired["card.item.r1"]["retired"] = true
	var with_retired := CollectionModel.entries(faces, _owned_collection(), {}, retired)
	var ids := with_retired.map(func(entry: Dictionary) -> String: return entry["id"])
	check(not ids.has("card.item.c2") and ids.has("card.item.r1"), "a retired card shows only while owned")


func test_card_seen_keeps_the_new_set_per_player() -> void:
	var dir := "user://test_card_ui/seen_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var seen := CardSeen.open(dir, "ann")
	check(seen.ids.is_empty(), "a missing file: nothing seen")
	check(seen.mark("card.item.r1") and not seen.mark("card.item.r1"), "marked once")
	check(CardSeen.open(dir, "ann").has("card.item.r1"), "kept on disk")
	check(not CardSeen.open(dir, "bob").has("card.item.r1"), "per player")
	var file := FileAccess.open(dir.path_join("ann").path_join(CardSeen.FILE_NAME), FileAccess.WRITE)
	file.store_string("{broken")
	file.close()
	check(CardSeen.open(dir, "ann").ids.is_empty(), "a broken file: nothing seen")
	var memory := CardSeen.open("", "ann")
	memory.mark("x")
	eq(memory.path, "", "no folder: in memory only")


func test_offline_collection() -> void:
	var game := _card_game()
	game.local_card_pool = [&"card.item.c2"]
	var screen := await _open_collection(game)
	check(screen != null and screen.name == "Collection", "the Collection opens in local mode")
	var shown: Dictionary = screen.shown()
	check(not shown["actions"] and shown["message"].contains("Local mode"), "read-only, with the line: %s" % shown["message"])
	var states := {}
	for entry in screen.all_entries:
		states[entry["id"]] = entry["state"]
	eq([states["card.item.c1"], states["card.item.c2"], states["card.item.c3"]], ["core", "owned", "missing"], "core + the local pool")
	eq(shown["cards"].size(), 9, "only the owned at first: the 8 core cards and the pool's one")
	screen.set_filter("missing", true)
	eq(screen.shown()["cards"].size(), screen.per_page(), "a full page (the grid's columns x rows)")
	var detail: UIScreen = screen.open_detail("card.item.c3")
	await _frames(2)
	check(detail != null and detail.shown()["core_note"] and not detail.shown()["create_enabled"], "local mode: no Create")
	game.ui.back()
	await _frames(2)
	eq(game.ui.top(MODAL), null, "Back closes the detail")
	game.ui.back()
	await _frames(2)
	eq(String(game.ui.top(MENU).name), "MainMenu", "Back returns to the main menu")


func test_collection_shows_the_account_in_server_mode() -> void:
	var bridge := _card_bridge(_owned_collection(120, "Active"))
	var game := _card_game(bridge)
	var screen := await _open_collection(game)
	var shown: Dictionary = screen.shown()
	var owned: int = screen.all_entries.filter(func(entry: Dictionary) -> bool: return CollectionModel.is_owned(entry)).size()
	eq([shown["dust"], shown["gems"], shown["actions"], shown["count"]], [120, 340, true, owned],
		"dust, gems, actions on; only the owned cards at first (playtest 2026-11-18)")
	check(not screen.get_node("%Missing").button_pressed and screen.get_node("%Owned").button_pressed, "Owned on, Missing off")
	screen.set_filter("missing", true)
	eq(screen.shown()["count"], _catalog()["cards"].size(), "Missing adds the rest")
	eq(screen.get_node("%Dust").text, "120 dust", "the dust total")
	check(screen.get_node("%RunLine").visible, "the run line says cards are locked")
	screen.set_filter("kind", "item")
	screen.set_filter("missing", false)
	var cards := {}
	for card in screen.shown()["cards"]:
		cards[card["id"]] = card
	check(cards.has("card.item.e1") and cards["card.item.e1"]["locked"] and cards["card.item.e1"]["new"], "locked and NEW")
	var slot: Control = screen.get_node("%Page").slots["card.item.e1"]
	eq([slot.get_node("Chip").text, slot.get_node("New").visible], ["In your run", true], "the chip and the badge")
	screen.set_filter("missing", true)
	screen.set_filter("owned", false)
	var missing_slot: Control = screen.get_node("%Page").slots.values()[0]
	check(not missing_slot.has_node("Chip"), "no craft-cost chip under a missing card (playtest 2026-11-18: the detail shows it)")
	var views_before: Dictionary = screen.get_node("%Page").views.duplicate()
	screen.set_filter("text", "card")
	var kept: bool = views_before.keys().all(func(id: String) -> bool:
		return screen.get_node("%Page").views.get(id) == views_before[id])
	check(kept, "a filter that keeps the same cards keeps their views (no face rendered again)")
	eq(bridge.count("GetCardCatalog"), 1, "the catalog read once")
	var reads := bridge.count("GetCollection")
	await screen.refresh()
	eq(bridge.count("GetCardCatalog"), 1, "and kept for the session")
	eq(bridge.count("GetCollection"), reads + 1, "the collection read on every refresh")


func test_collection_reads_the_catalog_again_when_a_card_is_unknown() -> void:
	var collection := _owned_collection()
	collection["owned"].append({"cardId": "card.item.brand_new", "acquiredAt": "2026-11-01T10:00:00+00:00", "source": "pack",
		"lockedByRunId": null})
	var game := _card_game(_card_bridge(collection))
	var screen := await _open_collection(game)
	eq(game.server.card_catalog.is_empty(), false, "the catalog is kept")
	eq((game.server.bridge as FakeBridge).count("GetCardCatalog"), 2, "a card the cached catalog lacks: read again (once)")
	check(screen != null, "the screen still shows")


func test_collection_shows_no_ownership_without_a_session() -> void:
	var bridge := _card_bridge()
	var game := _card_game(bridge)
	await _frames(3)
	game.server.session_replaced = true
	var reads := bridge.count("GetCollection")
	var screen := await _open_collection(game)
	check(screen.all_entries.all(func(entry: Dictionary) -> bool: return entry["state"] in ["core", "unknown"]),
		"another login holds the account: nothing shows as owned or missing")
	check(not screen.shown()["actions"], "no actions")
	eq(bridge.count("GetCollection"), reads, "the account is not read")
	game.server.session_replaced = false
	game.server.session_changed.emit()
	await screen.loaded
	check(screen.shown()["actions"], "Use it here (a new session): the account shows again")


func test_collection_unreachable_offers_go_online() -> void:
	var bridge := _card_bridge()
	bridge.answers["StartAccountSession"] = [[false, {"status": 0, "errorCode": null, "title": "HttpRequestException", "detail": "offline"}]]
	var game := _card_game(bridge)
	game.server.account_session = 0
	var screen := await _open_collection(game)
	check(screen.get_node("%Online").visible, "Go online")
	check(screen.shown()["message"].begins_with("Can't reach the server"), "the line: %s" % screen.shown()["message"])
	check(screen.all_entries.all(func(entry: Dictionary) -> bool: return entry["state"] in ["core", "unknown"]), "no ownership")


func _open_detail(game: GameMain, id: String) -> UIScreen:
	var screen := await _open_collection(game)
	var detail: UIScreen = screen.open_detail(id)
	await _frames(2)
	return detail


func test_detail_dust_and_create() -> void:
	var bridge := _card_bridge(_owned_collection(400))
	bridge.answers["DustCard"] = [[true, {"cardId": "card.item.r1", "dustGained": 20, "rateVersion": 1, "dust": 420, "accountVersion": 4}]]
	var game := _card_game(bridge)
	var detail := await _open_detail(game, "card.item.r1")
	var before: Dictionary = detail.shown()
	eq([before["dust_enabled"], before["create_enabled"]], [true, false], "an owned card: Dust, no Create")
	var big: Control = detail.get_node("%Card").slots.values()[0]
	eq([big.focus_mode, big.has_node("Chip"), big.has_node("New")], [Control.FOCUS_NONE, false, false],
		"the big card takes no focus and shows no chip or badge (playtest 2026-11-18)")
	var page: CardPage = game.ui.top(MENU).get_node("%Page")
	eq(page.stage.viewport.render_target_update_mode, SubViewport.UPDATE_DISABLED, "the page under the detail stops rendering")
	eq(detail.get_node("%DustButton").text, "Dust  +20", "the dust value")
	var after_dust := _owned_collection(420)
	after_dust["owned"] = after_dust["owned"].slice(1)
	after_dust["accountVersion"] = 4
	bridge.answers["GetCollection"] = [[true, after_dust]]
	var dusting: Array = [null]
	var run := func() -> void: dusting[0] = await detail.dust()
	run.call()
	check(await _answer(game, true), "the dust asks first")
	await _until(func() -> bool: return dusting[0] != null)
	check(dusting[0]["ok"], "dusted")
	var shown: Dictionary = detail.shown()
	eq([shown["state"], shown["message"], shown["dust_enabled"]], ["missing", "Dusted: +20 dust.", false], "the card is missing now")
	eq(detail.get_node("%DustTotal").text, "420 dust", "the new total")
	check(shown["create_enabled"], "a Rare costs 100: 420 dust can create it again")
	eq(bridge.count("DustCard"), 1, "one dust")


func test_detail_create_asks_only_for_the_expensive_rarities() -> void:
	var bridge := _card_bridge(_owned_collection(2000))
	bridge.answers["CraftCard"] = [[true, {"cardId": "card.item.c2", "dustSpent": 40, "rateVersion": 1, "dust": 1960, "accountVersion": 4}]]
	var game := _card_game(bridge)
	var detail := await _open_detail(game, "card.item.c2")
	check(detail.shown()["create_enabled"], "a missing Common, enough dust")
	var answer: Dictionary = await detail.create()
	check(answer["ok"], "created without a pop-up")
	game.ui.back()
	await _frames(2)
	var screen: UIScreen = game.ui.top(MENU)
	var legendary: UIScreen = screen.open_detail("card.item.l1")
	await _frames(2)
	var made: Array = [null]
	var run := func() -> void: made[0] = await legendary.create()
	run.call()
	check(await _answer(game, false), "a Legendary asks first")
	await _until(func() -> bool: return made[0] != null)
	eq([made[0], bridge.count("CraftCard")], [{}, 1], "Cancel sends nothing")


func test_dust_cancel_run_from_the_detail() -> void:
	var bridge := _card_bridge(_owned_collection(120, "Active"))
	bridge.answers["DustCard"] = [[false, {"status": 409, "errorCode": 1403, "title": "Card locked by the run", "detail": "",
		"runId": "run-1", "runStatus": "Active"}], [true, {"cardId": "card.item.e1", "dustGained": 100, "rateVersion": 1, "dust": 220}]]
	bridge.answers["AbandonRun"] = [[true, null]]
	var game := _card_game(bridge)
	var detail := await _open_detail(game, "card.item.e1")
	check(detail.shown()["locked"] and detail.shown()["dust_enabled"], "a locked card can still be dusted (the pop-up is the way out)")
	var dusting: Array = [null]
	var run := func() -> void: dusting[0] = await detail.dust()
	run.call()
	check(await _answer(game, true), "the run-lock pop-up: Cancel run")
	await _until(func() -> bool: return dusting[0] != null)
	check(dusting[0]["ok"], "dusted after the cancel")
	eq(bridge.count("AbandonRun"), 1, "the run was cancelled")
	var keys := bridge.calls.filter(func(call: Array) -> bool: return call[0] == "DustCard").map(
		func(call: Array) -> String: return JSON.parse_string(call[2])["requestKey"])
	eq([keys.size(), keys[0] == keys[1]], [2, true], "the same key re-sent")


func test_dust_keep_run_sends_nothing() -> void:
	var bridge := _card_bridge(_owned_collection(120, "Active"))
	var game := _card_game(bridge)
	var detail := await _open_detail(game, "card.item.e1")
	var dusting: Array = [null]
	var run := func() -> void: dusting[0] = await detail.dust()
	run.call()
	check(await _answer(game, false), "Keep run")
	await _until(func() -> bool: return dusting[0] != null)
	eq([dusting[0], bridge.count("DustCard")], [{}, 0], "nothing sent")


func test_dust_verifying_message() -> void:
	var bridge := _card_bridge(_owned_collection(120, "Verifying"))
	var game := _card_game(bridge)
	var detail := await _open_detail(game, "card.item.e1")
	var answer: Dictionary = await detail.dust()
	eq([answer, bridge.count("DustCard")], [{}, 0], "nothing sent while the run is verified")
	check(detail.shown()["message"].contains("being verified"), "the wait message: %s" % detail.shown()["message"])
	# Second case: the server says Verifying (the collection was stale) on a card the screen thought free.
	var stale := _card_bridge(_owned_collection(120))
	stale.answers["DustCard"] = [[false, {"status": 409, "errorCode": 1403, "title": "Card locked by the run", "detail": "",
		"runId": "run-1", "runStatus": "Verifying"}]]
	var game2 := _card_game(stale)
	var detail2 := await _open_detail(game2, "card.item.r1")
	var dusting: Array = [null]
	var run := func() -> void: dusting[0] = await detail2.dust()
	run.call()
	check(await _answer(game2, true), "the dust confirm")
	await _until(func() -> bool: return dusting[0] != null)
	eq([stale.count("DustCard"), stale.count("AbandonRun")], [1, 0], "no cancel, no retry")
	check(detail2.shown()["message"].contains("being verified"), "the wait message")


func test_stale_refusals_refetch() -> void:
	var bridge := _card_bridge(_owned_collection(2000))
	bridge.answers["CraftCard"] = [[false, {"status": 409, "errorCode": 1413, "title": "Account version stale", "detail": "",
		"currentAccountVersion": 9}], [false, {"status": 409, "errorCode": 1402, "title": "Not enough dust", "detail": ""}]]
	var game := _card_game(bridge)
	var detail := await _open_detail(game, "card.item.c2")
	var reads := bridge.count("GetCollection")
	var answer: Dictionary = await detail.create()
	eq(CardAccount.code_of(answer), 1413, "a moved account")
	check(bridge.count("GetCollection") > reads, "the collection was read again")
	eq(detail.shown()["message"], "Your account changed. Here is what you have now.", "the line")
	var screen: UIScreen = game.ui.top(MENU)
	eq(screen.shown()["message"], "Your account changed. Here is what you have now.", "the Collection says so too")
	answer = await detail.create()
	eq(CardAccount.code_of(answer), 1402, "not enough dust")
	check(detail.shown()["message"].begins_with("Not enough dust"), "the line: %s" % detail.shown()["message"])


func test_detail_after_a_session_replaced_waits_for_use_it_here() -> void:
	var bridge := _card_bridge(_owned_collection(400))
	bridge.answers["DustCard"] = [[false, {"status": 409, "errorCode": 1412, "title": "Account session replaced", "detail": "",
		"currentSession": 7}]]
	var game := _card_game(bridge)
	var detail := await _open_detail(game, "card.item.r1")
	var dusting: Array = [null]
	var run := func() -> void: dusting[0] = await detail.dust()
	run.call()
	check(await _answer(game, true), "the dust confirm")
	await _until(func() -> bool: return dusting[0] != null)
	check(game.server.session_replaced, "the session is marked replaced")
	eq(detail.shown()["message"], "", "the detail says nothing: the pop-up's Use it here does")
	var screen: UIScreen = game.ui.top(MENU)
	check(not screen.shown()["actions"], "the Collection shows no ownership until Use it here")


func test_card_page_renders_faces_live_and_frees_them() -> void:
	var game := _card_game()
	var screen := await _open_collection(game)
	var page: CardPage = screen.get_node("%Page")
	screen.set_filter("missing", true)
	eq(page.views.size(), screen.per_page(), "one view per card on a full page")
	await _frames(2)
	var full_size: Vector2 = page.slots.values()[0].size
	screen.set_filter("text", "card.item.c2")
	await _frames(2)
	eq([page.slots.size(), page.slots.values()[0].size], [1, full_size],
		"one search match keeps the grid: the card keeps the size it has on a full page (playtest 2026-11-18)")
	screen.set_filter("text", "")
	await _frames(2)
	var first: CardView3D = page.views.values()[0]
	var viewport := first.viewport
	check(first.face_view != null and first.face_view.get_parent() == viewport, "each card renders its face in its own SubViewport")
	screen.turn(1)
	await _frames(2)
	check(not is_instance_valid(viewport), "a page change frees the old viewports")
	var style := CardStyle.current()
	var faces := CardFaces.build(CardWorld.content(), style)
	var still := CardView3D.new()
	var shiny := CardView3D.new()
	host.add_child(still)
	host.add_child(shiny)
	_nodes.append(still)
	_nodes.append(shiny)
	var common: CardFace = faces.filter(func(face: CardFace) -> bool: return face.rarity == "common")[0]
	var legendary: CardFace = faces.filter(func(face: CardFace) -> bool: return face.rarity == "legendary")[0]
	still.show_face(common, style, style.face_scene(), 1.0, 1.0)
	shiny.show_face(legendary, style, style.face_scene(), 1.0, 1.0)
	eq([still.live(), shiny.live()], [false, true], "a Common is still, a Legendary loops")
	eq(shiny.viewport.render_target_update_mode, SubViewport.UPDATE_ALWAYS, "a looping face redraws every frame")
	check(still.viewport.render_target_update_mode in [SubViewport.UPDATE_ONCE, SubViewport.UPDATE_DISABLED],
		"a still face draws once")
	still.set_render_scale(2.0)
	eq(still.viewport.size, Vector2i(ceili((300 + 60) * 2.0), ceili((420 + 60) * 2.0)), "sized to the card on screen, with the glow margin")


func test_main_menu_collection_opens_the_collection() -> void:
	var game := _card_game()
	await _frames(3)
	var menu := game.ui.top(MENU)
	check(not menu.get_node("%Collection").disabled, "Collection is enabled")
	menu.get_node("%Collection").pressed.emit()
	await _frames(3)
	eq(String(game.ui.top(MENU).name), "Collection", "Collection opens the Collection (local mode too)")


func test_cardui_collection_commands() -> void:
	var bridge := _card_bridge(_owned_collection(400))
	bridge.answers["DustCard"] = [[true, {"cardId": "card.item.r1", "dustGained": 20, "rateVersion": 1, "dust": 420, "accountVersion": 4}]]
	var game := _card_game(bridge)
	await _frames(2)
	var console := _console(game)
	for line in ["cardui collection", "cardui page 2", "cardui filter kind item", "cardui detail", "cardui open detail"]:
		check(not (await console.execute(line))["ok"], "'%s' is refused before the Collection opens" % line)
	var opened: Dictionary = await console.execute("cardui open collection")
	check(opened["ok"] and opened["text"].contains("page 1 /") and opened["text"].contains("dust 400"), "opened: %s" % opened["text"])
	check((await console.execute("cardui filter missing on"))["ok"], "Missing on: two pages")
	var paged: Dictionary = await console.execute("cardui page 2")
	check(paged["ok"] and paged["text"].begins_with("page 2 /"), "page 2: %s" % paged["text"])
	var filtered: Dictionary = await console.execute("cardui filter rarity epic")
	check(filtered["ok"] and filtered["text"].contains("card.item.e1") and not filtered["text"].contains("(common)"),
		"rarity filter: %s" % filtered["text"])
	for line in ["cardui filter rarity shiny", "cardui filter owned maybe", "cardui filter kind spell", "cardui filter colour red",
			"cardui page x", "cardui open detail card.nope"]:
		check(not (await console.execute(line))["ok"], "'%s' is refused" % line)
	var detail: Dictionary = await console.execute("cardui open detail card.item.r1")
	check(detail["ok"] and detail["text"].contains("\"dust_enabled\":true"), "the detail: %s" % detail["text"])
	check(not (await console.execute("cardui detail create"))["ok"], "Create refused on an owned card")
	var answering := func() -> void: await _answer(game, true)
	answering.call()
	var dusted: Dictionary = await console.execute("cardui detail dust")
	check(dusted["ok"] and dusted["text"].contains("Dusted: +20 dust."), "dusted: %s" % dusted["text"])


## User, 2026-11-18: every card its own glyph; only a Void card may share the glyph of the item it corrupts.
func test_cards_never_share_a_glyph_except_void_twins() -> void:
	var base := CardWorld.item("card.item.lantern", "Rare", CardWorld.DESCENT, ["Treasure"])
	var twin := CardWorld.item("card.item.corrupted_lantern", "Epic", CardWorld.DESCENT, ["Void"])
	twin.tags.append(&"Item.Corrupted")
	var other := CardWorld.item("card.item.other_lantern", "Rare", CardWorld.DESCENT, ["Treasure"])
	var list := CardWorld.resources()
	list.append_array([base, twin, other])
	var content := CardWorld.content(list)
	eq([CardIconPass.twin_of(content, "card.item.corrupted_lantern"), CardIconPass.twin_of(content, "card.item.lantern")],
		["card.item.lantern", ""], "a Void card's twin is the item it corrupts")
	var glyph := PlaceholderTexture2D.new()
	glyph.resource_path = "res://test/lantern.svg"
	var set := CardArtSet.new()
	set.textures = {&"card.item.lantern": glyph, &"card.item.corrupted_lantern": glyph}
	var style := CardStyle.new()
	style.art_sets = [set]
	var shared := CardStyleValidator.validate(style, content).filter(func(issue: ValidationIssue) -> bool:
		return issue.code == "card_icon_shared")
	eq(shared.size(), 0, "a Void card may share its item's glyph")
	set.textures[&"card.item.other_lantern"] = glyph
	shared = CardStyleValidator.validate(style, content).filter(func(issue: ValidationIssue) -> bool:
		return issue.code == "card_icon_shared")
	eq(shared.size(), 1, "two different cards may not")
	check(shared[0].path.contains("card.item.other_lantern") and shared[0].severity == ValidationIssue.ERROR, "an error naming both")
	var rows: Array[Dictionary] = [{"id": "a", "stem": "ring", "by": "keyword"}, {"id": "b", "stem": "ring", "by": "shared"},
		{"id": "c", "stem": "ring", "by": "twin"}]
	eq(CardIconPass.clashes(rows, content), ["ring is shared by a, b"], "the pass reports clashes, not twins")


# --- Isolation (spec 3.2) --------------------------------------------------------------------------------------------------

func test_the_card_presentation_stays_out_of_combat_the_verifier_and_the_ruleset() -> void:
	if skip_in_export():
		return
	check(not RulesetVersion.ROOTS.any(func(root: String) -> bool: return CardStyle.DEFAULT_PATH.begins_with(root)),
		"the card style is outside the ruleset roots")
	var names := ["CardStyle", "CardPackLook", "CardRarityLook", "CardPackView", "CardAccount", "ShopModel", "presentation/demo/cards",
		"presentation/demo/ui/cards", "CollectionModel", "CardSeen", "CardView3D", "CardPage", "PackReveal", "PackStage",
		"PackChoreography", "OpenPacksModel", "CardBackView"]
	for root in ["res://combat/", "res://game/verify/"]:
		for path in _scripts(root):
			var text := FileAccess.get_file_as_string(path)
			for name in names:
				check(not text.contains(name), "%s never names %s" % [path, name])


static func _scripts(root: String) -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open(root)
	if dir == null:
		return found
	for file in dir.get_files():
		if file.ends_with(".gd"):
			found.append(root.path_join(file))
	for sub in dir.get_directories():
		found.append_array(_scripts(root.path_join(sub)))
	return found


# --- Gate 3: Open packs and the pack reveal (spec card-ui 2.3, 2.4) ------------------------------------------------------------

const PACKS_SCENE: String = "res://presentation/demo/ui/cards/packs.tscn"


## A PackOpenResponse of the card fixtures: a duplicate Rare, an Epic, a pity Legendary.
static func _open_response(packs_left: int = 1) -> Dictionary:
	return {"openingId": "op-1", "packId": "descent-pack", "packVersion": 1, "gemsSpent": 0, "cards": [
		{"cardId": "card.item.c1", "rarity": "common", "duplicate": false, "dustGained": 0, "pity": false},
		{"cardId": "card.item.r1", "rarity": "rare", "duplicate": true, "dustGained": 20, "pity": false},
		{"cardId": "card.item.c2", "rarity": "common", "duplicate": false, "dustGained": 0, "pity": false},
		{"cardId": "card.item.e1", "rarity": "epic", "duplicate": false, "dustGained": 0, "pity": false},
		{"cardId": "card.item.l1", "rarity": "legendary", "duplicate": false, "dustGained": 0, "pity": true}],
		"gems": 340, "dust": 140, "drawSeed": "42", "packsLeft": packs_left, "accountVersion": 4}


func _pack_bridge() -> FakeBridge:
	var bridge := _card_bridge()
	bridge.answers["RefundPacks"] = [[true, {"refunded": []}]]
	return bridge


func _open_packs(game: GameMain) -> UIScreen:
	await _frames(2)
	var screen := game.ui.push(MENU, load(PACKS_SCENE))
	if screen != null and screen.loading:
		await screen.loaded
	return screen


func _open_bodies(bridge: FakeBridge) -> Array:
	return bridge.of("OpenPack").map(func(call: Array) -> Dictionary: return JSON.parse_string(call[2]))


func test_pack_reveal_slots_tiers_labels_and_order() -> void:
	var reveal := PackReveal.from_response(_open_response())
	eq(reveal.size(), 5, "five cards")
	eq(reveal.slots.map(func(slot: Dictionary) -> int: return slot["tier"]), [0, 1, 0, 2, 3], "tiers by rarity")
	eq([reveal.slots[1]["new"], reveal.slots[1]["dust"], reveal.slots[0]["new"]], [false, 20, true],
		"a duplicate gives dust; NEW only for a card not owned before the open")
	eq(reveal.dust_gained(), 20, "the dust of the duplicates")
	eq([reveal.packs_left, reveal.gems, reveal.dust], [1, 340, 140], "the totals after the open")
	eq(reveal.hidden(), [0, 1, 2, 3, 4], "all face down")
	check(reveal.reveal(3) and not reveal.reveal(3), "a card flips once")
	eq(reveal.next_hidden(), 0, "Space flips the first still face down")
	eq(reveal.rarity_line(3), "Epic", "the rarity word")
	eq([reveal.rarity_line(4), reveal.detail_line(4)], ["Legendary!", "NEW · Guaranteed"], "a big rarity and a pity card")
	eq(reveal.detail_line(1), "+20 dust", "a duplicate's dust")
	eq(reveal.reveal_all(), [0, 1, 2, 4], "Reveal all flips the rest in order")
	check(reveal.done(), "done")
	var demo := PackReveal.from_response(PackReveal.demo(CardCatalog.cards(CardWorld.content()), ["epic", "legendary"]))
	eq(demo.slots.map(func(slot: Dictionary) -> String: return slot["rarity"]), ["common", "common", "common", "epic", "legendary"],
		"a demo pads with common")
	check(demo.slots[1]["duplicate"] and demo.slots[4]["pity"], "the demo shows a duplicate and a pity card")


func test_open_packs_model_counts_pity_and_held_packs() -> void:
	var collection: Dictionary = COLLECTION.duplicate(true)
	collection["pity"] = [{"packId": "descent-pack", "missedPacks": {"epic": 7, "legendary": 8, "mythic": 12}}]
	collection["ownedPacks"].append({"packId": "retired-pack", "count": 1})
	var entries := OpenPacksModel.entries(PACKS, collection)
	eq(entries.map(func(entry: Dictionary) -> String: return entry["packId"]), ["descent-pack", "retired-pack"],
		"the list's order, then a retired type still owned; a held refund is left out")
	eq(entries[0]["count"], 2, "the count")
	eq(OpenPacksModel.pity_line(entries[0]), "Epic in 3 · Legendary in 12 · Mythic in 18 packs", "PityPacks - missed")
	eq(entries[1]["name"], "Retired Pack", "a type the list no longer carries (retired) is named from its id")
	eq(OpenPacksModel.odds_lines(entries[0])[0], "Common 72.10%", "odds in rarity order")
	eq(OpenPacksModel.entries(PACKS, null), [], "no collection, no packs")


func test_card_view_shows_a_back_and_flips() -> void:
	var stage := FxStage.new()
	host.add_child(stage)
	_nodes.append(stage)
	var view := CardView3D.new()
	stage.world_root.add_child(view)
	var face := CardFaces.build(CardWorld.content(), CardStyle.current())[0]
	view.show_face(face, CardStyle.current(), CardStyle.current().face_scene(), 1.0, 1.0)
	view.show_back(CardStyle.current(), true)
	check(view.face_down and view.back_mesh != null, "face down with a back")
	check(is_equal_approx(view.flipper.rotation.y, PI), "the back faces the camera")
	var tween := view.flip(0.05)
	check(tween != null and not view.face_down, "the flip starts")
	await tween.finished
	check(is_equal_approx(view.flipper.rotation.y, 0.0), "face up")
	check(view.flip(0.05) == null, "a face-up card does not flip again")


func test_open_packs_shows_the_owned_packs_and_pays_refunds() -> void:
	var bridge := _pack_bridge()
	bridge.answers["RefundPacks"] = [[true, {"refunded": [{"packId": "descent-pack", "count": 3, "gemsRefunded": 300}]}]]
	var game := _card_game(bridge)
	var screen := await _open_packs(game)
	var shown: Dictionary = screen.shown()
	eq(shown["packs"].map(func(pack: Dictionary) -> String: return "%s x%d" % [pack["packId"], pack["count"]]), ["descent-pack x2"],
		"the owned packs (a held refund is not openable)")
	eq([shown["gems"], shown["dust"]], [340, 120], "the totals")
	eq(shown["message"], "Your 3 Descent Packs were retired: +300 gems.", "the refund notice")
	eq(bridge.count("RefundPacks"), 1, "refunds are paid once, when the screen opens")
	var entry: Node = screen.get_node("%PackList").get_child(0)
	eq(entry.get_node("%Pack").count, 2, "the count badge")


func test_open_a_pack_plays_the_reveal() -> void:
	var bridge := _pack_bridge()
	bridge.answers["OpenPack"] = [[true, _open_response()]]
	var game := _card_game(bridge)
	var screen := await _open_packs(game)
	var after: Dictionary = _owned_collection()
	after["ownedPacks"] = [{"packId": "descent-pack", "count": 1}, {"packId": "old-pack", "count": 4, "refundHeld": true}]
	after["pity"] = [{"packId": "descent-pack", "missedPacks": {"epic": 4, "legendary": 4, "mythic": 4}}]
	var before_pity: String = screen.shown()["packs"][0]["pity"]
	bridge.answers["GetCollection"] = [[true, after]]   # the server's state once the pack is opened
	var answer: Dictionary = await screen.open_pack("descent-pack")
	check(answer["ok"], "opened")
	var shown: Dictionary = screen.shown()
	eq(shown["cards"].size(), 5, "five cards on the stage")
	check(shown["cards"].all(func(card: Dictionary) -> bool: return not card["revealed"] and card["labels"].is_empty()),
		"face down, no labels yet")
	eq(shown["packs"][0]["count"], 1, "the badge drops by one (PacksLeft)")
	check(shown["packs"][0]["pity"] != before_pity and shown["packs"][0]["pity"].contains("Epic in 6"),
		"the pity countdown changed with every card still face down (%s → %s)" % [before_pity, shown["packs"][0]["pity"]])
	check(screen.get_node("%RevealAll").visible and not screen.get_node("%Done").visible, "Reveal all, no Done yet")
	var stage: PackStage = screen.get_node("%Stage")
	check(stage.views.all(func(view: CardView3D) -> bool: return view.face_down), "every view shows its back")
	check(await screen.flip(4), "a click flips card 5")
	eq(Array(stage.labels_of(4)), ["Legendary!", "NEW · Guaranteed"], "its labels (the labels show with effects off too)")
	check(not await screen.flip(4), "once")
	await screen.reveal_all()
	eq(screen.shown()["cards"][1]["labels"], ["Rare", "+20 dust"], "a duplicate's dust")
	check(screen.shown()["done"] and screen.get_node("%Done").visible, "Done after the fifth")
	eq(screen.shown()["dust"], 140, "the dust total takes the duplicates")
	eq(bridge.count("OpenPack"), 1, "one open")
	await screen.done()
	eq(screen.shown()["cards"], [], "Done clears the stage")
	check(bridge.count("GetCollection") >= 2, "and reads the account again")


func test_lost_open_replays_same_cards() -> void:
	var bridge := _pack_bridge()
	bridge.answers["OpenPack"] = DOWN
	var game := _card_game(bridge)
	var screen := await _open_packs(game)
	var answer := {}
	var press := func() -> void: answer.merge(await screen.open_pack("descent-pack"))
	press.call()
	var account := game.server.card_account()
	check(await _until(func() -> bool: return account.reconnecting_seconds() >= 0.0), "reconnecting")
	eq(game.server.waiting_text(), "Reconnecting to the server…", "the connecting pop-up says so")
	check(screen.get_node("%Stage").pack != null, "the pack waits in the socket")
	game.ui.back()
	eq(game.ui.top(MENU), screen, "Back waits for the open")
	# The commit landed but its answer was lost: the server answers the same key with the stored response.
	bridge.answers["OpenPack"] = [[true, _open_response()]]
	check(await _until(func() -> bool: return not answer.is_empty()), "the server answers")
	check(answer["ok"], "the stored response")
	eq(screen.shown()["cards"].map(func(card: Dictionary) -> String: return card["id"]),
		["card.item.c1", "card.item.r1", "card.item.c2", "card.item.e1", "card.item.l1"], "the same five cards, revealed once")
	var keys := _open_bodies(bridge).map(func(body: Dictionary) -> String: return body["requestKey"])
	check(keys.size() >= 2 and keys.all(func(key: String) -> bool: return key == answer["key"]), "one key for every try")


func test_stale_pack_count() -> void:
	var bridge := _pack_bridge()
	bridge.answers["OpenPack"] = [[false, {"status": 409, "errorCode": 1411, "title": "NoPackOwned", "detail": ""}]]
	var game := _card_game(bridge)
	var screen := await _open_packs(game)
	var reads := bridge.count("GetCollection")
	var after := _owned_collection()
	after["ownedPacks"] = []
	bridge.answers["GetCollection"] = [[true, after]]
	var answer: Dictionary = await screen.open_pack("descent-pack")
	check(not answer["ok"], "refused")
	var shown: Dictionary = screen.shown()
	eq(shown["message"], "You have no pack of this kind left.", "the line")
	eq(shown["packs"], [], "the count corrected from the server")
	check(bridge.count("GetCollection") > reads, "the collection read again")
	eq(shown["cards"], [], "no reveal")
	check(screen.get_node("%Empty").visible, "the Shop line")


func test_pack_unavailable() -> void:
	var bridge := _pack_bridge()
	bridge.answers["OpenPack"] = [[false, {"status": 404, "errorCode": 1408, "title": "PackUnavailable", "detail": ""}]]
	var game := _card_game(bridge)
	var screen := await _open_packs(game)
	var packs_reads := bridge.count("GetPacks")
	await screen.open_pack("descent-pack")
	eq(screen.shown()["message"], "This pack cannot be opened right now.", "the line")
	check(bridge.count("GetPacks") > packs_reads, "the pack list read again")
	eq(screen.shown()["packs"][0]["count"], 2, "the pack stays owned")


func test_back_reveals_all() -> void:
	var bridge := _pack_bridge()
	bridge.answers["OpenPack"] = [[true, _open_response()]]
	var game := _card_game(bridge)
	var screen := await _open_packs(game)
	await screen.open_pack("descent-pack")
	var stage: PackStage = screen.get_node("%Stage")
	check(game.ui.back(), "Back is taken")
	eq(game.ui.top(MENU), screen, "the screen stays while the cards flip")
	var flipped := []
	stage.card_flipped.connect(func(index: int) -> void: flipped.append(index))
	var id := screen.get_instance_id()
	check(await _until(func() -> bool: return game.ui.top(MENU) == null or game.ui.top(MENU).get_instance_id() != id), "then it leaves")
	eq(flipped.size(), 5, "every card was flipped first")


func test_reveal_without_fx() -> void:
	check(not FxManager.enabled, "effects are inert headless")
	var game := _card_game()
	var screen := await _open_packs(game)
	eq(screen.shown()["message"], "Opening packs needs a server connection. Packs, gems and cards live on the server.", "local mode")
	var demo: PackReveal = await screen.play_demo(["epic", "legendary", "mythic"])
	check(demo != null and demo.size() == 5, "the demo plays offline")
	await screen.reveal_all()
	var cards: Array = screen.shown()["cards"]
	check(cards.all(func(card: Dictionary) -> bool: return card["labels"].size() == 2), "every label shows without effects")
	eq(cards[4]["labels"][0], "Mythic!", "the last card")


func test_cardui_pack_commands() -> void:
	var game := _card_game()
	await _frames(3)
	var console := _console(game)
	var refused: Dictionary = await console.execute("cardui pack descent-pack")
	check(not refused["ok"] and refused["text"].contains("not in server mode"), "a real open needs the server: " + refused["text"])
	var demo: Dictionary = await console.execute("cardui pack demo rare epic")
	check(demo["ok"] and demo["text"].contains("demo pack on the stage") and demo["text"].contains("face down"), demo["text"])
	var bad: Dictionary = await console.execute("cardui reveal 9")
	check(not bad["ok"] and bad["text"].contains("usage"), bad["text"])
	var one: Dictionary = await console.execute("cardui reveal 5")
	check(one["ok"] and one["text"].contains("card 5") and one["text"].contains("Epic / NEW"), one["text"])
	var all: Dictionary = await console.execute("cardui reveal all")
	check(all["ok"] and all["text"].contains("all revealed"), all["text"])
	var done: Dictionary = await console.execute("cardui done")
	check(done["ok"] and not done["text"].contains("card 1"), done["text"])
	var wrong: Dictionary = await console.execute("cardui pack demo shiny")
	check(not wrong["ok"] and wrong["text"].contains("no rarity"), wrong["text"])
	var logged: Dictionary = await console.execute("cardui log on")
	eq(logged["text"], "account log on", "the account log")
	CardAccount.log_actions = false


func test_cardui_pack_opens_through_the_account() -> void:
	var bridge := _pack_bridge()
	bridge.answers["OpenPack"] = [[true, _open_response()]]
	var game := _card_game(bridge)
	await _frames(3)
	var console := _console(game)
	var opened: Dictionary = await console.execute("cardui pack descent-pack")
	check(opened["ok"] and opened["text"].contains("opened [key") and opened["text"].contains("card 5: card.item.l1"), opened["text"])
	var waited: Dictionary = await console.execute("cardui wait opened 1")
	check(waited["ok"] and waited["text"].contains("card 1"), waited["text"])
	var all: Dictionary = await console.execute("cardui reveal all")
	check(all["ok"] and all["text"].contains("all revealed"), all["text"])
	eq(bridge.count("OpenPack"), 1, "one open")


func test_main_menu_open_packs_opens_the_pack_screen() -> void:
	var game := _card_game(_pack_bridge())
	await _frames(6)
	var menu := game.ui.top(MENU)
	check(not menu.get_node("%OpenPacks").disabled, "Open packs is enabled")
	menu.get_node("%OpenPacks").pressed.emit()
	await _frames(3)
	eq(String(game.ui.top(MENU).name), "Packs", "Open packs opens the pack screen")


## Review fix: a first open's countdown starts at the first guarantee (the server's PackDrawer.InitialMissed), not at the pity.
func test_open_packs_first_open_counts_from_the_first_guarantee() -> void:
	var packs: Dictionary = PACKS.duplicate(true)
	packs["packs"][0]["firstGuarantees"] = {"epic": 5, "legendary": 10, "mythic": 15}
	var entries := OpenPacksModel.entries(packs, COLLECTION)
	eq(OpenPacksModel.pity_line(entries[0]), "Epic in 5 · Legendary in 10 · Mythic in 15 packs", "no counters yet: the first guarantee")
	var opened: Dictionary = COLLECTION.duplicate(true)
	opened["pity"] = [{"packId": "descent-pack", "missedPacks": {"epic": 1}}]
	eq(OpenPacksModel.pity_line(OpenPacksModel.entries(packs, opened)[0]), "Epic in 9 · Legendary in 20 · Mythic in 30 packs",
		"after the first open the server's counters count")


## Review fixes: Reveal all announces the end once, after the last card has turned; Enter on a face-up card flips the next one.
func test_reveal_all_announces_once_and_enter_flips_the_next() -> void:
	var bridge := _pack_bridge()
	bridge.answers["OpenPack"] = [[true, _open_response()]]
	var game := _card_game(bridge)
	var screen := await _open_packs(game)
	await screen.open_pack("descent-pack")
	var stage: PackStage = screen.get_node("%Stage")
	await screen.flip(0)
	var enter := InputEventAction.new()
	enter.action = &"ui_accept"
	enter.pressed = true
	stage._on_slot_input(enter, 0)
	check(screen.reveal.slots[1]["revealed"], "Enter on the face-up first card flipped the second")
	check(stage.slots[1].has_focus(), "which took the focus")
	var announced := [0]
	screen.revealed.connect(func() -> void: announced[0] += 1)
	var turning := [true]
	stage.all_revealed.connect(func() -> void: turning[0] = stage.views.any(func(view: CardView3D) -> bool:
		return not is_equal_approx(view.flipper.rotation.y, 0.0)))
	await screen.reveal_all()
	await _frames(30)
	eq(announced[0], 1, "revealed once")
	check(not turning[0], "after every card has turned")


func test_cards_fan_from_the_socket_and_show_no_focus_ring() -> void:
	var bridge := _pack_bridge()
	bridge.answers["OpenPack"] = [[true, _open_response()]]
	var game := _card_game(bridge)
	var screen := await _open_packs(game)
	var stage: PackStage = screen.get_node("%Stage")
	var socket := stage._pack_rect().get_center()
	var first_seen: Array = []
	stage.child_entered_tree.connect(func(node: Node) -> void:
		if node.name.begins_with("Slot") and first_seen.is_empty():
			first_seen.append((node as Control).position + (node as Control).size * 0.5))
	await screen.open_pack("descent-pack")
	eq(first_seen.size(), 1, "a card slot was built")
	var place: Vector2 = stage._places()[0].get_center()
	check(first_seen[0].distance_to(socket) < 40.0 and first_seen[0].distance_to(place) > 100.0,
		"the cards start in the socket (%s, socket %s), never at their places (%s)" % [first_seen[0], socket, place])
	check(stage.slots[0].has_focus(), "the first card holds the focus")
	check(not FileAccess.get_file_as_string("res://game/cards/pack_stage.gd").contains("&\"focus\""), "and no card draws a focus ring")


func test_card_flip_takes_its_seconds() -> void:
	var stage := FxStage.new()
	host.add_child(stage)
	_nodes.append(stage)
	var view := CardView3D.new()
	stage.world_root.add_child(view)
	view.show_back(CardStyle.current(), true)
	var start := Time.get_ticks_msec()
	await view.flip(0.2).finished
	var took := (Time.get_ticks_msec() - start) / 1000.0
	check(took < 0.28, "the settle runs beside the turn: %.2f s for a 0.2 s flip" % took)
	check(is_equal_approx(view.flipper.position.z, 0.0), "settled")


func test_pack_sounds_ring_out_and_fade_when_the_stage_leaves() -> void:
	var plan := PackChoreography.new()
	for tier in 5:
		var id := plan.flip_sound(tier)
		check(ResourceLoader.exists(SfxBank.bank_path(id)), "the %d flip sound %s is in the bank" % [tier, id])
	var bank := SfxBank.load_manifest()
	for row in bank.entries():
		if str(row["id"]).begins_with("pack.flip."):
			check(int(row["measured"][0]["ms"]) > 200, "%s keeps its tail (%d ms)" % [row["id"], row["measured"][0]["ms"]])
	var stage := PackStage.new()
	host.add_child(stage)
	for index in 6:
		stage._play_sound("pack.flip.legendary")
	var voices: Array = stage._voices.duplicate()
	eq(voices.size(), 6, "overlapping sounds each get their own voice, none is cut by the next")
	check(voices.all(func(v): return v.get_parent().name == PackStage.VOICE_HOST), "the voices live outside the stage")
	stage.queue_free()
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	var ringing: AudioStreamPlayer = voices[0]
	check(is_instance_valid(ringing) and ringing.playing, "the screen closed: the sound still rings")
	check(ringing.volume_db < 0.0, "and is fading out (%.1f dB)" % ringing.volume_db)
	await host.get_tree().create_timer(plan.sound_fade_seconds + 0.2).timeout
	check(voices.all(func(v): return not is_instance_valid(v)), "after the fade every voice is gone")


func test_big_reveal_effects_by_rarity_and_the_alternatives_exist() -> void:
	var plan := PackChoreography.new()
	eq([plan.big_reveal_fx(2), plan.big_reveal_fx(3), plan.big_reveal_fx(4)], [&"", &"fx.reveal_halo", &"fx.reveal_rays"],
		"nothing below Legendary; the halo on a Legendary, the short rays on a Mythic (the user's picks)")
	plan.mythic_fx = &""
	eq(plan.big_reveal_fx(4), &"fx.reveal_halo", "a Mythic with no pick of its own takes the Legendary's")
	plan.mythic_fx = &"fx.legendary_rays"
	eq(plan.big_reveal_fx(4), &"fx.legendary_rays", "a Mythic's own pick")
	plan.mythic_fx = &"none"
	eq(plan.big_reveal_fx(4), &"", "none is none")
	var registry := load("res://presentation/demo/fx/fx_registry.tres") as FxRegistry
	var ids := registry.all()
	for id in [&"fx.reveal_rays", &"fx.reveal_halo"]:
		check(ids.has(id), "%s is registered" % id)
	check(ids[&"fx.reveal_rays"].layers[0].duration < ids[&"fx.legendary_rays"].layers[0].duration, "the short rays are shorter")
	for id in [&"fx.reveal_rays", &"fx.reveal_halo"]:
		eq(ids[id].space, FxDefinition.Space.UI, "%s plays over the screen, not clipped by the stage's viewport" % id)
	var halo: FxShaderQuadLayer = ids[&"fx.reveal_halo"].layers[0]
	check(exp(-float(halo.shader_params["falloff"]) * halo.grow) < 0.002, "the halo has faded out before its quad's edge (no box)")


func test_face_down_cards_glow_only_when_selected_and_walk_in_one_order() -> void:
	var bridge := _pack_bridge()
	bridge.answers["OpenPack"] = [[true, _open_response()]]
	var game := _card_game(bridge)
	var screen := await _open_packs(game)
	await screen.open_pack("descent-pack")
	var stage: PackStage = screen.get_node("%Stage")
	eq(stage._tells.size(), 0, "no card glows its rarity until it is hovered or selected")
	stage.slots[3].grab_focus()
	await _frames(1)
	eq(stage._tells.keys(), [3], "the card the keyboard selects glows")
	stage.slots[4].grab_focus()
	await _frames(1)
	eq(stage._tells.keys(), [4], "and stops when the selection moves on")
	for index in 5:
		var slot: Control = stage.slots[index]
		eq(slot.get_node(slot.focus_neighbor_right), stage.slots[(index + 1) % 5], "right from card %d goes to the next" % index)
		eq(slot.get_node(slot.focus_neighbor_bottom), stage.slots[(index + 1) % 5], "down too")
		eq(slot.get_node(slot.focus_neighbor_left), stage.slots[(index + 4) % 5], "left from card %d goes back" % index)
	await screen.flip(4)
	eq(stage._tells.size(), 0, "a card face up glows no more")


func test_the_pack_reveal_demo_opens_made_up_packs_and_swaps_effects() -> void:
	var demo: Control = load("res://game/dev/pack_reveal_demo.tscn").instantiate()
	host.add_child(demo)
	_nodes.append(demo)
	var deadline := Time.get_ticks_msec() + 20000
	while (demo.stage == null or demo.stage.reveal == null or demo.stage.busy) and Time.get_ticks_msec() < deadline:
		await _frames(1)
	eq(demo.stage.slots.size(), 5, "a made-up pack on the stage")
	eq(demo.stage.reveal.opening_id, "demo", "a demo opening, nothing from the server")
	demo._mythic.select(2)
	demo._mythic.item_selected.emit(2)
	eq(demo.stage.choreography().big_reveal_fx(4), demo._picked(demo._mythic), "the picker sets the stage's Mythic reveal")
	check(demo.stage.choreography() != CardStyle.current().pack_choreography(), "on a copy: the style is not changed")
	await demo.stage.flip_all()
	check(demo.stage.reveal.done(), "every card revealed")


func test_space_or_enter_opens_the_next_pack_and_after_a_reveal_the_one_after() -> void:
	var bridge := _pack_bridge()
	bridge.answers["OpenPack"] = [[true, _open_response()], [true, _open_response()]]
	var game := _card_game(bridge)
	var screen := await _open_packs(game)
	var accept := InputEventAction.new()
	accept.action = &"ui_accept"
	accept.pressed = true
	screen._unhandled_input(accept)
	var deadline := Time.get_ticks_msec() + 10000
	while (screen.reveal == null or screen.opening) and Time.get_ticks_msec() < deadline:
		await _frames(1)
	eq(bridge.count("OpenPack"), 1, "Space / Enter with an empty stage opens a pack")
	screen._unhandled_input(accept)
	await _frames(5)
	check(screen.reveal.slots[0]["revealed"] and bridge.count("OpenPack") == 1, "with cards face down it flips the next instead")
	await screen.reveal_all()
	await _frames(30)
	var first: PackReveal = screen.reveal
	screen._unhandled_input(accept)
	deadline = Time.get_ticks_msec() + 10000
	while (screen.reveal == null or screen.reveal == first or screen.opening) and Time.get_ticks_msec() < deadline:
		await _frames(1)
	eq(bridge.count("OpenPack"), 2, "with every card face up it clears the stage and opens the next pack")


func test_the_3d_pack_bulges_toward_the_camera_and_the_foil_demo_builds() -> void:
	var middle := (CardPack3D.ROWS / 2) * (CardPack3D.COLUMNS + 1) + CardPack3D.COLUMNS / 2
	var seal_row := 2 * (CardPack3D.COLUMNS + 1) + CardPack3D.COLUMNS / 2   # inside the top seal
	for flip in [false, true]:
		var arrays := CardPack3D.pouch(1.0, 1.52, 0.05, 0.085, flip).surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var side := -1.0 if flip else 1.0
		check(is_equal_approx(vertices[middle].z * side, 0.05), "%s: the body stands off the seal plane" % ["front", "back"][int(flip)])
		check(is_zero_approx(vertices[seal_row].z), "the seal lies flat, pressed against the other face")
		check(normals[middle].z * side > 0.9, "its normals face outward (the back is a real back, seen from behind)")
	var quarter := (CardPack3D.ROWS / 2) * (CardPack3D.COLUMNS + 1) + CardPack3D.COLUMNS / 4
	var front := CardPack3D.pouch(1.0, 1.52, 0.05, 0.085, false).surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array
	check(front[quarter].z > 0.048, "flat across most of the face, not a balloon (%.3f at a quarter)" % front[quarter].z)
	var demo: Control = load("res://game/dev/pack_foil_demo.tscn").instantiate()
	host.add_child(demo)
	_nodes.append(demo)
	await _frames(3)
	eq(demo._solid.size(), 2, "the metallic and the holographic 3D pack")


func test_a_cancelled_pack_never_takes_the_next_ones_3d_model() -> void:
	var stage := PackStage.new()
	stage.size = Vector2(1200, 800)
	host.add_child(stage)
	_nodes.append(stage)
	var look := CardStyle.current().pack("descent-pack")
	stage.socket_pack(look, "A")
	await _frames(2)
	var first := stage.pack_3d
	stage.cancel_pack()
	stage.socket_pack(look, "B")
	var second := stage.pack_3d
	await host.get_tree().create_timer(0.4).timeout
	check(not is_instance_valid(first), "the cancelled pack's 3D model is gone")
	check(is_instance_valid(second) and stage.pack_3d == second, "the new pack's 3D model is still there after the fade")


func test_enter_under_a_dialog_opens_nothing_and_done_leaves_the_focus_on_the_column() -> void:
	var bridge := _pack_bridge()
	bridge.answers["OpenPack"] = [[true, _open_response()]]
	var game := _card_game(bridge)
	var screen := await _open_packs(game)
	game.ui.notify("a notice")
	await _frames(2)
	var accept := InputEventAction.new()
	accept.action = &"ui_accept"
	accept.pressed = true
	screen._unhandled_input(accept)
	await _frames(3)
	eq(bridge.count("OpenPack"), 0, "Enter with a dialog up opens no pack behind it")
	check(await _answer(game, true), "the notice closes")
	await screen.open_pack("descent-pack")
	await screen.reveal_all()
	await _frames(20)
	await screen.done()
	await _frames(2)
	var owner := screen.get_viewport().gui_get_focus_owner()
	check(owner != null and screen.is_ancestor_of(owner), "after Done the focus is on the screen (%s), not lost" % owner)


func test_a_refresh_behind_the_buy_confirm_does_not_drop_the_buy() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [[true, {"packId": "descent-pack", "packVersion": 1, "count": 1, "gemsSpent": 100, "gems": 240,
		"owned": 3}]]
	var game := _game(bridge)
	var shop := await _open_shop(game)
	shop.get_node("%Offers").get_child(0).get_node("%Buy1").pressed.emit()
	await _frames(2)
	shop._on_session_changed()   # a session change while the pop-up is up
	check(not shop.loading, "no refresh starts behind the confirm")
	shop.refresh()   # one started anyway (the screen's own)
	check(await _answer(game, true), "Buy")
	var deadline := Time.get_ticks_msec() + 5000
	while bridge.count("BuyPack") == 0 and Time.get_ticks_msec() < deadline:
		await _frames(1)
	eq(bridge.count("BuyPack"), 1, "the confirmed buy goes through once the refresh is done")


func test_a_session_change_behind_the_buy_confirm_refreshes_once_it_is_answered() -> void:
	var game := _game(_bridge())
	var shop := await _open_shop(game)
	var reads := [0]
	shop.loaded.connect(func() -> void: reads[0] += 1)
	shop.get_node("%Offers").get_child(0).get_node("%Buy1").pressed.emit()
	await _frames(2)
	shop._on_session_changed()
	check(not shop.loading, "nothing refreshes behind the pop-up")
	check(await _answer(game, false), "Cancel")
	var deadline := Time.get_ticks_msec() + 5000
	while reads[0] == 0 and Time.get_ticks_msec() < deadline:
		await _frames(1)
	eq(reads[0], 1, "the skipped refresh runs once the pop-up is answered")
