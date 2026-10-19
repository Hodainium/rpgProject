## Demo run-end screen (placeholder): won, lost or stopped by a runner error, with the seed and the run hash.
extends Control

var _main: GameMain

@onready var _text: Label = %Text


func setup(main: GameMain) -> void:
	_main = main
	%Back.pressed.connect(func(): _main.back_to_menu())
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
