## Spec card-ui 2.3a (Hearthstone's separate buy menu): the packs on sale, bought with gems, waiting unopened in Open packs.
## Built on the menu frame (Back top left, the description window on top: hover previews an offer). Every buy goes through
## the player's CardAccount, so a double click or a retry buys once; a buy with no answer keeps the connecting pop-up up
## ("Reconnecting…") and is re-sent with the same key until the server answers, and Back waits for it. Local mode has no
## account: the screen says the Shop needs a server.
extends DemoMenuFrame

@export var title_text: String = "Shop"
@export var gems_text: String = "%d gems"
@export var loading_text: String = "Loading the Shop…"
@export var offline_text: String = "The Shop needs a server connection. Packs, gems and cards live on the server."
@export var unreachable_text: String = "Can't reach the server: %s"
@export var empty_text: String = "No packs are on sale right now."
@export var bought_text: String = "Bought %d pack%s. You have %d waiting in Open packs."
## The pop-up after a buy went through (card-ui playtest, user 2026-11-18): the count and "s" for more than one.
@export var purchased_text: String = "Purchased %d pack%s!"
@export var purchased_ok_text: String = "OK"
## The question before a buy (user, 2026-11-18): count, "s" for several, the pack's name, the gems it costs.
@export var confirm_buy_text: String = "Buy %d pack%s of %s for %d gems?"
@export var confirm_buy_yes_text: String = "Buy"
@export var confirm_buy_no_text: String = "Cancel"
## The confirmed pack left the Shop while the pop-up was up.
@export var offer_gone_text: String = "That pack is no longer on sale."
@export var not_enough_text: String = "Not enough gems (need %d, have %d)."
@export var wait_text: String = "Talking to the Shop…"
@export var reconnecting_text: String = "Reconnecting to the server…"
@export var gave_up_text: String = "We couldn't confirm your purchase. Your gems and packs show what the server has."
## The account changed since the Shop read it (1413): it read it again.
@export var stale_text: String = "Your account changed. Here is what you have now."
## No session could start (the server is unreachable): offline mode, with a button to sign in again.
@export var go_online_text: String = "Go online"
@export var gems_tween_seconds: float = 0.6
## The hover preview in the description window.
@export var preview_kind_text: String = "%d cards · %d gems"
@export var preview_pity_text: String = "Pity: %s."
@export var preview_pity_entry: String = "a %s within %d packs"

const WAIT_KEY: StringName = &"cards.shop"

## After each refresh has shown its answer (the console and the tests wait on it).
signal loaded

## True from a refresh's first call until its answer is on screen.
var loading: bool = false

var _generation: int = 0
var _offers: Array[Dictionary] = []
var _gems: int = -1
var _buying: bool = false
## A Buy press is waiting on its confirm pop-up (the buttons lock meanwhile).
var _asking: bool = false
## A refresh asked for while the confirm was up: it runs once the pop-up is answered.
var _refresh_after_ask: bool = false
var _gems_counter: UICountUp
var _note: String = ""  # a line the next refreshes keep (after giving up), cleared by the next buy
var _refresh_when_free: bool = false  # given up: refetch once the last try is back


func bind(_context: UIContext) -> void:
	%Offers.entry_filled.connect(_wire_offer)
	%Title.text = title_text
	%Online.pressed.connect(_go_online)


## Spec account-session 2.1: "Go online" signs in again, then the Shop reads the account from the new session's start. (A 1412's
## "Use it here" is the connecting pop-up's, card-ui playtest 2026-11-18.)
func _go_online() -> void:
	var link: ServerLink = ctx.main.server if ctx != null else null
	if link == null or loading or _buying or link.card_account().busy() or link.session_replaced:
		return
	_show_online("")
	await ctx.main.go_online()   # review fix: the one Go online (the pop-up with Go offline, one at a time, the session kept)
	if is_instance_valid(self) and active:
		refresh()


## The Go online button (`text` "" hides it).
func _show_online(text: String) -> void:
	%Online.text = text
	%Online.visible = text != ""


func on_activated() -> void:
	if ctx != null and ctx.main.server != null:
		var account := ctx.main.server.card_account()
		if not account.busy_changed.is_connected(_on_busy_changed):
			account.busy_changed.connect(_on_busy_changed)
		if not ctx.main.server.session_changed.is_connected(_on_session_changed):
			ctx.main.server.session_changed.connect(_on_session_changed)
	refresh()


## Spec account-session 2.3 (review fix): a 1412 from any call (a run start, the console) shows the gate at once.
func _on_session_changed() -> void:
	if _asking:
		_refresh_after_ask = true   # review fix: never behind the buy's confirm, but right after it
	elif active and not loading and not _buying:
		refresh()


func on_deactivated() -> void:
	_end_wait()
	if ctx != null and ctx.main.server != null:
		ctx.main.server.end_wait(CardAccount.WAIT_KEY)


## After giving up, the try still out may land on the server: once it is back, show the server's state again.
func _on_busy_changed() -> void:
	if _asking and _refresh_when_free:
		_refresh_after_ask = true
		return
	if not _refresh_when_free or not active or _buying or ctx == null or ctx.main.server == null:
		return
	if not ctx.main.server.card_account().busy():
		_refresh_when_free = false
		refresh()


func _on_reconnecting() -> void:
	if ctx != null and ctx.main.server != null:
		ctx.main.server.begin_wait(CardAccount.WAIT_KEY, reconnecting_text)


## Spec card-ui 2.5: Back waits while a buy is on its way (the pop-up's button is the way out of a long reconnect).
func handles_back() -> bool:
	return _buying


func refresh() -> void:
	if ctx == null:
		return
	_generation += 1
	var generation := _generation
	var link: ServerLink = ctx.main.server
	if link == null:
		_show_offers([], -1)
		_say(offline_text)
		describe({"name": title_text, "text": offline_text})
		_finish_loading()
		return
	_show_online("")
	if link.session_replaced:
		# Spec account-session 2.3: another login holds the account. Nothing of it is shown until the player takes it back
		# (the connecting pop-up's "opened somewhere else" dialog; session_changed refreshes the Shop).
		_show_offers([], -1)
		_say("")
		_finish_loading()
		return
	loading = true
	_say(loading_text)
	_begin_wait(link)
	var line := ""
	if link.account_session == 0:
		# The gate (spec account-session 2.1): ownership shows only from a session; none could start at sign-in, so try now.
		var started: Dictionary = await link.start_account_session()
		if not _current(generation):
			return
		if not started["ok"]:
			_end_wait()
			_show_offers([], -1)
			_say(unreachable_text % ServerLink.describe(started["error"]))
			if not ServerLink.answered(started["error"]):
				_show_online(go_online_text)   # a server-side refusal is not cured by signing in again
			_finish_loading()
			return
	var packs: Dictionary = await link.get_packs()
	if not _current(generation):
		return
	if not packs["ok"]:
		_end_wait()
		_show_offers([], -1)
		_say(unreachable_text % ServerLink.describe(packs["error"]))
		if not ServerLink.answered(packs["error"]):
			_show_online(go_online_text)
		_finish_loading()
		return
	var collection: Dictionary = await link.get_collection()
	if not _current(generation):
		return
	_end_wait()
	var offers := ShopModel.offers(packs["data"], collection["data"] if collection["ok"] else null)
	_show_offers(offers, ShopModel.gems(collection["data"] if collection["ok"] else null))
	if offers.is_empty():
		line = empty_text
	elif not collection["ok"]:
		line = unreachable_text % ServerLink.describe(collection["error"])
	_say(line if line != "" else _note)
	if not offers.is_empty():
		_preview(offers[0])
	_finish_loading()


## The offers on screen (one per pack type) and the gems total; the Buy buttons follow both.
func _show_offers(offers: Array[Dictionary], gems: int) -> void:
	_offers = offers
	%Offers.set_items(offers)
	_set_gems(gems, false)
	_update_offers()


func _wire_offer(entry: Node, _item: Variant) -> void:
	if not entry.buy_requested.is_connected(_buy):
		entry.buy_requested.connect(_buy)
		entry.hovered.connect(_preview)


func _preview(offer: Dictionary) -> void:
	if offer.is_empty():
		return
	var odds := PackedStringArray()
	for row in offer["odds"]:
		odds.append("%s %s" % [str(row["rarity"]).capitalize(), ShopModel.percent(int(row["per10000"]))])
	var pity := PackedStringArray()
	for row in offer["pity"]:
		pity.append(preview_pity_entry % [str(row["rarity"]).capitalize(), int(row["packs"])])
	describe({"name": str(offer["name"]), "kind": preview_kind_text % [int(offer["cardCount"]), int(offer["price"])],
		"text": " · ".join(odds), "extra": preview_pity_text % ", ".join(pity) if not pity.is_empty() else ""})


## Spec card-ui 2.3a: one buy through the account (one key until it is answered; the Buy buttons ask first, in _buy, user
## 2026-11-18; this is the buy itself, which the console also calls; the button names the
## price). The connecting pop-up covers the wait after 0.3 s and says "Reconnecting…" while the account re-sends it.
func buy(pack_id: String, count: int) -> Dictionary:
	var link: ServerLink = ctx.main.server if ctx != null else null
	if link == null or _buying or loading:
		return {}
	var account := link.card_account()
	if account.busy():
		return {}
	var offer := offer_for(pack_id)
	_buying = true
	_note = ""
	_update_offers()
	link.begin_wait(CardAccount.WAIT_KEY, wait_text)
	if not account.reconnecting.is_connected(_on_reconnecting):
		account.reconnecting.connect(_on_reconnecting)  # a method: it leaves with the Shop
	var answer: Dictionary = await account.run(CardAccount.BUY, pack_id, count)
	link.end_wait(CardAccount.WAIT_KEY)
	if not is_instance_valid(self):
		return answer
	_buying = false
	if answer.get("ok", false):
		var data: Dictionary = answer["data"]
		_set_gems(int(data["gems"]), true)
		for index in _offers.size():
			if _offers[index]["packId"] == pack_id:
				_offers[index]["owned"] = int(data["owned"])
		%Offers.set_items(_offers)
		_say(_bought_line(answer, bought_text))
		var bought := int(data.get("count", count))
		ctx.ui.notify(purchased_text % [bought, "" if bought == 1 else "s"], purchased_ok_text)  # not awaited: the buy is done
	elif answer.get("given_up", false):
		# The server may or may not have done it: show what it has now, and again once the last try is back.
		_note = gave_up_text
		_refresh_when_free = true
		await refresh()
		if not is_instance_valid(self):
			return answer
	else:
		# A refusal means the screen was stale: fetch again first, then say why with the fresh totals.
		await refresh()
		if not is_instance_valid(self):
			return answer
		if CardAccount.code_of(answer) != ServerLink.ACCOUNT_SESSION_REPLACED:   # that one is the pop-up's
			_refuse(not_enough_text % [int(offer.get("price", 0)) * count, maxi(_gems, 0)]
				if CardAccount.code_of(answer) == CardAccount.NOT_ENOUGH_CURRENCY else _refusal_line(answer))
	_update_offers()
	return answer


## A Buy button: asks "Buy N packs of X for G gems?" (Buy / Cancel) and buys only on Buy (user, 2026-11-18).
func _buy(pack_id: String, count: int) -> void:
	var offer := offer_for(pack_id)
	if _asking or _buying or loading or offer.is_empty() or ctx == null:
		return
	_asking = true
	_update_offers()
	var price := int(offer.get("price", 0)) * count
	var yes: bool = await ctx.ui.confirm(confirm_buy_text % [count, "" if count == 1 else "s", str(offer["name"]), price],
		confirm_buy_yes_text, confirm_buy_no_text)
	if not is_instance_valid(self):
		return
	while yes and loading and is_instance_valid(self) and is_inside_tree():
		await loaded   # review fix: a refresh started meanwhile: buy once it is done, not into a refusal that says nothing
	if not is_instance_valid(self):
		return
	_asking = false
	_update_offers()
	if not is_inside_tree():
		return   # the Shop closed meanwhile: nothing is bought
	if _refresh_after_ask:
		_refresh_after_ask = false
		_refresh_when_free = false
		await refresh()   # what changed meanwhile (a replaced session, a given-up try's result) shows first
		if not is_instance_valid(self):
			return
	if not yes:
		return
	var now := offer_for(pack_id)
	if now.is_empty():
		_refuse(offer_gone_text)
		return
	if int(now.get("price", 0)) * count != price:
		_buy(pack_id, count)   # the price changed while the pop-up was up: ask again with what is on sale now
		return
	await buy(pack_id, count)


func _update_offers() -> void:
	var locked := _buying or loading or _asking  # a buy never overlaps a refresh (its totals would land over the buy's)
	if ctx != null and ctx.main.server != null:
		locked = locked or ctx.main.server.card_account().busy()
	for entry in %Offers.get_children():
		if entry.has_method("set_state"):
			entry.set_state(_gems, locked)


## The offer on screen for `pack_id`, or {} when it is not on sale.
func offer_for(pack_id: String) -> Dictionary:
	for offer in _offers:
		if offer["packId"] == pack_id:
			return offer
	return {}


func _bought_line(answer: Dictionary, template: String) -> String:
	var data: Dictionary = answer.get("data", {})
	var count := int(data.get("count", answer.get("count", 1)))
	return template % [count, "" if count == 1 else "s", int(data.get("owned", 0))]


func _refusal_line(answer: Dictionary) -> String:
	var error: Dictionary = answer.get("error", {})
	match CardAccount.code_of(answer):
		ServerLink.ACCOUNT_VERSION_STALE:
			return stale_text
	var detail := str(error.get("detail", ""))
	return detail if detail != "" else ServerLink.describe(error)


## The gems total; `animate` counts it to the new value.
func _set_gems(gems: int, animate: bool) -> void:
	_gems = gems
	if _gems_counter == null:
		_gems_counter = UICountUp.new(%Gems, gems_text, gems_tween_seconds)
	_gems_counter.set_value(gems, animate)


func _say(text: String) -> void:
	%Message.text = text
	%Message.visible = text != ""


func _refuse(text: String) -> void:
	_say(text)
	ctx.main.refuse(text)


func _begin_wait(link: ServerLink, text: String = "") -> void:
	link.begin_wait(WAIT_KEY, text if text != "" else loading_text)


func _end_wait() -> void:
	if ctx != null and ctx.main.server != null:
		ctx.main.server.end_wait(WAIT_KEY)


func _finish_loading() -> void:
	loading = false
	_update_offers()
	loaded.emit()


## The offers on screen (pack id, price, owned, ...), the gems total (-1 unknown) and the message line: for the console and tests.
func shown() -> Dictionary:
	return {"offers": _offers.duplicate(true), "gems": _gems, "message": %Message.text if %Message.visible else ""}


func _current(generation: int) -> bool:
	return generation == _generation and is_instance_valid(self) and is_inside_tree()
