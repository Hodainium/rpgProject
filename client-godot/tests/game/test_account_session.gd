## Spec account-session (slice 5b1), the Godot half: the session is the login (started right after the first sign-in, kept
## through a token refresh), every account-changing call carries it and decisions also carry the account version, the client
## keeps an answer's version only when it is the one sent + 1 (never from refunds), a 1413 takes the current version, a 1412
## blocks account calls until the player takes the account back, giving up starts a new session, a run finished offline still
## syncs after a new session, Go online signs in again, the Shop's gate and buttons, and the console's `server session`.
## A fake bridge only: no server, and the user's content cannot fail these.
extends TestCase

const ServerMode := preload("res://tests/game/test_server_mode.gd")
const FakeBridge = preload("res://tests/game/test_server_mode.gd").FakeBridge
const RUN_ID: String = "019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b"
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic"]
const TWO_FLOORS: StringName = &"fixture.run.two_floors"
const MENU: StringName = &"UI.Layer.Menu"
const SHOP_SCENE: String = "res://presentation/demo/ui/cards/shop.tscn"

const PACKS := {"packs": [{"packId": "descent-pack", "name": "Descent Pack", "version": 1, "priceGems": 100, "cardCount": 5,
	"oddsPer10000": {"common": 10000}, "setIds": ["descent"], "cardIds": [], "pityPacks": {}, "firstGuarantees": {},
	"minRarityPerPack": null}]}

var _nodes: Array[Node] = []
var _games: Array[GameMain] = []


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


static func _collection(account_version: int, gems: int = 300) -> Dictionary:
	return {"owned": [], "gems": gems, "dust": 0, "accountVersion": account_version, "activeRunId": null, "activeRunStatus": null,
		"pity": [], "ownedPacks": []}


static func _session(session: int, account_version: int = 5) -> Array:
	return [true, {"session": session, "collection": _collection(account_version)}]


static func _bought(account_version: int, owned: int = 1) -> Array:
	return [true, {"packId": "descent-pack", "packVersion": 1, "count": 1, "gemsSpent": 100, "gems": 200, "owned": owned,
		"accountVersion": account_version}]


static func _refused(code: int, extra: Dictionary = {}) -> Array:
	var body := {"status": 409, "errorCode": code, "title": "refused", "detail": ""}
	body.merge(extra)
	return [false, body]


func _bridge() -> FakeBridge:
	var bridge := FakeBridge.new()
	bridge.answers["StartAccountSession"] = [_session(1)]
	bridge.answers["GetPacks"] = [[true, PACKS]]
	bridge.answers["GetCollection"] = [[true, _collection(5)]]
	bridge.answers["GetCurrentRun"] = [[true, null]]
	bridge.answers["GetFloorSeed"] = [[true, {"runId": RUN_ID, "floor": 1, "floorSeed": "777"}]]
	return bridge


func _link(bridge: FakeBridge) -> ServerLink:
	var link := ServerLink.new(bridge)
	link.retry_base_seconds = 0.01
	link.retry_max_seconds = 0.02
	link.poll_seconds = 0.01
	link.player = "tester"
	link.url = "http://fake:5000"
	link.saves_dir = "user://test_account_session/%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	host.add_child(link)
	_nodes.append(link)
	return link


func _until(condition: Callable, frames: int = 600) -> bool:
	for frame in frames:
		if condition.call():
			return true
		await host.get_tree().process_frame
	return condition.call()


static func _body(bridge: FakeBridge, method: String, index: int = -1) -> Dictionary:
	var call: Array = bridge.of(method)[index]
	return JSON.parse_string(call[-1])


# --- the session is the login (2.1) ------------------------------------------------------------------------------------------

func test_the_first_sign_in_starts_a_session_and_a_token_refresh_keeps_it() -> void:
	var bridge := _bridge()
	bridge.answers["GetPacks"] = [[false, {"status": 401, "errorCode": null, "title": "Unauthorized", "detail": ""}], [true, PACKS]]
	var link := _link(bridge)
	var heard := []
	link.session_changed.connect(func() -> void: heard.append(link.account_session))
	var packs: Dictionary = await link.get_packs()
	check(packs["ok"], "answered after one fresh token")
	eq(bridge.count("GetDevToken"), 2, "the 401 fetched a second token")
	eq(bridge.count("StartAccountSession"), 1, "but kept the session: a refreshed token is the same login")
	eq([link.account_session, link.card_account().account_version], [1, 5], "the session and the snapshot's account version")
	eq(heard, [1], "session_changed told the screens")


func test_go_online_from_offline_mode_signs_in_and_starts_a_session() -> void:
	var bridge := _bridge()
	bridge.offline = true
	var link := _link(bridge)
	var down: Dictionary = await link.get_packs()
	check(not down["ok"] and link.account_session == 0, "offline: no session")
	bridge.offline = false
	var online: Dictionary = await link.go_online()
	check(online["ok"], "Go online works once the server answers")
	eq(link.account_session, 1, "signed in and logged in")


# --- the fence on every account-changing call (2.2) -------------------------------------------------------------------------

func test_every_fenced_call_carries_the_session_and_decisions_the_account_version() -> void:
	var bridge := _bridge()
	bridge.answers["StartAccountSession"] = [_session(7, 12)]
	bridge.answers["BuyPack"] = [_bought(13)]
	bridge.answers["OpenPack"] = [[true, {"openingId": "o", "packId": "descent-pack", "packVersion": 1, "gemsSpent": 0, "cards": [],
		"gems": 200, "dust": 0, "drawSeed": "1", "packsLeft": 0, "accountVersion": 14}]]
	bridge.answers["DustCard"] = [[true, {"cardId": "item.a", "dustGained": 5, "rateVersion": 1, "dust": 5, "accountVersion": 15}]]
	bridge.answers["CraftCard"] = [[true, {"cardId": "item.b", "dustSpent": 5, "rateVersion": 1, "dust": 0, "accountVersion": 16}]]
	bridge.answers["RefundPacks"] = [[true, {"refunded": []}]]
	bridge.answers["AbandonRun"] = [[true, null]]
	bridge.answers["StartRun"] = [[true, {"runId": RUN_ID, "floor": 0, "floorSeed": "5150", "startedAt": "2026-11-18T00:00:00+00:00"}]]
	var link := _link(bridge)
	await link.buy_pack("descent-pack", 1, ServerLink.new_request_key())
	await link.open_pack("descent-pack", ServerLink.new_request_key())
	await link.dust_card("item.a", ServerLink.new_request_key())
	await link.craft_card("item.b", ServerLink.new_request_key())
	await link.refund_packs()
	await link.abandon_run(RUN_ID)
	await link.start_run("4.7.2.stable.mono+0123456789abcdef", "fixture.run.two_floors", PARTY)
	var versions: Array = []
	for method in ["BuyPack", "OpenPack", "DustCard", "CraftCard"]:
		var body := _body(bridge, method)
		eq(int(body["session"]), 7, "%s carries the session" % method)
		versions.append(int(body["expectedAccountVersion"]))
	eq(versions, [12, 13, 14, 15], "each decision sends the version the one before it left (+1 each time: kept, no reads)")
	eq(bridge.count("GetCollection"), 0, "no extra reads while every answer was the one sent + 1")
	for method in ["RefundPacks", "AbandonRun", "StartRun"]:
		var body := _body(bridge, method)
		eq([int(body["session"]), body.has("expectedAccountVersion")], [7, false], "%s carries the session only" % method)


func test_an_answer_that_is_not_the_one_sent_plus_one_is_read_again_before_the_next_decision() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [_bought(8), _bought(10)]   # sent 5: 8 is not 6 (something else changed too)
	bridge.answers["GetCollection"] = [[true, _collection(9)]]
	var link := _link(bridge)
	await link.buy_pack("descent-pack", 1, ServerLink.new_request_key())
	eq(link.card_account().account_version, -1, "a version the client cannot account for is not kept")
	await link.buy_pack("descent-pack", 1, ServerLink.new_request_key())
	eq(bridge.count("GetCollection"), 1, "the account was read again before the next decision")
	eq(int(_body(bridge, "BuyPack")["expectedAccountVersion"]), 9, "which then sent the version it read")


func test_a_refund_is_followed_by_a_read_never_by_its_own_version() -> void:
	var bridge := _bridge()
	bridge.answers["RefundPacks"] = [[true, {"refunded": [{"packId": "old", "count": 2, "gemsRefunded": 20}]}]]
	bridge.answers["GetCollection"] = [[true, _collection(5)], [true, _collection(8)]]
	bridge.answers["BuyPack"] = [_bought(9)]
	var link := _link(bridge)
	await link.get_collection()
	await link.refund_packs()
	eq(link.card_account().account_version, -1, "a refund carries no version and moved the account: the version is not known")
	await link.buy_pack("descent-pack", 1, ServerLink.new_request_key())
	eq(bridge.count("GetCollection"), 2, "the next decision read the account first")
	eq(int(_body(bridge, "BuyPack")["expectedAccountVersion"]), 8, "and sent the version it read")


func test_every_retry_of_one_action_sends_the_first_try_s_session_and_version() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [[false, {"status": 503, "errorCode": null, "title": "down", "detail": ""}], _bought(6)]
	bridge.answers["StartAccountSession"] = [_session(1), _session(2, 40)]
	var link := _link(bridge)
	await link.get_collection()
	var account := link.card_account()
	var answer := {}
	var start := func() -> void: answer.merge(await account.run(CardAccount.BUY, "descent-pack", 1))
	start.call()
	check(await _until(func() -> bool: return bridge.count("BuyPack") >= 1), "the first try went out")
	await link.take_account()   # another call starts a newer session and moves the version meanwhile
	check(await _until(func() -> bool: return not answer.is_empty()), "answered")
	var tries := bridge.of("BuyPack").map(func(call: Array) -> Array:
		var body: Dictionary = JSON.parse_string(call[2])
		return [int(body["session"]), int(body["expectedAccountVersion"])])
	eq(tries, [[1, 5], [1, 5]], "the retry carried the first try's session and version, not the newer ones")


# --- the refusals (2.3) --------------------------------------------------------------------------------------------------------

func test_a_stale_version_takes_the_current_one_and_is_not_retried() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [_refused(1413, {"currentAccountVersion": 9})]
	var link := _link(bridge)
	var account := link.card_account()
	var refused: Dictionary = await account.run(CardAccount.BUY, "descent-pack", 1)
	eq([refused["ok"], CardAccount.code_of(refused)], [false, 1413], "a refusal")
	eq(bridge.count("BuyPack"), 1, "not retried: the screen reads the account and the player decides again")
	eq(account.account_version, 9, "the current account version taken from the refusal")


func test_a_replaced_session_blocks_account_calls_until_the_account_is_taken_back() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [_refused(1412, {"currentSession": 2}), _bought(6)]
	bridge.answers["StartAccountSession"] = [_session(1), _session(3, 5)]
	var link := _link(bridge)
	var first: Dictionary = await link.buy_pack("descent-pack", 1, ServerLink.new_request_key())
	eq(CardAccount.code_of(first), 1412, "another login holds the account")
	check(link.session_replaced, "the link knows")
	var blocked: Dictionary = await link.open_pack("descent-pack", ServerLink.new_request_key())
	check(not blocked["ok"] and blocked["error"].get("local", false) and CardAccount.code_of(blocked) == 1412,
		"a later account call is refused here")
	eq(bridge.count("OpenPack"), 0, "and never sent")
	var stale_start: Dictionary = await link.start_run("4.7.2.stable.mono+0123456789abcdef", "fixture.run.two_floors", PARTY)
	check(not stale_start["ok"] and bridge.count("StartRun") == 0, "nor a run start (it would abandon the other device's run)")
	var taken: Dictionary = await link.take_account()
	check(taken["ok"] and not link.session_replaced and link.account_session == 3, "Use it here: a new session")
	var bought: Dictionary = await link.buy_pack("descent-pack", 1, ServerLink.new_request_key())
	check(bought["ok"], "account calls go out again")
	eq(int(_body(bridge, "BuyPack")["session"]), 3, "with the new session")


func test_giving_up_starts_a_new_session_before_the_account_is_free() -> void:
	var bridge := _bridge()
	var link := _link(bridge)
	await link.get_collection()
	eq(bridge.count("StartAccountSession"), 1, "the login")
	bridge.offline = true
	var account := link.card_account()
	var start := func() -> void: await account.run(CardAccount.BUY, "descent-pack", 1)
	start.call()
	check(await _until(func() -> bool: return account.reconnecting_seconds() >= 0.0), "reconnecting")
	account.give_up()
	bridge.answers["StartAccountSession"] = [_session(2)]
	bridge.offline = false
	check(await _until(func() -> bool: return not account.busy()), "free once the last try is back")
	eq(bridge.count("StartAccountSession"), 2, "a new session fenced the request given up")
	eq(link.account_session, 2, "and the link holds it")


# --- runs are never touched by a session (2.1) --------------------------------------------------------------------------------

func test_a_run_played_offline_still_syncs_after_a_new_session() -> void:
	var bridge := _bridge()
	bridge.offline = true
	var link := _link(bridge)
	var run := RunController.new()
	host.add_child(run)
	_nodes.append(run)
	link.link(run, RUN_ID)
	eq(run.start_server_run(fixtures(), PARTY, RUN_ID, 5150, TWO_FLOORS), "", "a server run")
	await RunPlayer.play(run)
	check(link.queued().size() > 0, "played offline: its actions wait in the queue")
	bridge.offline = false
	bridge.answers["StartAccountSession"] = [_session(4)]
	await link.take_account()   # a new login meanwhile (this device or another)
	check(await _until(func() -> bool: return link.queued().is_empty()), "back online: the whole queue uploads")
	var uploads: Array = bridge.of("SendActions")
	check(not uploads.is_empty() and uploads.all(func(call: Array) -> bool:
		return not JSON.parse_string(call[2]).has("session")), "run uploads carry the run's epoch, never the account session")


# --- the Shop's gate and buttons ------------------------------------------------------------------------------------------------

func _game(bridge: FakeBridge) -> GameMain:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	_games.append(game)
	game.content_root = FIXTURES
	game.load_content()
	game.local_saves = false
	game.use_server(_link(bridge))
	return game


func _open_shop(game: GameMain) -> UIScreen:
	for i in 2:
		await host.get_tree().process_frame
	var shop := game.ui.push(MENU, load(SHOP_SCENE))
	if shop != null and shop.loading:
		await shop.loaded
	return shop


func test_the_shop_after_a_replaced_session_offers_use_it_here() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [_refused(1412, {"currentSession": 2})]
	bridge.answers["StartAccountSession"] = [_session(1), _session(3)]
	var game := _game(bridge)
	var shop := await _open_shop(game)
	eq(shop.shown()["offers"].size(), 1, "the offers show")
	await shop.buy("descent-pack", 1)
	if shop.loading:
		await shop.loaded
	eq([shop.shown()["message"], shop.shown()["offers"].size()], ["Your account was opened somewhere else.", 0],
		"the account is not shown while another login holds it")
	var button: Button = shop.get_node("%Online")
	eq([button.visible, button.text], [true, "Use it here"], "the way back")
	button.pressed.emit()
	check(await _until(func() -> bool: return shop.shown()["offers"].size() == 1 and not shop.loading), "taken back: the Shop reads it again")
	eq(game.server.account_session, 3, "from the new session")
	check(not button.visible, "the button goes")


func test_the_shop_with_no_session_offers_go_online() -> void:
	var bridge := _bridge()
	bridge.offline = true
	var game := _game(bridge)
	var shop := await _open_shop(game)
	var button: Button = shop.get_node("%Online")
	eq([shop.shown()["offers"].size(), shop.shown()["gems"]], [0, -1], "no ownership without a session")
	eq([button.visible, button.text], [true, "Go online"], "Go online is offered")
	bridge.offline = false
	button.pressed.emit()
	check(await _until(func() -> bool: return shop.shown()["offers"].size() == 1 and not shop.loading), "online: the Shop shows the account")
	eq(game.server.account_session, 1, "after a login")


func test_the_shop_says_a_stale_view_was_read_again() -> void:
	var bridge := _bridge()
	bridge.answers["BuyPack"] = [_refused(1413, {"currentAccountVersion": 9})]
	var game := _game(bridge)
	var shop := await _open_shop(game)
	var reads := bridge.count("GetCollection")
	await shop.buy("descent-pack", 1)
	if shop.loading:
		await shop.loaded
	eq(shop.shown()["message"], "Your account changed. Here is what you have now.", "the line")
	check(bridge.count("GetCollection") > reads, "and the Shop read the account again")


# --- the console ---------------------------------------------------------------------------------------------------------------

func test_server_session_and_steal() -> void:
	var bridge := _bridge()
	bridge.answers["StartAccountSession"] = [_session(1), _session(2, 6), _session(3)]
	bridge.answers["BuyPack"] = [_refused(1412, {"currentSession": 3})]
	var game := _game(bridge)
	for i in 2:
		await host.get_tree().process_frame
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	console.attach(game)
	await game.server.get_collection()
	var started: Dictionary = await console.execute("server session")
	check(started["ok"] and started["text"] == "session 2 (account version 6)", "a new login: %s" % started["text"])
	var stolen: Dictionary = await console.execute("server session steal")
	check(stolen["ok"] and stolen["text"].contains("another device holds session 3; this game still holds 2"), stolen["text"])
	var refused: Dictionary = await game.server.buy_pack("descent-pack", 1, ServerLink.new_request_key())
	eq(CardAccount.code_of(refused), 1412, "so this game's next account call is refused")
	check(not (await console.execute("server session nope"))["ok"], "a bad argument is refused")
