## Demo event panel (placeholder): the page text and its choices; choices whose conditions fail are disabled.
extends Control

var _main: GameMain

@onready var _title: Label = %Title
@onready var _text: Label = %Text
@onready var _choices: VBoxContainer = %Choices


func setup(main: GameMain) -> void:
	_main = main
	main.run_changed.connect(_bind)
	main.mode_changed.connect(func(_mode): _refresh())
	visible = false


func _bind(run: RunController) -> void:
	for changed in [run.event_page_shown, run.room_entered, run.room_cleared, run.battle_requested, run.party_changed]:
		changed.connect(func(_a = null, _b = null): _refresh.call_deferred())


func _refresh() -> void:
	var run := _main.run
	var event := run.current_event() if run != null and run.state != null else null
	var page := run.current_page() if event != null else null
	visible = page != null and _main.mode == "run" and run.pending_battle.is_empty()
	if not visible:
		return
	for child in _choices.get_children():
		child.queue_free()
	_title.text = event.display_name
	_text.text = page.text
	for index in page.choices.size():
		var button := Button.new()
		button.text = page.choices[index].label
		button.disabled = not run.choice_enabled(index)
		button.pressed.connect(func(): run.choose(index))
		_choices.add_child(button)
