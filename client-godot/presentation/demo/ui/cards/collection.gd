## Spec card-ui 2.1 (Hearthstone's collection viewer, the approved prototype's layout as changed in the playtest of 2026-11-18): one
## book window over the whole screen with Back, the title, set and kind tabs and the dust and gems in its top row, 10 cards a page
## (5 x 2) on a 3D stage, the rarity gems, the pool, Owned / Missing (owned only at first) and search filters, paging, and the
## owned count beside the card count. Clicking a card opens the card detail (Dust / Create). Built on the menu frame with its
## description window and Back hidden.
## Server mode reads the catalog (once per session) and the collection (every activation and after every action); ownership
## shows only from an account session (spec account-session 2.3: none while another login holds the account, or while no session
## could start: then "Go online"). Local mode is a read-only browser: the core set and the local test pool are owned.
extends DemoMenuFrame

@export var title_text: String = "Collection"
@export var gems_text: String = "%d gems"
@export var dust_text: String = "%d dust"
@export var count_text: String = "%d cards"
@export var page_text: String = "%d / %d"
## After the card count: owned and total cards.
@export var owned_text: String = "  ·  %d / %d owned"
@export var empty_text: String = "No card matches these filters."
@export var loading_text: String = "Opening your collection…"
@export var local_text: String = "Local mode: the core set and the local test pool. Packs, dust and crafting need a server."
@export var unreachable_text: String = "Can't reach the server: %s"
@export var replaced_text: String = "Your account is open somewhere else."
@export var run_active_text: String = "Cards you owned when your run started are locked until it ends (In your run)."
@export var run_verifying_text: String = "Your won run is being verified. Its cards unlock after the verdict."
@export var go_online_text: String = "Go online"
@export var all_sets_text: String = "All sets"
@export var all_cards_title: String = "All cards"
## Set id → its name on the tabs and the page title.
@export var set_names: Dictionary = {"core": "Core set", "descent": "The Descent"}
@export var kind_names: Dictionary = {"all": "All", "character": "Characters", "item": "Items", "equipment": "Armor"}
@export var any_pool_text: String = "Any pool"
## The hover preview: the status line under the text.
@export var status_texts: Dictionary = {"owned": "Owned", "missing": "Not owned · Create for %d dust", "missing_no_rate": "Not owned",
	"core": "Core: every account owns it",
	"unknown": "", "locked": "Owned · in your active run", "retired": "Owned · retired"}
## Missing cards show from the start (playtest 2026-11-18: off; the Collection opens on what the player owns, Missing adds the rest).
@export var missing_at_first: bool = false
@export var detail_scene: PackedScene = preload("res://presentation/demo/ui/cards/card_detail.tscn")

const WAIT_KEY: StringName = &"cards.collection"

## After each refresh has shown its answer (the console and the tests wait on it).
signal loaded

var loading: bool = false
var filters: Dictionary = CollectionModel.default_filters()
var page_index: int = 0
## Every entry (before the filters) and the filtered list.
var all_entries: Array[Dictionary] = []
var shown_entries: Array[Dictionary] = []
## The server's CollectionResponse, or null (local mode, unknown).
var collection: Variant = null
## True when the account's actions (dust, craft) can go out: server mode, a session, a collection read.
var actions_enabled: bool = false
var seen: CardSeen
var style: CardStyle

var _generation: int = 0
var _faces: Array = []
var _faces_key: String = ""
var _rates: Dictionary = {}
var _note: String = ""
var _refresh_when_free: bool = false
var _dust_counter: UICountUp


func bind(_context: UIContext) -> void:
	style = CardStyle.current()
	filters["missing"] = missing_at_first
	%Title.text = title_text
	%Online.text = go_online_text
	%Online.pressed.connect(_go_online)
	%Page.card_pressed.connect(open_detail)
	%Page.card_hovered.connect(_preview)
	%Page.card_seen.connect(_mark_seen)
	%Prev.pressed.connect(turn.bind(-1))
	%Next.pressed.connect(turn.bind(1))
	%Search.text_changed.connect(func(text: String) -> void: set_filter("text", text))
	%Pool.item_selected.connect(_on_pool)
	%Owned.toggled.connect(func(on: bool) -> void: set_filter("owned", on))
	%Missing.toggled.connect(func(on: bool) -> void: set_filter("missing", on))
	_build_rarity_gems()


func on_activated() -> void:
	var link: ServerLink = ctx.main.server if ctx != null else null
	if link != null:
		if not link.session_changed.is_connected(_on_session_changed):
			link.session_changed.connect(_on_session_changed)
		if not link.card_account().busy_changed.is_connected(_on_busy_changed):
			link.card_account().busy_changed.connect(_on_busy_changed)
	refresh()


func on_deactivated() -> void:
	_end_wait()


func _on_session_changed() -> void:
	if active and not loading:
		refresh()


## After giving up, the try still out may land on the server: once it is back, show the server's state again.
func _on_busy_changed() -> void:
	if _refresh_when_free and active and ctx != null and ctx.main.server != null and not ctx.main.server.card_account().busy():
		_refresh_when_free = false
		refresh()


## Reads everything again and redraws (keeps the filters and the page). Await it to know the answer is on screen.
func refresh() -> void:
	if ctx == null:
		return
	_generation += 1
	var generation := _generation
	var link: ServerLink = ctx.main.server
	_show_online(false)
	actions_enabled = false
	# The local mode's NEW set lives with the local saves (none when they are off: tests, a --local window run).
	seen = CardSeen.open(link.saves_dir if link != null else ("user://saves" if ctx.main.local_saves else ""),
		link.player if link != null else "local")
	if link == null:
		_use_faces([], "local")
		_rates = {}
		collection = null
		var pool: Variant = ctx.main.local_card_pool
		_show(CollectionModel.entries(_faces, null, seen.ids, {}, pool if pool is Array else []), local_text)
		_finish()
		return
	if link.session_replaced:
		# Spec account-session 2.3: another login holds the account; nothing of it shows until "Use it here" (the pop-up's).
		collection = null
		_show_unknown(replaced_text)
		_finish()
		return
	loading = true
	%Spinner.visible = true   # playtest 2026-11-18: a spinning circle while the cards load, never a blank page
	%Empty.visible = false
	_begin_wait(link)
	if link.account_session == 0:
		var started: Dictionary = await link.start_account_session()
		if not _current(generation):
			return
		if not started["ok"]:
			_fail(started["error"])
			return
	if link.card_catalog.is_empty():
		var catalog: Dictionary = await link.get_card_catalog()
		if not _current(generation):
			return
		if not catalog["ok"]:
			_fail(catalog["error"])
			return
		link.card_catalog = catalog["data"]
	var read: Dictionary = await link.get_collection()
	if not _current(generation):
		return
	if not read["ok"]:
		_fail(read["error"])
		return
	if _names_unknown_card(link.card_catalog, read["data"]):
		# Spec 2.1: a response naming a card the cached catalog lacks: the catalog moved on, read it again (once).
		var again: Dictionary = await link.get_card_catalog()
		if not _current(generation):
			return
		if again["ok"]:
			link.card_catalog = again["data"]
	_end_wait()
	var catalog_data: Dictionary = link.card_catalog
	_use_faces(catalog_data.get("cards", []), str(catalog_data.get("catalogHash", "")))
	_rates = CollectionModel.rates_of(catalog_data)
	collection = read["data"]
	actions_enabled = true
	_show(CollectionModel.entries(_faces, collection, seen.ids, _rates), _note)
	_finish()


## The faces of the catalog `key` from its `rows` ([] = the local content's own catalog), built only when the key changes (review
## fix: icons and portraits are looked up once per catalog, and the page keeps its views for faces it already shows).
func _use_faces(rows: Array, key: String) -> void:
	if key != _faces_key or _faces.is_empty():
		_faces = CardFaces.build(ctx.main.content, style, rows)
		_faces_key = key


## A set's name on the tabs, the page title and the detail.
func card_set_name(set_id: String) -> String:
	return str(set_names.get(set_id, set_id.capitalize()))


func _fail(error: Dictionary) -> void:
	_end_wait()
	collection = null
	if link_catalog_faces():
		_show_unknown(unreachable_text % ServerLink.describe(error))
	else:
		_show([], unreachable_text % ServerLink.describe(error))
	_show_online(not ServerLink.answered(error))
	_finish()


## Faces with unknown ownership (no session): the cached catalog's, else the local content's.
func link_catalog_faces() -> bool:
	var link: ServerLink = ctx.main.server
	if link != null and not link.card_catalog.is_empty():
		_use_faces(link.card_catalog.get("cards", []), str(link.card_catalog.get("catalogHash", "")))
	elif _faces.is_empty():
		_use_faces([], "local")
	return not _faces.is_empty()


func _show_unknown(line: String) -> void:
	link_catalog_faces()
	_show(CollectionModel.entries(_faces, null, {}, {}), line)


static func _names_unknown_card(catalog: Dictionary, read: Variant) -> bool:
	if not read is Dictionary:
		return false
	var known := {}
	for card in catalog.get("cards", []):
		known[str(card.get("id", ""))] = true
	for card in read.get("owned", []):
		if not known.has(str(card.get("cardId", ""))):
			return true
	return false


func _show(entries: Array[Dictionary], line: String) -> void:
	all_entries = entries
	_build_tabs()
	_build_pools()
	_redraw()
	var run_line := ""
	if collection is Dictionary:
		match str(collection.get("activeRunStatus", "")):
			"Active":
				run_line = run_active_text
			"Verifying":
				run_line = run_verifying_text
	%RunLine.text = run_line
	%RunLine.visible = run_line != ""
	_say(line)
	_show_count()
	var gems := int(collection.get("gems", 0)) if collection is Dictionary else -1
	var dust := int(collection.get("dust", 0)) if collection is Dictionary else -1
	%Gems.visible = gems >= 0
	%Gems.text = gems_text % maxi(gems, 0)
	_set_dust(dust, dust >= 0)   # counts only from a total already shown


## Applies the filters and shows the current page.
func _redraw() -> void:
	shown_entries = CollectionModel.filtered(all_entries, filters)
	var pages := CollectionModel.page_count(shown_entries, per_page())
	page_index = clampi(page_index, 0, pages - 1)
	var on_page := CollectionModel.page(shown_entries, page_index, per_page())
	%Page.show_entries(on_page, style, style.face_scene())
	%Empty.visible = on_page.is_empty()
	%Empty.text = empty_text
	%PageNo.text = page_text % [page_index + 1, pages]
	%Prev.disabled = page_index == 0
	%Next.disabled = page_index >= pages - 1
	_show_count()
	var set_id := str(filters["set"])
	%PageTitle.text = all_cards_title if set_id == "all" else card_set_name(set_id)
	if not on_page.is_empty():
		_preview(on_page[0]["id"])


## Playtest 2026-11-18: the Collection hides the menu frame's description window and its Back (Back sits in the book's tab row),
## so the book takes the whole screen; the frame's push-the-content-below-the-description rule must not move it.
func _keep_content_below() -> void:
	pass


## Cards a page: the page's grid (5 x 2 since the playtest of 2026-11-18).
func per_page() -> int:
	return maxi(1, %Page.columns * %Page.rows)


## The page head's count: the cards the filters show, and how many of all cards the player owns (the side window's total went
## here when the side window was removed, playtest 2026-11-18).
func _show_count() -> void:
	var text := count_text % shown_entries.size()
	if collection != null or (ctx != null and ctx.main.server == null):
		var counts := CollectionModel.counts(all_entries)
		text += owned_text % [counts["owned"], counts["total"]]
	%Count.text = text


## Changes one filter (set, kind, pool, owned, missing, text; rarities through toggle_rarity) and goes back to page 1.
func set_filter(field: String, value: Variant) -> void:
	filters[field] = value
	page_index = 0
	_sync_filter_controls()
	_redraw()


func toggle_rarity(rarity: String) -> void:
	var list: Array = filters["rarities"]
	if list.has(rarity):
		list.erase(rarity)
	else:
		list.append(rarity)
	page_index = 0
	_sync_filter_controls()
	_redraw()


## Turns the page by `step` (clamped).
func turn(step: int) -> void:
	go_to_page(page_index + step)


func go_to_page(index: int) -> void:
	page_index = clampi(index, 0, CollectionModel.page_count(shown_entries, per_page()) - 1)
	_redraw()
	var first: Control = %Page.first_slot()
	if first != null and get_viewport() != null and get_viewport().gui_get_focus_owner() == null:
		first.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if not active or ctx == null or ctx.ui.top(&"UI.Layer.Modal") != null:
		return
	if event.is_action_pressed(&"ui_page_down") or (event is InputEventKey and event.pressed and event.keycode == KEY_PAGEDOWN):
		turn(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_page_up") or (event is InputEventKey and event.pressed and event.keycode == KEY_PAGEUP):
		turn(-1)
		get_viewport().set_input_as_handled()


func entry_for(id: String) -> Dictionary:
	for entry in all_entries:
		if entry["id"] == id:
			return entry
	return {}


## Spec 2.2: the card detail on the Modal layer.
func open_detail(id: String) -> UIScreen:
	var entry := entry_for(id)
	if entry.is_empty() or ctx == null:
		return null
	_mark_seen(id)
	return ctx.ui.push(&"UI.Layer.Modal", detail_scene, {"id": id, "collection": self})


func _mark_seen(id: String) -> void:
	var entry := entry_for(id)
	if entry.is_empty() or not entry.get("new", false) or seen == null:
		return
	seen.mark(id)
	entry["new"] = false
	%Page.clear_new(id)


func _preview(id: String) -> void:
	var entry := entry_for(id)
	if entry.is_empty():
		return
	var face: CardFace = entry["face"]
	describe({"name": face.name, "kind": face.type_line, "text": face.text, "extra": status_of(entry)})


## The card's status line (the preview and the detail).
func status_of(entry: Dictionary) -> String:
	if entry.get("retired", false):
		return str(status_texts.get("retired", ""))
	if entry.get("locked", false):
		return str(status_texts.get("locked", ""))
	if entry["state"] == CollectionModel.STATE_MISSING and int(entry.get("craft", 0)) <= 0:
		return str(status_texts.get("missing_no_rate", ""))   # local mode: no rates
	var text := str(status_texts.get(entry["state"], ""))
	return text % int(entry.get("craft", 0)) if text.contains("%d") else text


# --- Filter controls -----------------------------------------------------------------------------------------------------

func _build_tabs() -> void:
	var facets := CollectionModel.facets(_faces)
	var sets: Array = ["all"] + facets["sets"]
	var wanted := ",".join(sets.map(func(s) -> String: return str(s)))
	if %SetTabs.get_meta(&"sets", "") != wanted:
		%SetTabs.set_meta(&"sets", wanted)
		for child in %SetTabs.get_children():
			child.queue_free()
		for set_id in sets:
			var button := _tab(all_sets_text if set_id == "all" else card_set_name(str(set_id)))
			button.name = "Set_" + str(set_id)
			button.pressed.connect(set_filter.bind("set", str(set_id)))
			%SetTabs.add_child(button)
	if %KindTabs.get_child_count() == 0:
		for kind in ["all", CardFace.KIND_CHARACTER, CardFace.KIND_ITEM, CardFace.KIND_EQUIPMENT]:
			var button := _tab(str(kind_names.get(kind, kind)))
			button.name = "Kind_" + kind
			button.pressed.connect(set_filter.bind("kind", kind))
			%KindTabs.add_child(button)
	_sync_filter_controls()


func _tab(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = true
	button.theme_type_variation = &"Toggle"
	button.focus_mode = Control.FOCUS_ALL
	return button


func _build_pools() -> void:
	var pools: Array = CollectionModel.facets(_faces)["pools"]
	var wanted := ",".join(pools)
	if %Pool.item_count > 0 and %Pool.get_meta(&"pools", "") == wanted:
		return
	%Pool.set_meta(&"pools", wanted)
	%Pool.clear()
	%Pool.add_item(any_pool_text)
	for pool in pools:
		%Pool.add_item(str(pool))
	_sync_filter_controls()


func _on_pool(index: int) -> void:
	set_filter("pool", "" if index <= 0 else %Pool.get_item_text(index))


func _build_rarity_gems() -> void:
	for rarity in CardStyle.RARITY_ORDER:
		var gem := Button.new()
		gem.name = "Rarity_" + rarity
		gem.toggle_mode = true
		gem.flat = true
		gem.custom_minimum_size = Vector2(30, 30)
		gem.tooltip_text = rarity.capitalize()
		gem.focus_mode = Control.FOCUS_ALL
		gem.pressed.connect(toggle_rarity.bind(rarity))
		gem.draw.connect(_draw_gem.bind(gem, rarity))
		%Rarities.add_child(gem)


func _draw_gem(gem: Button, rarity: String) -> void:
	var colour := style.rarity(rarity).color
	var on: bool = filters["rarities"].has(rarity)
	var c := gem.size * 0.5
	var r := minf(gem.size.x, gem.size.y) * 0.4
	var points := PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)])
	gem.draw_colored_polygon(points, colour if on else Color(colour, 0.3))
	var outline := points.duplicate()
	outline.append(points[0])
	gem.draw_polyline(outline, Color.BLACK if not gem.has_focus() else Color.WHITE, 2.0)


func _sync_filter_controls() -> void:
	for child in %SetTabs.get_children():
		child.set_pressed_no_signal(String(child.name) == "Set_" + str(filters["set"]))
	for child in %KindTabs.get_children():
		child.set_pressed_no_signal(String(child.name) == "Kind_" + str(filters["kind"]))
	for child in %Rarities.get_children():
		child.set_pressed_no_signal(filters["rarities"].has(String(child.name).trim_prefix("Rarity_")))
		child.queue_redraw()
	%Owned.set_pressed_no_signal(bool(filters["owned"]))
	%Missing.set_pressed_no_signal(bool(filters["missing"]))
	var known := collection != null or (ctx != null and ctx.main.server == null)
	%Owned.disabled = not known
	%Missing.disabled = not known
	var pool := str(filters["pool"])
	for index in %Pool.item_count:
		if (index == 0 and pool == "") or (index > 0 and %Pool.get_item_text(index) == pool):
			%Pool.select(index)
	if %Search.text != str(filters["text"]):
		%Search.text = str(filters["text"])


# --- Totals, lines, waits ------------------------------------------------------------------------------------------------

## The dust total; `animate` counts it to the new value (after a dust or craft).
func _set_dust(dust: int, animate: bool) -> void:
	if _dust_counter == null:
		_dust_counter = UICountUp.new(%Dust, dust_text)
	_dust_counter.set_value(dust, animate)


func _say(text: String) -> void:
	%Message.text = text
	%Message.visible = text != ""


## A line the next refreshes keep (after giving up, a stale account), cleared by the next action.
func note(text: String, refresh_when_free: bool = false) -> void:
	_note = text
	_refresh_when_free = _refresh_when_free or refresh_when_free


func _show_online(on: bool) -> void:
	%Online.visible = on


func _go_online() -> void:
	if ctx == null or loading:
		return
	_show_online(false)
	await ctx.main.go_online()
	if is_instance_valid(self) and active:
		refresh()


func _begin_wait(link: ServerLink) -> void:
	_say(loading_text)
	link.begin_wait(WAIT_KEY, loading_text)


func _end_wait() -> void:
	if ctx != null and ctx.main.server != null:
		ctx.main.server.end_wait(WAIT_KEY)


func _finish() -> void:
	_end_wait()   # review fix: a refresh that superseded one still waiting ends that wait too (one key per screen)
	loading = false
	%Spinner.visible = false
	loaded.emit()


func _current(generation: int) -> bool:
	return generation == _generation and is_instance_valid(self) and is_inside_tree()


## What the screen shows, for the console and the tests: {page, pages, count, cards: [{id, state, locked, new}], dust, gems,
## message, actions}.
func shown() -> Dictionary:
	var cards: Array = []
	for entry in %Page.entries():
		cards.append({"id": entry["id"], "state": entry["state"], "locked": entry["locked"], "new": entry["new"],
			"rarity": entry["face"].rarity})
	return {"page": page_index + 1, "pages": CollectionModel.page_count(shown_entries, per_page()), "count": shown_entries.size(),
		"cards": cards, "dust": int(collection.get("dust", -1)) if collection is Dictionary else -1,
		"gems": int(collection.get("gems", -1)) if collection is Dictionary else -1,
		"message": %Message.text if %Message.visible else "", "actions": actions_enabled}
