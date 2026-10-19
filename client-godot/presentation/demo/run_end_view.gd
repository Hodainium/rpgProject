## Demo run-end screen (placeholder): won, lost or stopped by a runner error, with the seed and the run hash.
extends Control

var _main: GameMain
var _text: Label


func setup(main: GameMain) -> void:
	_main = main
	set_anchors_and_offsets_preset(PRESET_CENTER)
	position = Vector2(-220, -90)
	var panel := PanelContainer.new()
	add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(440, 0)
	panel.add_child(box)
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_text)
	var back := Button.new()
	back.text = "Back to menu"
	back.pressed.connect(func(): _main.back_to_menu())
	box.add_child(back)
	main.mode_changed.connect(_on_mode)
	visible = false


func _on_mode(mode: String) -> void:
	visible = mode == "end"
	if not visible:
		return
	var run := _main.run
	if run == null or run.state == null:
		_text.text = "The run could not start.\n" + (run.runner_error if run != null else "")
		return
	var headline := "Stopped: " + run.runner_error if run.runner_error != "" else "Run %s" % run.state.status.to_lower()
	_text.text = "%s\n\nSeed: %d\nFloor reached: %d\nRun hash: %s" % [headline, run.state.run_seed,
		run.state.floor_index + 1, run.state.run_hash()]
