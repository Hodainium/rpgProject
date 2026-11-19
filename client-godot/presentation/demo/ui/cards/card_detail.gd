## Spec card-ui 2.2 (Hearthstone's crafting view): the card large on its own stage, its facts, and the crafting bar: Dust (+value)
## for an owned card, Create (-cost) for a missing one, a line instead for a core card. Every action goes through the player's
## CardAccount (one key until the server answers; "Reconnecting…" in the connecting pop-up meanwhile). A card the active run holds
## opens the run-lock pop-up first: Cancel run abandons it and dusts with the same key; a run being verified says to wait. After
## every answer the Collection reads the account again (spec account-session 2.3: a 1413 says the account changed; a 1412 is the
## connecting pop-up's "Use it here"). On the Modal layer, over the Collection; Back or a click beside the card closes it.
extends UIScreen

## The flash on a dusted card (a crafted card flashes its rarity's colour).
@export var dust_flash_color: Color = Color(0.75, 0.85, 1.0)
@export var dust_button_text: String = "Dust  +%d"
@export var create_button_text: String = "Create  -%d"
@export var dust_total_text: String = "%d dust"
@export var core_text: String = "Core: every account owns it. It is always in the pools and cannot be dusted or crafted."
@export var retired_text: String = "Retired: it can no longer be created."
@export var offline_text: String = "Dust and Create need a server connection."
@export var party_pick_text: String = "Party pick"
@export var none_text: String = "—"
@export var dust_confirm_text: String = "Dust %s for %d dust?"
@export var dust_yes_text: String = "Dust"
@export var create_confirm_text: String = "Create %s for %d dust?"
@export var create_yes_text: String = "Create"
@export var cancel_text: String = "Cancel"
@export var run_lock_text: String = "%s is in your active run. You owned it when the run started, so it can be dusted only after the run ends.\n\nCancel that run to dust it now?"
@export var cancel_run_text: String = "Cancel run"
@export var keep_run_text: String = "Keep run"
@export var verifying_text: String = "Your won run is being verified. You can dust this card after the verdict."
@export var dusted_text: String = "Dusted: +%d dust."
@export var created_text: String = "Created: %s is yours."
@export var not_enough_text: String = "Not enough dust (need %d, have %d)."
@export var stale_text: String = "Your account changed. Here is what you have now."
@export var gave_up_text: String = "We couldn't confirm that. Your cards and dust show what the server has."
@export var working_text: String = "Talking to the server…"
@export var reconnecting_text: String = "Reconnecting to the server…"
## Rarities that ask before Create (Hearthstone asks for the expensive ones).
@export var confirm_create_rarities: Array[String] = ["legendary", "mythic"]

## After each action has shown its answer (the console and the tests wait on it).
signal acted(answer: Dictionary)

var id: String = ""
var entry: Dictionary = {}
var collection: Node
var busy: bool = false
## The last action's answer ({} before any): the console's `cardui wait acted`.
var last_answer: Dictionary = {}
var _style: CardStyle


func on_pushed(payload: Dictionary) -> void:
	id = str(payload.get("id", ""))
	collection = payload.get("collection")
	_style = CardStyle.current()
	%Dim.gui_input.connect(_on_dim_input)
	%DustButton.pressed.connect(_dust_pressed)
	%CreateButton.pressed.connect(_create_pressed)
	if collection != null and is_instance_valid(collection):
		collection.get_node("%Page").set_paused(true)   # review fix: the page under the detail stops rendering
	tree_exiting.connect(_resume_page)
	_load_entry()
	_show_card(true)


func _resume_page() -> void:
	if collection != null and is_instance_valid(collection) and collection.is_inside_tree():
		collection.get_node("%Page").set_paused(false)


func handles_back() -> bool:
	return busy


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and not busy:
		ctx.ui.back()


func _load_entry() -> void:
	if collection != null and is_instance_valid(collection):
		entry = collection.entry_for(id)


## Redraws the card (only when `card` is true: the face is rendered again) and the facts and buttons.
func _show_card(card: bool) -> void:
	if entry.is_empty():
		return
	var face: CardFace = entry["face"]
	if card:
		var one: Array[Dictionary] = [entry]
		%Card.show_entries(one, _style, _style.face_scene())
	else:
		var view: CardView3D = %Card.views.get(id)
		if view != null:
			view.set_ghost(entry["state"] == CollectionModel.STATE_MISSING)
	%Name.text = face.name
	if _style.name_font != null:
		%Name.add_theme_font_override(&"font", _style.name_font)
	%TypeLine.text = face.type_line
	%Rarity.text = face.rarity.capitalize()
	%Rarity.add_theme_color_override(&"font_color", _style.rarity(face.rarity).color)
	%Set.text = collection.card_set_name(face.set_id) if collection != null and is_instance_valid(collection) else face.set_id.capitalize()
	%Pools.text = ", ".join(face.pools) if not face.pools.is_empty() else (party_pick_text if face.kind == CardFace.KIND_CHARACTER else none_text)
	%Status.text = collection.status_of(entry) if collection != null and is_instance_valid(collection) else ""
	%Text.text = face.text
	%Text.visible = face.text != ""
	var dust_value := int(entry.get("dust", 0))
	var cost := int(entry.get("craft", 0))
	%DustButton.text = dust_button_text % dust_value
	%CreateButton.text = create_button_text % cost
	var dust_total := _dust_total()
	%DustTotal.text = dust_total_text % maxi(dust_total, 0)
	%DustTotal.visible = dust_total >= 0
	var core: bool = entry["state"] == CollectionModel.STATE_CORE
	var enabled := _actions_enabled()
	%CraftBar.visible = not core and enabled
	%Note.visible = core or not enabled or entry.get("retired", false)
	%Note.text = core_text if core else (offline_text if not enabled else retired_text)
	var account_busy := busy or (ctx != null and ctx.main.server != null and ctx.main.server.card_account().busy())
	%DustButton.disabled = account_busy or entry["state"] != CollectionModel.STATE_OWNED
	%CreateButton.disabled = account_busy or entry["state"] != CollectionModel.STATE_MISSING or entry.get("retired", false) \
		or cost <= 0 or dust_total < cost


func _actions_enabled() -> bool:
	return ctx != null and ctx.main.server != null and collection != null and is_instance_valid(collection) \
		and collection.actions_enabled


func _dust_total() -> int:
	if collection == null or not is_instance_valid(collection) or not collection.collection is Dictionary:
		return -1
	return int(collection.collection.get("dust", 0))


func _run_status() -> String:
	if collection == null or not is_instance_valid(collection) or not collection.collection is Dictionary:
		return ""
	var status: Variant = collection.collection.get("activeRunStatus")
	return str(status) if status != null else ""


func _dust_pressed() -> void:
	await dust()


func _create_pressed() -> void:
	await create()


## Spec 2.2: Dust. A card the active run holds opens the run-lock pop-up first (Cancel run → abandon → the same dust with the
## same key); a run being verified says to wait. Returns the account's answer ({} when nothing was sent).
func dust() -> Dictionary:
	if busy or entry.is_empty() or entry["state"] != CollectionModel.STATE_OWNED or not _actions_enabled():
		return {}
	var face: CardFace = entry["face"]
	var cancel_run := false
	if entry.get("locked", false):
		if _run_status() == "Verifying":
			_say(verifying_text)
			return {}
		cancel_run = await ctx.ui.confirm(run_lock_text % face.name, cancel_run_text, keep_run_text)
		if not cancel_run:
			return {}
	elif not await ctx.ui.confirm(dust_confirm_text % [face.name, int(entry["dust"])], dust_yes_text, cancel_text):
		return {}
	var answer := await _act(CardAccount.DUST, cancel_run)
	return answer


## Spec 2.2: Create. Legendary and Mythic ask first; the button is disabled when the dust is short.
func create() -> Dictionary:
	if busy or entry.is_empty() or entry["state"] != CollectionModel.STATE_MISSING or not _actions_enabled():
		return {}
	var face: CardFace = entry["face"]
	if confirm_create_rarities.has(face.rarity):
		if not await ctx.ui.confirm(create_confirm_text % [face.name, int(entry["craft"])], create_yes_text, cancel_text):
			return {}
	return await _act(CardAccount.CRAFT, false)


func _act(kind: String, cancel_run: bool) -> Dictionary:
	var link: ServerLink = ctx.main.server
	var account := link.card_account()
	if account.busy():
		return {}
	busy = true
	_say("")
	collection.note("")
	_show_card(false)
	var face: CardFace = entry["face"]
	var dust_before := _dust_total()
	link.begin_wait(CardAccount.WAIT_KEY, working_text)
	if not account.reconnecting.is_connected(_on_reconnecting):
		account.reconnecting.connect(_on_reconnecting)
	var answer: Dictionary = await account.run(kind, id)
	if kind == CardAccount.DUST and CardAccount.code_of(answer) == CardAccount.CARD_LOCKED_BY_RUN:
		var status := str(answer.get("error", {}).get("runStatus", ""))
		if status == "Verifying":
			pass   # said below
		else:
			var go := cancel_run
			if not go:
				link.end_wait(CardAccount.WAIT_KEY)   # review fix: the connecting pop-up would cover the question and block it
				go = await _ask_cancel_run(face)
				if not is_instance_valid(self):
					return answer
				link.begin_wait(CardAccount.WAIT_KEY, working_text)
			if go:
				answer = await account.cancel_run_and_retry(answer)
	link.end_wait(CardAccount.WAIT_KEY)
	if not is_instance_valid(self):
		return answer
	var line := _line(kind, answer, face, dust_before)
	var code := CardAccount.code_of(answer)
	if not answer.get("ok", false) and not answer.get("given_up", false) and not code in [0, CardAccount.CARD_LOCKED_BY_RUN,
			CardAccount.RUN_VERIFYING, ServerLink.ACCOUNT_SESSION_REPLACED, ServerLink.ACCOUNT_VERSION_STALE]:
		link.card_catalog = {}   # review fix: a refusal may mean new rates or a retired card; the refetch reads the catalog too
	if answer.get("given_up", false):
		collection.note(gave_up_text, true)
	elif CardAccount.code_of(answer) == ServerLink.ACCOUNT_VERSION_STALE:
		collection.note(stale_text)
	await collection.refresh()
	if not is_instance_valid(self):
		return answer
	busy = false
	_load_entry()
	_show_card(false)
	_say(line)
	if answer.get("ok", false):
		var view: CardView3D = %Card.views.get(id)
		if view != null:
			view.flash(_style.rarity(face.rarity).color if kind == CardAccount.CRAFT else dust_flash_color)
	elif not line.is_empty() and CardAccount.code_of(answer) != ServerLink.ACCOUNT_SESSION_REPLACED:
		ctx.main.refuse(line)
	last_answer = answer
	acted.emit(answer)
	return answer


## The run lock the screen did not know about (the collection was stale): the same pop-up, after the server said so.
func _ask_cancel_run(face: CardFace) -> bool:
	return await ctx.ui.confirm(run_lock_text % face.name, cancel_run_text, keep_run_text)


## The line under the bar for `answer`.
func _line(kind: String, answer: Dictionary, face: CardFace, dust_before: int) -> String:
	if answer.get("ok", false):
		var data: Dictionary = answer.get("data", {}) if answer.get("data") is Dictionary else {}
		if kind == CardAccount.DUST:
			return dusted_text % int(data.get("dustGained", entry.get("dust", 0)))
		return created_text % face.name
	if answer.get("given_up", false):
		return gave_up_text
	var code := CardAccount.code_of(answer)
	match code:
		CardAccount.NOT_ENOUGH_CURRENCY:
			return not_enough_text % [int(entry.get("craft", 0)), maxi(dust_before, 0)]
		CardAccount.CARD_LOCKED_BY_RUN, CardAccount.RUN_VERIFYING:
			var status := str(answer.get("error", {}).get("runStatus", "Verifying"))
			return verifying_text if status == "Verifying" or code == CardAccount.RUN_VERIFYING else ""
		ServerLink.ACCOUNT_SESSION_REPLACED:
			return ""   # the connecting pop-up's "opened somewhere else" dialog
		ServerLink.ACCOUNT_VERSION_STALE:
			return stale_text
	var error: Dictionary = answer.get("error", {})
	var detail := str(error.get("detail", ""))
	return detail if detail != "" else ServerLink.describe(error)


func _on_reconnecting() -> void:
	if ctx != null and ctx.main.server != null:
		ctx.main.server.begin_wait(CardAccount.WAIT_KEY, reconnecting_text)


func _say(text: String) -> void:
	%Message.text = text
	%Message.visible = text != ""


## What the detail shows (the console and the tests).
func shown() -> Dictionary:
	return {"id": id, "state": entry.get("state", ""), "locked": entry.get("locked", false), "core_note": %Note.visible,
		"dust_enabled": %CraftBar.visible and not %DustButton.disabled,
		"create_enabled": %CraftBar.visible and not %CreateButton.disabled, "message": %Message.text if %Message.visible else ""}
