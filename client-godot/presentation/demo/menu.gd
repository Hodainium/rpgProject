## Demo menu (placeholder): content root, run picker, party select (up to four, each class's role and kit), seed, start.
## Remembers the last party and run (spec playable-demo 3.6).
extends Control

const MAX_PARTY: int = 4
## Checked on first launch, before a party was saved.
const FIRST_PARTY: Array = ["demo.character.warrior", "demo.character.cleric"]

var _main: GameMain

@onready var _root_picker: OptionButton = %ContentRoot
@onready var _run_picker: OptionButton = %RunPicker
@onready var _party_label: Label = %PartyLabel
@onready var _characters: GridContainer = %Characters
@onready var _seed: LineEdit = %Seed
@onready var _error: Label = %Error


func setup(main: GameMain) -> void:
	_main = main
	for path in GameMain.CONTENT_ROOTS:
		_root_picker.add_item("Content: " + path)
	_root_picker.item_selected.connect(func(index): _main.set_content_root(GameMain.CONTENT_ROOTS[index]))
	%Random.pressed.connect(func(): _seed.text = RunSeeds.random_code())
	%Start.pressed.connect(_start)
	main.mode_changed.connect(func(mode): visible = mode == "menu")
	main.content_changed.connect(_fill)
	_fill(main.content)


func _fill(content: ContentIndex) -> void:
	_root_picker.select(maxi(GameMain.CONTENT_ROOTS.find(_main.content_root), 0))
	for child in _characters.get_children():
		child.queue_free()
	_run_picker.clear()
	if content == null:
		return
	var settings := ConfigFile.new()
	settings.load(GameMain.SETTINGS_PATH)
	var runs := _main.runs()
	var saved_run: String = settings.get_value("menu", "run", "")
	if not runs.any(func(entry): return String(entry["id"]) == saved_run):
		saved_run = ""  # saved from another content root: the default run
	for entry in runs:
		_run_picker.add_item(entry["name"])
		_run_picker.set_item_metadata(_run_picker.item_count - 1, String(entry["id"]))
		if String(entry["id"]) == saved_run or (saved_run == "" and entry["default"]):
			_run_picker.select(_run_picker.item_count - 1)
	var ids: Array = content.characters.keys()
	ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))  # StringName < isn't alphabetical
	var party: Array = settings.get_value("menu", "party", FIRST_PARTY)
	if not party.any(func(id): return content.characters.has(StringName(id))):
		party = ids.slice(0, 2).map(func(id): return String(id))  # a root without these characters (fixtures)
	for id in ids:
		var character: CharacterDefinition = content.characters[id]
		if not character.selectable:
			continue
		var entry := VBoxContainer.new()
		entry.custom_minimum_size = Vector2(420, 0)
		entry.tooltip_text = character.description
		var toggle := CheckBox.new()
		var title := character.display_name if character.display_name != "" else String(id)
		toggle.text = "%s  ·  %s" % [title, character.role] if character.role != "" else title
		toggle.tooltip_text = character.description
		toggle.set_meta("id", String(id))
		toggle.button_pressed = party.has(String(id))
		toggle.toggled.connect(func(_on): _update_party())
		entry.add_child(toggle)
		var kit := Label.new()
		kit.text = _kit(character)
		kit.modulate = Color(0.75, 0.75, 0.75)
		kit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		kit.add_theme_font_size_override("font_size", 13)
		kit.tooltip_text = character.description
		kit.mouse_filter = Control.MOUSE_FILTER_PASS
		entry.add_child(kit)
		_characters.add_child(entry)
	_update_party()


## "Skills: Anthem, Discord · Ult: Finale · Passive: Encore", from the ability scenes' root names and tags (the shared
## ult-charge and break passives are left out).
static func _kit(character: CharacterDefinition) -> String:
	var groups := {"Skills": PackedStringArray(), "Ult": PackedStringArray(), "Passive": PackedStringArray()}
	for scene in character.abilities:
		if scene == null:
			continue
		var tag := String(SkillTags.tag_of(scene))
		if tag.begins_with("Ability.Passive.Ultcharge") or tag.begins_with("Ability.Passive.Break"):
			continue
		var group := "Ult" if tag.begins_with("Ability.Ult.") else "Passive" if tag.begins_with("Ability.Passive.") else "Skills"
		groups[group].append(String(scene.get_state().get_node_name(0)).capitalize())
	var parts := PackedStringArray()
	for group in groups:
		if not groups[group].is_empty():
			parts.append("%s: %s" % [group, ", ".join(groups[group])])
	return "  ·  ".join(parts)


func _toggles() -> Array:
	var result: Array = []
	for entry in _characters.get_children():
		if not entry.is_queued_for_deletion():
			result.append(entry.get_child(0))
	return result


## "Party (2/4):"; once four are picked, the others can't be.
func _update_party() -> void:
	var picked := _toggles().filter(func(toggle): return toggle.button_pressed).size()
	_party_label.text = "Party (%d/%d):" % [picked, MAX_PARTY]
	for toggle in _toggles():
		toggle.disabled = not toggle.button_pressed and picked >= MAX_PARTY


func _start() -> void:
	var ids: Array = []
	for toggle in _toggles():
		if toggle.button_pressed:
			ids.append(toggle.get_meta("id"))
	if _seed.text.strip_edges() == "":
		_seed.text = RunSeeds.random_code()
	var run_id: String = _run_picker.get_item_metadata(_run_picker.selected) if _run_picker.selected >= 0 else ""
	var settings := ConfigFile.new()
	settings.load(GameMain.SETTINGS_PATH)
	settings.set_value("menu", "party", ids)
	settings.set_value("menu", "run", run_id)
	settings.save(GameMain.SETTINGS_PATH)
	_error.text = _main.start_run(ids, _seed.text.strip_edges(), StringName(run_id))
