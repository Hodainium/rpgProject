## Title menu (Menu layer while UI.State.Menu): content root, run picker, party select (class cards, up to
## `max_party`), seed, Start. Remembers the last party and run. A class card's Details opens class_details on top;
## Back returns here with every pick as it was.
extends UIScreen

@export var max_party: int = 4
## Picked on first launch, before a party was saved.
@export var first_party: PackedStringArray = ["demo.character.warrior", "demo.character.cleric"]
@export var party_format: String = "Party (%d/%d):"


func bind(context: UIContext) -> void:
	for path in GameMain.CONTENT_ROOTS:
		%ContentRoot.add_item("Content: " + path)
	%ContentRoot.item_selected.connect(func(index): ctx.main.set_content_root(GameMain.CONTENT_ROOTS[index]))
	%Random.pressed.connect(func(): %Seed.text = RunSeeds.random_code())
	%Start.pressed.connect(_start)
	%Classes.entry_filled.connect(func(entry, _item):
		if not entry.picked_changed.is_connected(_update_party):
			entry.picked_changed.connect(_update_party))
	context.main.content_changed.connect(_fill)
	_fill(context.main.content)


func _fill(content: ContentIndex) -> void:
	%ContentRoot.select(maxi(GameMain.CONTENT_ROOTS.find(ctx.main.content_root), 0))
	%RunPicker.clear()
	if content == null:
		%Classes.set_items([])
		return
	var runs := ctx.main.runs()
	var saved_run: String = GameMain.load_setting("menu", "run", "")
	if not runs.any(func(entry): return String(entry["id"]) == saved_run):
		saved_run = ""  # saved from another content root: the default run
	for entry in runs:
		%RunPicker.add_item(entry["name"])
		%RunPicker.set_item_metadata(%RunPicker.item_count - 1, String(entry["id"]))
		if String(entry["id"]) == saved_run or (saved_run == "" and entry["default"]):
			%RunPicker.select(%RunPicker.item_count - 1)
	var ids: Array = content.characters.keys()
	ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))  # StringName < isn't alphabetical
	var characters: Array = ids.map(func(id): return content.characters[id]).filter(
		func(character: CharacterDefinition) -> bool: return character.selectable)
	var party: Array = GameMain.load_setting("menu", "party", Array(first_party))
	if not party.any(func(id): return content.characters.has(StringName(id))):
		party = ids.slice(0, 2).map(func(id): return String(id))  # a root without these characters (fixtures)
	for card in %Classes.set_items(characters):
		card.set_picked(party.has(card.character_id))
	_update_party()


func _cards() -> Array:
	return %Classes.get_children().filter(func(card) -> bool: return not card.is_queued_for_deletion())


## "Party (2/4):"; once `max_party` are picked, the others can't be.
func _update_party() -> void:
	var picked := _cards().filter(func(card) -> bool: return card.is_picked()).size()
	%PartyLabel.text = party_format % [picked, max_party]
	for card in _cards():
		card.set_pickable(card.is_picked() or picked < max_party)


func _start() -> void:
	var ids: Array = _cards().filter(func(card) -> bool: return card.is_picked()).map(
		func(card) -> String: return card.character_id)
	if %Seed.text.strip_edges() == "":
		%Seed.text = RunSeeds.random_code()
	var run_id: String = %RunPicker.get_item_metadata(%RunPicker.selected) if %RunPicker.selected >= 0 else ""
	GameMain.save_setting("menu", "party", ids)
	GameMain.save_setting("menu", "run", run_id)
	%Error.text = ctx.main.start_run(ids, %Seed.text.strip_edges(), StringName(run_id))
