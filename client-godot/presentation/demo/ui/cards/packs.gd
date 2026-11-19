## Spec card-ui 2.3 / 2.4 (Hearthstone's pack opening): the packs the account holds, unopened, in a column (count badge, pity
## countdowns, odds), and the stage where one opens: the pack flies into the socket and pulses while the server answers, bursts,
## and five cards fan out face down to be flipped (PackStage plays the choreography). Every open goes through the player's
## CardAccount (one key until the server answers; "Reconnecting…" in the connecting pop-up meanwhile, Go offline beneath it).
## Refunds of retired pack types are paid when the screen opens (spec pack-shop 2.5). Back during a reveal flips the rest first;
## the cards are the account's whatever the screen does. Local mode has no account: the screen says it needs a server, and
## `cardui pack demo` plays the choreography on made-up cards (presentation only).
extends DemoMenuFrame

@export var title_text: String = "Open packs"
@export var gems_text: String = "%d gems"
@export var dust_text: String = "%d dust"
@export var loading_text: String = "Opening your packs…"
@export var offline_text: String = "Opening packs needs a server connection. Packs, gems and cards live on the server."
@export var unreachable_text: String = "Can't reach the server: %s"
@export var no_packs_text: String = "You have no packs. Buy them in the Shop."
@export var hint_text: String = "Click a pack to open it."
@export var flip_hint_text: String = "Click a card to flip it (Space flips the next)."
@export var opening_text: String = "Opening the pack…"
@export var reconnecting_text: String = "Reconnecting to the server…"
@export var no_pack_left_text: String = "You have no pack of this kind left."
@export var unavailable_text: String = "This pack cannot be opened right now."
@export var gave_up_text: String = "We couldn't confirm the opening. Your packs and cards show what the server has."
@export var stale_text: String = "Your account changed. Here is what you have now."
@export var refunded_text: String = "Your %d %s were retired: +%d gems."
@export var refunded_one_text: String = "Your %d %s was retired: +%d gems."
@export var odds_title_text: String = "%s: odds per card (before the guarantee and pity)"
@export var odds_ok_text: String = "OK"
@export var go_online_text: String = "Go online"
@export var tween_seconds: float = 0.6
## The reveal's texts (PackReveal).
@export var reveal_rarity_text: String = "%s"
@export var reveal_big_rarity_text: String = "%s!"
@export var reveal_new_text: String = "NEW"
@export var reveal_duplicate_text: String = "+%d dust"
@export var reveal_pity_text: String = "Guaranteed"
@export var shop_scene: PackedScene = preload("res://presentation/demo/ui/cards/shop.tscn")

const WAIT_KEY: StringName = &"cards.packs"
const DEMO_PACK: String = "demo"

## After each refresh has shown its answer (the console and the tests wait on it).
signal loaded
## A pack's cards are on the stage, face down (the console and the tests).
signal opened(reveal: PackReveal)
## Every card of the pack is face up.
signal revealed

var loading: bool = false
var entries: Array[Dictionary] = []
## The server's CollectionResponse, or null.
var collection: Variant = null
## The reveal on the stage (null when none).
var reveal: PackReveal
## True from a press until the pack's cards are on the stage (or the open was refused).
var opening: bool = false
var style: CardStyle

var _generation: int = 0
var _packs: Variant = null
var _gems: int = -1
var _dust: int = -1
var _shown: Dictionary = {"gems": -1.0, "dust": -1.0}
var _tweens: Dictionary = {}
var _note: String = ""
var _refresh_when_free: bool = false
var _leaving: bool = false
var _refunds_asked: bool = false   # refunds are paid when the page opens (spec pack-shop 2.5), not on a return from the Shop
## Refund lines not shown yet (a read after the refund failed): the next refresh that gets through shows them.
var _pending_notices: PackedStringArray = []


func bind(_context: UIContext) -> void:
	style = CardStyle.current()
	%Stage.style = style
	%Title.text = title_text
	%Online.text = go_online_text
	%Online.pressed.connect(_go_online)
	%PackList.entry_filled.connect(_wire_entry)
	%Stage.card_pressed.connect(_on_card_pressed)
	%Stage.all_revealed.connect(_on_all_revealed)
	%RevealAll.pressed.connect(reveal_all)
	%Done.pressed.connect(done)
	%ShopButton.pressed.connect(_open_shop)
	_show_buttons()


func on_activated() -> void:
	var link: ServerLink = ctx.main.server if ctx != null else null
	if link != null:
		if not link.session_changed.is_connected(_on_session_changed):
			link.session_changed.connect(_on_session_changed)
		if not link.card_account().busy_changed.is_connected(_on_busy_changed):
			link.card_account().busy_changed.connect(_on_busy_changed)
	if _refresh_when_free and ctx != null and ctx.main.server != null and not ctx.main.server.card_account().busy():
		_refresh_when_free = false   # review fix: the given-up try came back while another screen covered this one
	if reveal == null and not opening:
		refresh(not _refunds_asked)
		_refunds_asked = true


func on_deactivated() -> void:
	_end_wait()


func _on_session_changed() -> void:
	if active and not loading and not opening:
		refresh()


func _on_busy_changed() -> void:
	if _refresh_when_free and active and ctx != null and ctx.main.server != null and not ctx.main.server.card_account().busy():
		_refresh_when_free = false
		refresh()


## Spec 2.4: Back while the cards are face down flips them first, then leaves (the cards are the player's either way); Back
## waits while an open is on its way (the pop-up's Go offline is the way out of a long reconnect).
func handles_back() -> bool:
	if opening:
		return true
	if reveal != null and not reveal.done():
		if not _leaving:
			_leaving = true
			_reveal_then_leave()
		return true
	return false


func _reveal_then_leave() -> void:
	await reveal_all()
	if is_instance_valid(self) and active and ctx != null:
		_leaving = false
		ctx.ui.back()


## Space / Enter / the pad's A (ui_accept): flips the next card while some are face down; otherwise opens the next pack (Done
## first when a revealed pack is still on the stage). Playtest fix 2026-11-18.
func _unhandled_input(event: InputEvent) -> void:
	if not active or event.is_echo() or not event.is_action_pressed(&"ui_accept"):
		return
	get_viewport().set_input_as_handled()
	if reveal != null and not reveal.done():
		flip_next()
	else:
		open_next()


## Opens one pack of the first type in the column that has one (after Done when the last pack's cards are still out). Returns
## the account's answer ({} when nothing was sent).
func open_next() -> Dictionary:
	if opening or loading or %Stage.busy:
		return {}
	if reveal != null:
		if not reveal.done():
			return {}
		await done()
		if not is_instance_valid(self) or reveal != null:
			return {}
	for index in entries.size():
		if int(entries[index]["count"]) > 0:
			var view: Node = %PackList.get_child(index) if index < %PackList.get_child_count() else null
			return await open_pack(str(entries[index]["packId"]), view.pack_view() if view != null and view.has_method("pack_view") else null)
	return {}


## Reads the packs and the collection again (`with_refunds`: pays the refunds of retired packs first, spec pack-shop 2.5).
func refresh(with_refunds: bool = false) -> void:
	if ctx == null:
		return
	_generation += 1
	var generation := _generation
	var link: ServerLink = ctx.main.server
	_show_online(false)
	if link == null:
		collection = null
		_show_entries([])
		_set_totals(-1, -1, false)
		_say(offline_text)
		_hint("")
		_finish()
		return
	if link.session_replaced:
		collection = null
		_show_entries([])
		_set_totals(-1, -1, false)
		_say("")
		_finish()
		return
	loading = true
	_say(loading_text)
	link.begin_wait(WAIT_KEY, loading_text)
	if link.account_session == 0:
		var started: Dictionary = await link.start_account_session()
		if not _current(generation):
			return
		if not started["ok"]:
			_fail(started["error"])
			return
	var refunded: Array = []
	if with_refunds:
		var refunds: Dictionary = await link.refund_packs()
		if not _current(generation):
			return
		if refunds["ok"] and refunds["data"] is Dictionary:
			refunded = refunds["data"].get("refunded", [])
	var packs: Dictionary = await link.get_packs()
	if not _current(generation):
		return
	if not packs["ok"]:
		_fail(packs["error"])
		return
	_packs = packs["data"]
	var notices := _pending_notices
	for row in refunded:   # named after the pack list is read
		var count := int(row["count"])
		notices.append((refunded_text if count != 1 else refunded_one_text) % [count, _pack_name(str(row["packId"]), count),
			int(row["gemsRefunded"])])
	_pending_notices = notices   # review fix: kept until a refresh gets the whole way through and shows them
	if link.card_catalog.is_empty():
		var catalog: Dictionary = await link.get_card_catalog()
		if not _current(generation):
			return
		if catalog["ok"]:
			link.card_catalog = catalog["data"]
	var read: Dictionary = await link.get_collection()
	if not _current(generation):
		return
	if not read["ok"]:
		_fail(read["error"])
		return
	_end_wait()
	collection = read["data"]
	_show_entries(OpenPacksModel.entries(_packs, collection))
	var gems := int(collection.get("gems", 0))
	if not notices.is_empty() and float(_shown["gems"]) < 0.0:
		var paid := 0
		for row in refunded:
			paid += int(row["gemsRefunded"])
		_shown["gems"] = float(maxi(gems - paid, 0))   # review fix: the refund counts up from what the player had
	_set_totals(gems, int(collection.get("dust", 0)), not notices.is_empty())
	_say("\n".join(notices) if not notices.is_empty() else _note)
	_pending_notices = PackedStringArray()
	if not _refresh_when_free:
		_note = ""   # review fix: the give-up line shows until the last try is back and read, then never again
	_hint(hint_text if not entries.is_empty() and reveal == null else "")
	_finish()


func _fail(error: Dictionary) -> void:
	_end_wait()
	collection = null
	_show_entries([])
	_set_totals(-1, -1, false)
	_say(unreachable_text % ServerLink.describe(error))
	_show_online(not ServerLink.answered(error))
	_finish()


func _finish() -> void:
	loading = false
	_update_locks()
	loaded.emit()


## The column: one entry per pack type held; none → the Shop line and button.
func _show_entries(list: Array[Dictionary]) -> void:
	entries = list
	%PackList.set_items(list)
	var server := ctx != null and ctx.main.server != null and collection != null
	%Empty.visible = server and list.is_empty()
	%Empty.text = no_packs_text
	%ShopButton.visible = server
	_update_locks()


func _wire_entry(entry: Node, _item: Variant) -> void:
	if not entry.open_requested.is_connected(_on_open_requested):
		entry.open_requested.connect(_on_open_requested)
		entry.odds_requested.connect(_show_odds)


func _on_open_requested(pack_id: String, from: Control) -> void:
	await open_pack(pack_id, from)


## The entry of `pack_id` in the column, or {}.
func entry_for(pack_id: String) -> Dictionary:
	for entry in entries:
		if entry["packId"] == pack_id:
			return entry
	return {}


func _show_odds(entry: Dictionary) -> void:
	var lines := OpenPacksModel.odds_lines(entry)
	ctx.ui.notify("%s\n\n%s" % [odds_title_text % str(entry["name"]), "\n".join(lines)], odds_ok_text)


## Spec 2.3: opens one owned pack of `pack_id` through the account (no pop-up: already paid for). The pack waits in the socket
## while the server answers; the answer's cards fan out face down. Returns the account's answer ({} when nothing was sent).
func open_pack(pack_id: String, from: Control = null) -> Dictionary:
	var link: ServerLink = ctx.main.server if ctx != null else null
	if link == null or opening or loading or reveal != null or %Stage.busy:
		return {}
	var account := link.card_account()
	if account.busy() or entry_for(pack_id).is_empty():
		return {}
	var entry := entry_for(pack_id)
	opening = true
	_note = ""
	_say("")
	_hint("")
	_update_locks()
	var look := style.pack(pack_id)
	%Stage.socket_pack(look, look.label if look.label != "" else str(entry["name"]), from.get_global_rect() if from != null else Rect2())
	link.begin_wait(CardAccount.WAIT_KEY, opening_text)
	if not account.reconnecting.is_connected(_on_reconnecting):
		account.reconnecting.connect(_on_reconnecting)
	var answer: Dictionary = await account.run(CardAccount.OPEN, pack_id)
	if is_instance_valid(self) and account.reconnecting.is_connected(_on_reconnecting):
		account.reconnecting.disconnect(_on_reconnecting)   # review fix: another screen's action is not this screen's
	link.end_wait(CardAccount.WAIT_KEY)
	if not is_instance_valid(self):
		return answer
	if answer.get("ok", false) and answer.get("data") is Dictionary:
		var data: Dictionary = answer["data"]
		_set_count(pack_id, int(data.get("packsLeft", entry["count"] - 1)))
		_set_totals(int(data.get("gems", _gems)), _dust, false)
		_reload_column()   # playtest fix: the pity countdowns change now, not after the last card is seen
		await _play(PackReveal.from_response(data), look)
		opening = false
		_show_buttons()
		return answer
	opening = false
	%Stage.cancel_pack()
	var code := CardAccount.code_of(answer)
	if answer.get("given_up", false):
		_note = gave_up_text
		_refresh_when_free = true
	elif code == 1408:
		link.card_catalog = {}   # the pack has nothing left to draw: a catalog change; read it again
		_refunds_asked = false   # review fix: a retired type waits for its refund here; ask for it again
	await refresh(not _refunds_asked)
	_refunds_asked = true
	if not is_instance_valid(self):
		return answer
	var line := _refusal_line(answer)
	if line != "":
		_say(line)
		if not answer.get("given_up", false):
			ctx.main.refuse(line)
	return answer


## Spec 6: `cardui pack demo [rarity ...]`: the choreography on made-up cards of the local content (no account is touched).
func play_demo(rarities: Array) -> PackReveal:
	if opening or reveal != null or %Stage.busy:
		return null
	opening = true
	_say("")
	_update_locks()
	var look := style.pack(DEMO_PACK)
	%Stage.socket_pack(look, look.label if look.label != "" else "Demo")
	if is_inside_tree():
		await get_tree().create_timer(0.3).timeout
	var open := PackReveal.from_response(PackReveal.demo(CardCatalog.cards(ctx.main.content), rarities))
	await _play(open, look)
	opening = false
	_show_buttons()
	return open


func _play(open: PackReveal, look: CardPackLook) -> void:
	open.rarity_text = reveal_rarity_text
	open.big_rarity_text = reveal_big_rarity_text
	open.new_text = reveal_new_text
	open.duplicate_text = reveal_duplicate_text
	open.pity_text = reveal_pity_text
	reveal = open
	_show_buttons()
	await %Stage.burst(open, _faces_of(open), look)
	if not is_instance_valid(self):
		return
	_hint(flip_hint_text)
	_show_buttons()
	opened.emit(open)


## The faces of the reveal's cards: the server's catalog rows (the content's own in local mode); an id neither knows is an
## "Unknown card" face.
func _faces_of(open: PackReveal) -> Array:
	var rows := {}
	var link: ServerLink = ctx.main.server
	var catalog_rows: Array = link.card_catalog.get("cards", []) if link != null else []
	if catalog_rows.is_empty():
		catalog_rows = CardCatalog.cards(ctx.main.content)
	for row in catalog_rows:
		rows[str(row["id"])] = row
	var faces: Array = []
	for slot in open.slots:
		var row: Dictionary = rows.get(slot["id"], {"id": slot["id"], "rarity": slot["rarity"]})
		faces.append(CardFaces.face_of(ctx.main.content, style, row))
	return faces


func _on_card_pressed(index: int) -> void:
	await flip(index)


## Flips card `index` (false when it was face up already or no pack is on the stage).
func flip(index: int) -> bool:
	if reveal == null or %Stage.busy:
		return false
	return await %Stage.flip(index)


func flip_next() -> bool:
	if reveal == null:
		return false
	return await flip(reveal.next_hidden())


## Reveal all (also Back during the reveal): the rest flip a short gap apart. Await it for the last card.
func reveal_all() -> void:
	if reveal == null or reveal.done():
		return
	while %Stage.busy and is_instance_valid(self):
		await get_tree().process_frame   # the fan is still landing
	await %Stage.flip_all()


func _on_all_revealed() -> void:
	if reveal == null:
		return
	if reveal.dust >= 0:
		_set_totals(_gems, reveal.dust, true)
	_hint("")
	_show_buttons()
	if not reveal.done():
		return
	# Playtest fix: the focus stays where it is, so Space / Enter reach the screen and open the next pack (Done is still a click).
	revealed.emit()


## Done: the cards leave and the column and totals are read again.
func done() -> void:
	if reveal == null or not reveal.done():
		return
	var was_demo := reveal.opening_id == "demo"
	await %Stage.clear_cards()
	if not is_instance_valid(self):
		return
	reveal = null
	_show_buttons()
	if was_demo or ctx.main.server == null:
		_hint(hint_text if not entries.is_empty() else "")
		_update_locks()
		return
	await refresh()


func _show_buttons() -> void:
	var on_stage := reveal != null
	%RevealAll.visible = on_stage and not reveal.done() and not opening
	%Done.visible = on_stage and reveal.done()
	_update_locks()


func _update_locks() -> void:
	var locked := opening or loading or reveal != null
	if ctx != null and ctx.main.server != null:
		locked = locked or ctx.main.server.card_account().busy()
	for entry in %PackList.get_children():
		if entry.has_method("set_locked"):
			entry.set_locked(locked)
	%ShopButton.disabled = opening or reveal != null


## Reads the collection again in the background (no wait pop-up, nothing on the stage changes) and redraws the pack column, so
## the counts and pity countdowns of an open show while its cards are still face down. A failed read keeps the column as it is.
func _reload_column() -> void:
	var link: ServerLink = ctx.main.server if ctx != null else null
	if link == null or not _packs is Dictionary:
		return
	var generation := _generation
	var read: Dictionary = await link.get_collection()
	if not is_instance_valid(self) or generation != _generation or not read["ok"] or not read["data"] is Dictionary:
		return
	collection = read["data"]
	_show_entries(OpenPacksModel.entries(_packs, collection))


func _set_count(pack_id: String, count: int) -> void:
	for index in entries.size():
		if entries[index]["packId"] == pack_id:
			entries[index]["count"] = count
	var kept: Array[Dictionary] = []
	for entry in entries:
		if int(entry["count"]) > 0:
			kept.append(entry)
	_show_entries(kept)


func _refusal_line(answer: Dictionary) -> String:
	if answer.get("given_up", false):
		return gave_up_text
	match CardAccount.code_of(answer):
		ServerLink.ACCOUNT_SESSION_REPLACED:
			return ""   # the connecting pop-up's "opened somewhere else" dialog
		ServerLink.ACCOUNT_VERSION_STALE:
			return stale_text
		1411:
			return no_pack_left_text
		1408:
			return unavailable_text
	var error: Dictionary = answer.get("error", {})
	if error.get("local", false) and error.get("busy", false):
		return ""
	var detail := str(error.get("detail", ""))
	return detail if detail != "" else ServerLink.describe(error)


func _pack_name(pack_id: String, count: int) -> String:
	var name := OpenPacksModel.readable_name(pack_id)   # a refunded type is retired: GET /packs no longer lists it
	if _packs is Dictionary:
		for pack in _packs.get("packs", []):
			if str(pack["packId"]) == pack_id:
				name = str(pack.get("name", pack_id))
	return name + ("s" if count != 1 and not name.ends_with("s") else "")


func _on_reconnecting() -> void:
	if ctx != null and ctx.main.server != null:
		ctx.main.server.begin_wait(CardAccount.WAIT_KEY, reconnecting_text)


func _go_online() -> void:
	if ctx == null or loading or opening:
		return
	_show_online(false)
	await ctx.main.go_online()
	if is_instance_valid(self) and active:
		refresh(true)


func _open_shop() -> void:
	if ctx != null and not opening and reveal == null:
		ctx.ui.push(&"UI.Layer.Menu", shop_scene)


func _show_online(on: bool) -> void:
	%Online.visible = on


## The gems and dust totals (-1 hides one); `animate` counts to the new value.
func _set_totals(gems: int, dust: int, animate: bool) -> void:
	_gems = gems
	_dust = dust
	_count_to(%Gems, "gems", gems_text, gems, animate)
	_count_to(%Dust, "dust", dust_text, dust, animate)


func _count_to(label: Label, key: String, template: String, value: int, animate: bool) -> void:
	label.visible = value >= 0
	var tween: Tween = _tweens.get(key)
	if tween != null:
		tween.kill()
	var from: float = _shown[key]
	if not animate or from < 0.0 or not is_inside_tree() or value < 0:
		_show_total(float(value), label, key, template)
		return
	tween = create_tween()
	tween.tween_method(_show_total.bind(label, key, template), from, float(value), tween_seconds)
	_tweens[key] = tween


func _show_total(value: float, label: Label, key: String, template: String) -> void:
	_shown[key] = value
	label.text = template % roundi(value)


func _say(text: String) -> void:
	%Message.text = text
	%Message.visible = text != ""


func _hint(text: String) -> void:
	%Hint.text = text


func _end_wait() -> void:
	if ctx != null and ctx.main.server != null:
		ctx.main.server.end_wait(WAIT_KEY)


func _current(generation: int) -> bool:
	return generation == _generation and is_instance_valid(self) and is_inside_tree()


## What the screen shows (the console and the tests): the column, the totals, the message, and the stage's cards.
func shown() -> Dictionary:
	var cards: Array = []
	if reveal != null:
		for slot in reveal.slots:
			var card := slot.duplicate()
			card["labels"] = Array(%Stage.labels_of(int(slot["index"])))
			cards.append(card)
	return {"packs": entries.map(func(entry: Dictionary) -> Dictionary: return {"packId": entry["packId"], "count": entry["count"],
		"pity": OpenPacksModel.pity_line(entry, "%s in %d", " packs")}), "gems": _gems, "dust": _dust,
		"message": %Message.text if %Message.visible else "", "cards": cards, "done": reveal != null and reveal.done(),
		"opening": opening}
