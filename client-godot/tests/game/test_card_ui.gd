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
	check(entry.get_node("%Buy1").disabled, "the buttons disable while the buy is on its way")
	entry.get_node("%Buy1").pressed.emit()
	await _frames(4)
	eq(bridge.count("BuyPack"), 1, "one purchase")


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
	popup.give_up_after = 0.0
	var answer := {}
	var press := func() -> void: answer.merge(await shop.buy("descent-pack", 1))
	press.call()
	check(await _until(func() -> bool: return popup.offers_give_up(), 600), "the pop-up offers to stop waiting")
	var fetched := bridge.count("GetCollection")
	popup.get_node("%GiveUp").pressed.emit()
	check(await _until(func() -> bool: return not answer.is_empty() and not shop.loading), "the buy settles")
	check(answer["given_up"], "given up")
	eq(shop.shown()["message"], "We couldn't confirm your purchase. Your gems and packs show what the server has.", "the line")
	check(bridge.count("GetCollection") > fetched, "the Shop fetched the server's state")
	var buy1: Button = shop.get_node("%Offers").get_child(0).get_node("%Buy1")
	check(await _until(func() -> bool: return not game.server.card_account().busy() and not shop.loading and not buy1.disabled),
		"once the last try is back, the Shop refetches and can buy again")
	eq(shop.shown()["message"], "We couldn't confirm your purchase. Your gems and packs show what the server has.", "the line stays")


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


# --- Isolation (spec 3.2) --------------------------------------------------------------------------------------------------

func test_the_card_presentation_stays_out_of_combat_the_verifier_and_the_ruleset() -> void:
	if skip_in_export():
		return
	check(not RulesetVersion.ROOTS.any(func(root: String) -> bool: return CardStyle.DEFAULT_PATH.begins_with(root)),
		"the card style is outside the ruleset roots")
	var names := ["CardStyle", "CardPackLook", "CardRarityLook", "CardPackView", "CardAccount", "ShopModel", "presentation/demo/cards",
		"presentation/demo/ui/cards"]
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
