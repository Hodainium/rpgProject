## Demo menu (placeholder): content root, character toggles, seed, start.
extends Control

var _main: GameMain
var _root_picker: OptionButton
var _characters: VBoxContainer
var _seed: LineEdit
var _error: Label


func setup(main: GameMain) -> void:
	_main = main
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(PRESET_CENTER)
	panel.custom_minimum_size = Vector2(420, 0)
	panel.position = Vector2(-210, -200)
	add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	var title := Label.new()
	title.text = "Run demo"
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)
	_root_picker = OptionButton.new()
	for path in GameMain.CONTENT_ROOTS:
		_root_picker.add_item("Content: " + path)
	_root_picker.item_selected.connect(func(index): _main.set_content_root(GameMain.CONTENT_ROOTS[index]))
	box.add_child(_root_picker)
	box.add_child(_label("Party (1-4):"))
	_characters = VBoxContainer.new()
	box.add_child(_characters)
	var seed_row := HBoxContainer.new()
	seed_row.add_child(_label("Seed:"))
	_seed = LineEdit.new()
	_seed.text = "1"
	_seed.size_flags_horizontal = SIZE_EXPAND_FILL
	seed_row.add_child(_seed)
	var dice := Button.new()
	dice.text = "Random"
	dice.pressed.connect(func(): _seed.text = str(randi()))
	seed_row.add_child(dice)
	box.add_child(seed_row)
	var start := Button.new()
	start.text = "Start run"
	start.pressed.connect(_start)
	box.add_child(start)
	_error = _label("")
	_error.modulate = Color.SALMON
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_error)
	main.mode_changed.connect(func(mode): visible = mode == "menu")
	main.content_changed.connect(_fill)
	_fill(main.content)


func _fill(content: ContentIndex) -> void:
	_root_picker.select(maxi(GameMain.CONTENT_ROOTS.find(_main.content_root), 0))
	for child in _characters.get_children():
		child.queue_free()
	if content == null:
		return
	var ids: Array = content.characters.keys()
	ids.sort()
	var shown := 0
	for id in ids:
		var character: CharacterDefinition = content.characters[id]
		if not character.selectable:
			continue
		var toggle := CheckBox.new()
		toggle.text = character.display_name if character.display_name != "" else String(id)
		toggle.set_meta("id", String(id))
		toggle.button_pressed = shown < 2
		shown += 1
		_characters.add_child(toggle)


func _start() -> void:
	var ids: Array = []
	for toggle in _characters.get_children():
		if toggle is CheckBox and toggle.button_pressed and not toggle.is_queued_for_deletion():
			ids.append(toggle.get_meta("id"))
	_error.text = _main.start_run(ids, _seed.text.strip_edges())


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label
