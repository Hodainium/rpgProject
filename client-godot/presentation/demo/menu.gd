## Demo menu (placeholder): content root, character toggles, seed, start.
extends Control

var _main: GameMain

@onready var _root_picker: OptionButton = %ContentRoot
@onready var _characters: VBoxContainer = %Characters
@onready var _seed: LineEdit = %Seed
@onready var _error: Label = %Error


func setup(main: GameMain) -> void:
	_main = main
	for path in GameMain.CONTENT_ROOTS:
		_root_picker.add_item("Content: " + path)
	_root_picker.item_selected.connect(func(index): _main.set_content_root(GameMain.CONTENT_ROOTS[index]))
	%Random.pressed.connect(func(): _seed.text = str(randi()))
	%Start.pressed.connect(_start)
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
