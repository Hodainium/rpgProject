## Spec class-pick: the class pick (Menu layer, pushed by the main menu's New run). Left: the 3D turntable of the classes in a
## gold frame (only the arrows turn it, D13) and the class card under it (name, role, description, moves, level skills, stats
## as numbers). Right: the party as portrait slots (a click removes a member), the recommended parties (a click loads one; a
## class the account lacks leaves its slot empty), the footer and Lock in. In server mode the classes the account does not
## own are greyed and cannot be added (spec card-ui 2.6). No run picker, seed or content root here: the dev console's
## `runsetup` sets them (2.6). Menu logic lives in ClassPickModel; this screen draws it.
extends UIScreen

## The number of party slots.
@export var max_party: int = 4
## The lock over a locked class in front (only the front one, once the ring stops; user, 2026-11-19): its icon, its size as a
## share of the cube's height (0.7: the mock-up's "medium"), and how fast it fades in (it goes at once when the ring turns).
@export var lock_icon: Texture2D
@export var lock_size: float = 0.7
@export var lock_fade_seconds: float = 0.15
## The description's height in lines, whatever the class (the card keeps one size).
@export var description_lines: int = 2
## Picked on first launch, before a party was saved.
@export var first_party: PackedStringArray = ["demo.character.warrior", "demo.character.cleric"]
@export var presets: PartyPresetList
@export var title_text: String = "Choose your party"
@export var party_heading: String = "Party"
@export var count_format: String = "%d / %d"
@export var presets_heading: String = "Recommended parties"
@export var add_text: String = "Add to party"
@export var remove_text: String = "Remove from party"
@export var lock_in_text: String = "Lock in"
@export var locked_chip: String = "Locked"
@export var in_party_chip: String = "In party"
@export var locked_hint: String = "Find %s in a pack or craft it."
@export var full_hint: String = "The party is full. Click a member to take it out."
@export var short_footer: String = "Only %d slots filled."
@export var short_footer_one: String = "Only 1 slot filled."
@export var empty_footer: String = "Pick at least one class."
@export var learns_format: String = "Learns: %s"
@export var learn_entry: String = "Lv %d %s"
@export var move_labels: Dictionary = {"Basic": "Basic", "Skill": "Skill", "FollowUp": "Follow-up", "Passive": "Passive",
	"Ultimate": "Ult"}
@export var collection_failed_text: String = "Couldn't check your collection. Only starter classes can be picked."
@export var session_replaced_text: String = "Your account was opened somewhere else. Only starter classes can be picked here."
@export var locked_start_text: String = "%s is not on your account any more. Pick another class."
## A 1409 whose class this screen cannot name (its collection still lists it, or the read failed).
@export var refused_text: String = "The server refused a class in this party. Check your collection and pick again."
@export var dev_line_text: String = "Dev run setup: %s"
@export var dev_seed_text: String = "seed %s"
## The position dots under the stage: a pickable class, a locked one.
@export var dot_open: String = "●"
@export var dot_locked: String = "○"
## Spec main-menu M2: asked when a run can be continued and a new one is started.
@export var abandon_question: String = "Start a new run? Your current run will be abandoned."
@export var abandon_yes: String = "Start new run"
@export var abandon_no: String = "Cancel"

## Character id (String) → ClassPickModel state.
var states: Dictionary = {}
## True while the account's ownership is being read (server mode).
var loading: bool = false
## The party: `max_party` entries, a character id or &"" (empty).
var party: Array = []
## True once the saved party was restored against real ownership.
var _restored: bool = false
## True while `states` came from the account (a collection), not from local mode or the core-only fallback.
var _from_account: bool = false
var _characters: Array = []
var _portraits: Dictionary = {}
var _generation: int = 0
var _starting: bool = false
var _source: PartyPresetSource


func bind(context: UIContext) -> void:
	%Title.text = title_text
	%PartyHeading.text = party_heading
	%PresetsHeading.text = presets_heading
	%LockIn.text = lock_in_text
	%Prev.pressed.connect(turn.bind(-1))
	%Next.pressed.connect(turn.bind(1))
	%Add.pressed.connect(toggle_selected)
	%LockIn.pressed.connect(lock_in)
	%Carousel.selected_changed.connect(func(_index: int) -> void: _show_class())
	%Slots.entry_filled.connect(func(entry: Node, _item: Variant) -> void:
		if not entry.pressed.is_connected(_on_slot_pressed):
			entry.pressed.connect(_on_slot_pressed.bind(entry)))
	%Presets.entry_filled.connect(func(entry: Node, _item: Variant) -> void:
		if not entry.pressed.is_connected(_on_preset_pressed):
			entry.pressed.connect(_on_preset_pressed.bind(entry)))
	# One-line and two-line descriptions take the same height, so the card never jumps as the ring turns (user, 2026-11-19).
	var text: Label = %Description.get_node("%Text")
	text.custom_minimum_size.y = text.get_line_height() * description_lines + text.get_theme_constant(&"line_spacing") * (description_lines - 1)
	_source = PartyPresetSource.DeveloperPresets.new(presets, presets_heading)
	%Viewport.msaa_3d = GraphicsSettings.msaa_of(GraphicsSettings.saved_aa())  # the player's anti-aliasing (B25)
	%Stage.resized.connect(_fit_stage)
	get_tree().root.size_changed.connect(_fit_stage)   # a fullscreen switch keeps the canvas size, not the pixels
	_fit_stage.call_deferred()
	var portraits: Variant = load(CardArtSet.PORTRAITS_PATH) if ResourceLoader.exists(CardArtSet.PORTRAITS_PATH) else null
	if portraits is CardArtSet:
		_portraits = portraits.textures
	context.main.content_changed.connect(func(_content: ContentIndex) -> void: _fill())
	context.main.server_changed.connect(func(_link: ServerLink) -> void:
		_watch_session()
		load_ownership())
	context.main.run_start_refused.connect(_on_start_refused)
	_fill()


func on_activated() -> void:
	_watch_session()
	_starting = false
	load_ownership()


## Re-reads ownership when the link's account session changes (whichever link is current).
func _watch_session() -> void:
	var link: ServerLink = ctx.main.server if ctx != null else null
	if link != null and not link.session_changed.is_connected(_on_session_changed):
		link.session_changed.connect(_on_session_changed)


func _on_session_changed() -> void:
	if active and not loading:   # a session this screen started itself is answered by its own load
		load_ownership()


## The arrows (D13): Left / Right turn the ring while this screen is on top; holding a key repeats.
func _input(event: InputEvent) -> void:
	if not active or not is_visible_in_tree() or ctx.ui.top(&"UI.Layer.Modal") != null:
		return  # a dialog or the dev run setup above: its own keys
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	if event.is_action_pressed(&"ui_left", true):
		turn(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_right", true):
		turn(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_accept") and get_viewport().gui_get_focus_owner() == null:
		toggle_selected()   # Enter adds or removes the class in front (a focused button handles Enter itself)
		get_viewport().set_input_as_handled()


## "Damage dealer / off-tank: break" → "Damage Dealer / Off-Tank: Break" (the role line reads like a title; user, 2026-11-19):
## every word's first letter, including after a hyphen, in upper case; the rest as written. Small words (`title_small_words`)
## stay lower case unless they open the text or follow a colon.
const TITLE_SMALL_WORDS: Array[String] = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to", "with"]


static func title_case(text: String) -> String:
	var words := text.split(" ")
	for index in words.size():
		var word := words[index]
		var opens := index == 0 or words[index - 1].ends_with(":")
		if word == "" or (not opens and TITLE_SMALL_WORDS.has(word.to_lower())):
			continue
		var parts := word.split("-")
		for part in parts.size():
			parts[part] = parts[part].left(1).to_upper() + parts[part].substr(1)
		words[index] = "-".join(parts)
	return " ".join(words)


## Redraws the footer and the dev run setup line (the console's runsetup calls it).
func refresh() -> void:
	_show_footer()


## Turns the ring `steps` classes.
func turn(steps: int) -> void:
	if _starting:
		return   # Lock in pressed: the party on screen is the one being started
	%Carousel.turn(steps)


## The class in front, or null.
func selected() -> CharacterDefinition:
	return %Carousel.selected()


## Adds the class in front to the first empty slot, or takes it out when it is in the party (Add / Remove, Enter).
func toggle_selected() -> void:
	var character := selected()
	if _starting or character == null or not ClassPickModel.pickable(states.get(String(character.id), ClassPickModel.LOCKED)):
		return
	var slot := party.find(character.id)
	var before := party.duplicate()
	party = ClassPickModel.remove(party, slot, max_party) if slot >= 0 else ClassPickModel.add(party, character.id, max_party)
	_restored = _restored or party != before   # the player's own party now: a late answer from the account never replaces it
	_show_party()
	_show_class()


## Empties `slot` (a click on a member).
func remove_slot(slot: int) -> void:
	if _starting:
		return
	var before := party.duplicate()
	party = ClassPickModel.remove(party, slot, max_party)
	_restored = _restored or party != before
	_show_party()
	_show_class()


## Loads `preset`: a class that is not pickable leaves its slot empty (D8); no message (the empty slot says it; user, 2026-11-19).
func apply_preset(preset: PartyPreset) -> void:
	if preset == null or _starting:
		return
	_restored = true
	var applied := ClassPickModel.apply_preset(Array(preset.members), states, max_party)
	party = applied["party"]
	_show_party()
	_show_class()


## Lock in (2.5): confirms abandoning a continuable run, saves the party, starts the run with the dev setup's run and seed when
## set, else the content's default run (D11) and a random (local) or server-issued seed.
func lock_in() -> void:
	var ids: Array = ClassPickModel.members(party).map(func(id) -> String: return String(id))
	if _starting or ids.is_empty():
		return
	_starting = true
	_show_footer()
	var continuable: Dictionary = await ctx.main.can_continue()
	if not is_instance_valid(self):
		return
	if continuable["enabled"] and not await ctx.ui.confirm(abandon_question, abandon_yes, abandon_no):
		_starting = false
		_show_footer()
		return
	GameMain.save_setting("menu", "party", ids)
	var setup: Dictionary = ctx.main.dev_run_setup
	var seed_text := str(setup.get("seed", "")).strip_edges()
	if seed_text == "" and ctx.main.server == null:
		seed_text = RunSeeds.random_code()
	var error: String = ctx.main.start_run(ids, seed_text, StringName(str(setup.get("run_id", ""))))
	if error != "":
		_message(error)
	if ctx.main.server == null or error != "":
		_starting = false
		_show_footer()


## Reads who may be picked (2.3) and redraws. Local mode: everyone. Server mode: core ∪ owned, through the account session (the
## session's own snapshot when it is new, else one collection read). A read that fails before any answer leaves the core classes
## only; one that fails later keeps what the account last said.
func load_ownership() -> void:
	if ctx == null or ctx.main.content == null:
		return
	_generation += 1
	var generation := _generation
	var ids: Array = _characters.map(func(character: CharacterDefinition) -> String: return String(character.id))
	var core: Array = CardCatalog.core_ids(ctx.main.content)
	var link: ServerLink = ctx.main.server
	if link != null:
		loading = true   # from the first request on: commands and tests wait for the whole answer
		if states.is_empty():
			_use_states(ClassPickModel.ownership(ids, core, null, true), false)  # core only until the account first answers
		# The server decides what counts: its catalog's core cards; an empty catalog enforces nothing (cards off or unseeded),
		# so every class is open, as the run start would accept them. Only a catalog with cards is kept on the link (an empty
		# one is read again next time: the server may have been seeded since).
		var cards: Array = link.card_catalog.get("cards", []) if not link.card_catalog.is_empty() else []
		if cards.is_empty():
			var catalog: Dictionary = await link.get_card_catalog()
			if generation != _generation or not is_instance_valid(self):
				return
			if catalog["ok"] and catalog["data"] is Dictionary:
				cards = catalog["data"].get("cards", [])
				if not cards.is_empty():
					link.card_catalog = catalog["data"]
			if catalog["ok"] and cards.is_empty():
				link = null   # nothing enforced: every class is open
		if not cards.is_empty():
			var server_core: Array = []
			for card in cards:
				if card is Dictionary and bool(card.get("core", false)):
					server_core.append(str(card.get("id", "")))
			core = server_core
	if link == null:
		loading = false
		_from_account = false
		_use_states(ClassPickModel.ownership(ids, core, null, false))
		return
	loading = true
	var collection: Variant = null
	if not link.session_replaced:
		if link.account_session == 0:
			var started: Dictionary = await link.start_account_session()
			if generation != _generation or not is_instance_valid(self):
				return
			if started["ok"] and started["data"] is Dictionary:
				collection = started["data"].get("collection")
		if collection == null and link.account_session != 0:
			var read: Dictionary = await link.get_collection()
			if generation != _generation or not is_instance_valid(self):
				return
			if read["ok"]:
				collection = read["data"]
	loading = false
	if not collection is Dictionary:
		collection = null
		if not core.is_empty():
			_message(session_replaced_text if link.session_replaced else collection_failed_text)
			if _from_account:
				return   # keep what the account last said
	_from_account = collection != null
	_use_states(ClassPickModel.ownership(ids, core, collection, true))


## `final` false: a provisional answer (core only, before the account's first answer): it shows on the card and the dots but
## greys no cube and takes no member out of the party.
func _use_states(found: Dictionary, final: bool = true) -> void:
	states = found
	if final:
		var locked := {}
		for id in states:
			if not ClassPickModel.pickable(states[id]):
				locked[id] = true
		%Carousel.set_locked(locked)
	if final and not _restored:
		_restored = true
		var saved: Array = GameMain.load_setting("menu", "party", Array(first_party))
		if not saved.any(func(id) -> bool: return states.has(String(id))):
			# A root without these classes (the fixtures): its first two, as the old title menu did.
			saved = _characters.slice(0, 2).map(func(character: CharacterDefinition) -> String: return String(character.id))
		party = ClassPickModel.restore(saved, states, max_party)
	elif final:
		# A member that is no longer pickable leaves its slot.
		for slot in party.size():
			if party[slot] != &"" and not ClassPickModel.pickable(states.get(String(party[slot]), ClassPickModel.LOCKED)):
				party[slot] = &""
	_show_party()
	_show_presets()
	_show_class()


## The content's selectable classes on the ring (sorted by name, not StringName pointer).
func _fill() -> void:
	var content: ContentIndex = ctx.main.content if ctx != null else null
	_characters = []
	if content != null:
		var ids: Array = content.characters.keys()
		ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))
		for id in ids:
			var character: CharacterDefinition = content.characters[id]
			if character.selectable:
				_characters.append(character)
	party = ClassPickModel.normalized([], max_party)
	states = {}
	_restored = false
	%Carousel.show_characters(_characters)
	_show_dots()
	if active:
		load_ownership()   # a content change while open; the first open loads in on_activated


func _show_class() -> void:
	var character := selected()
	_show_dots()
	if character == null:
		%Card.visible = false
		return
	%Card.visible = true
	var state: String = states.get(String(character.id), ClassPickModel.LOCKED)
	var in_party := party.has(character.id)
	var chips := PackedStringArray()
	if not ClassPickModel.pickable(state):
		chips.append(locked_chip)
	if in_party:
		chips.append(in_party_chip)
	%Description.show_info({"name": character.display_name, "kind": title_case(character.role), "text": character.description,
		"extra": "  ·  ".join(chips)})
	%Description.get_node("%Extra").visible = true   # the chips' line keeps its place when empty: the card never jumps
	for child in %Moves.get_children():
		child.queue_free()
	for move: Dictionary in ClassPickModel.moves(character):
		var chip := HBoxContainer.new()
		chip.add_theme_constant_override(&"separation", 6)
		var kind := Label.new()
		kind.text = move_labels.get(move["type"], move["type"])
		kind.theme_type_variation = &"Gold" if move["type"] == "Ultimate" else &"Muted"
		var title := Label.new()
		title.text = move["name"]
		chip.add_child(kind)
		chip.add_child(title)
		%Moves.add_child(chip)
	var learned := PackedStringArray()
	for row in ClassPickModel.learns(character):
		learned.append(learn_entry % [row[0], row[1]])
	%Learns.text = learns_format % "  ·  ".join(learned) if not learned.is_empty() else ""
	%Learns.visible = true   # keeps its line when a class learns nothing
	for child in %Stats.get_children():
		child.queue_free()
	for row in ClassPickModel.stats(character):
		var label := Label.new()
		label.text = row[0]
		label.theme_type_variation = &"Muted"
		var number := Label.new()
		number.text = row[1]
		number.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		%Stats.add_child(label)
		%Stats.add_child(number)
	var full := ClassPickModel.members(party).size() >= max_party
	%Add.text = remove_text if in_party else add_text
	%Add.disabled = not ClassPickModel.pickable(state) or (full and not in_party)
	if not ClassPickModel.pickable(state):
		%Hint.text = locked_hint % character.display_name
	elif full and not in_party:
		%Hint.text = full_hint
	else:
		%Hint.text = ""
	%Hint.visible = %Hint.text != ""


func _show_party() -> void:
	var slots: Array = []
	for id in party:
		var character: CharacterDefinition = ctx.main.content.characters.get(id) if id != &"" else null
		slots.append({"id": id if character != null else &"", "name": character.display_name if character != null else "",
			"portrait": _portraits.get(id)})
	%Slots.set_items(slots)
	%Count.text = count_format % [ClassPickModel.members(party).size(), max_party]
	_show_footer()


func _show_presets() -> void:
	var rows: Array = []
	for entry in _source.presets():
		var preset: PartyPreset = entry["preset"]
		var members: Array = []
		for id in preset.members:
			var character: CharacterDefinition = ctx.main.content.characters.get(id)
			members.append({"id": id, "name": character.display_name if character != null else String(id),
				"portrait": _portraits.get(id), "locked": character == null
					or not ClassPickModel.pickable(states.get(String(id), ClassPickModel.LOCKED))})
		rows.append({"preset": preset, "stat": entry["stat"], "members": members})
	%Presets.set_items(rows)
	%PresetsWindow.visible = not rows.is_empty()


func _show_footer() -> void:
	%Footer.text = ClassPickModel.footer(party, max_party, short_footer, short_footer_one, empty_footer)
	%LockIn.disabled = _starting or ClassPickModel.members(party).is_empty()
	var setup: Dictionary = ctx.main.dev_run_setup if ctx != null else {}
	var parts := PackedStringArray()
	if str(setup.get("run_id", "")) != "":
		parts.append(str(setup["run_id"]))
	if str(setup.get("seed", "")) != "" and ctx.main.server == null:
		parts.append(dev_seed_text % str(setup["seed"]))
	%DevLine.text = dev_line_text % " · ".join(parts) if not parts.is_empty() else ""
	%DevLine.visible = not parts.is_empty()


func _show_dots() -> void:
	var count: int = _characters.size()
	while %Dots.get_child_count() < count:
		var dot := Label.new()
		%Dots.add_child(dot)
	while %Dots.get_child_count() > count:
		var extra := %Dots.get_child(%Dots.get_child_count() - 1)
		%Dots.remove_child(extra)
		extra.queue_free()
	for i in count:
		var dot: Label = %Dots.get_child(i)
		var open := ClassPickModel.pickable(states.get(String(_characters[i].id), ClassPickModel.LOCKED))
		dot.text = dot_open if open else dot_locked
		dot.theme_type_variation = &"Gold" if i == %Carousel.index else &"Muted"


func _message(text: String) -> void:
	%Message.text = text
	%Message.visible = text != ""


func _on_slot_pressed(entry: Node) -> void:
	remove_slot(entry.get_index())


func _on_preset_pressed(entry: Node) -> void:
	apply_preset(entry.preset)


## Spec 2.5: the server refused the start. A 1409 (the account changed elsewhere): read ownership again, the lost members leave
## their slots, the line names them.
func _on_start_refused(error: Dictionary) -> void:
	_starting = false
	var code: Variant = error.get("errorCode")
	if code == null or int(code) != 1409 or not is_inside_tree():
		_show_footer()
		return
	var before := ClassPickModel.members(party)
	await load_ownership()
	if not is_instance_valid(self):
		return
	var lost := before.filter(func(id) -> bool: return not party.has(id))
	var names: Array = lost.map(func(id) -> String:
		var character: CharacterDefinition = ctx.main.content.characters.get(id)
		return character.display_name if character != null else String(id))
	_message(locked_start_text % ", ".join(names) if not names.is_empty() else refused_text)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	var character := selected()
	var locked: bool = character != null and lock_icon != null and not %Carousel.turning()
	locked = locked and not ClassPickModel.pickable(states.get(String(character.id), ClassPickModel.LOCKED))
	var lock: TextureRect = %Lock
	lock.texture = lock_icon
	lock.modulate.a = move_toward(lock.modulate.a, 1.0, delta / maxf(lock_fade_seconds, 0.01)) if locked else 0.0
	lock.visible = lock.modulate.a > 0.0
	if lock.visible:
		var cube: Rect2 = %Carousel.front_on_screen()
		var ratio := FxStage.screen_pixel_ratio(%Stage)
		var side := cube.size.y * lock_size / ratio
		lock.size = Vector2(side, side)
		lock.position = cube.get_center() / ratio - lock.size * 0.5


## The stage's viewport at the window's real pixels (sharp at 4K, FxStage.screen_pixel_ratio): refitted when the stage or the
## window changes size.
func _fit_stage() -> void:
	if not is_inside_tree():
		return
	var ratio := FxStage.screen_pixel_ratio(%Stage)
	var pixels := Vector2i(maxi(1, roundi(%Stage.size.x * ratio)), maxi(1, roundi(%Stage.size.y * ratio)))
	%Viewport.size = pixels
	%ViewportBox.size = Vector2(pixels)
	%ViewportBox.scale = Vector2.ONE / ratio
