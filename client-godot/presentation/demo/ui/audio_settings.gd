## Audio (spec audio-pass 3.3; opened from Settings on the same layer, Back returns to it): the Master, Effects and Interface
## volumes, each applied at once and saved in user://game_main.cfg [settings]. A change plays a sample on that bus so the player
## hears the level (a drag plays once, when it ends). Presentation only.
extends UIScreen

## Slider node (unique name) per volume.
const ROWS: Dictionary = {"master": "%MasterVolume", "sfx": "%SfxVolume", "ui": "%UiVolume"}
## The bank entry the Effects slider plays (a hit); Master and Interface play the sound board's Confirm.
const SFX_SAMPLE := "res://presentation/audio/sfx/bank/hit.physical.tres"

var _sample: AudioStreamPlayer
var _dragging: bool = false
var _drag_from: float = -1.0


func bind(_context: UIContext) -> void:
	_sample = AudioStreamPlayer.new()
	_sample.bus = &"Sfx"
	_sample.stream = load(SFX_SAMPLE) if ResourceLoader.exists(SFX_SAMPLE) else null
	add_child(_sample)
	for volume_name in ROWS:
		var slider := get_node(ROWS[volume_name]) as HSlider
		slider.min_value = 0
		slider.max_value = 100
		slider.step = 1  # the console and the save take any 0–100
		slider.set_value_no_signal(AudioSettings.saved(volume_name))
		slider.value_changed.connect(_on_changed.bind(volume_name))
		slider.drag_started.connect(func():
			_dragging = true
			_drag_from = slider.value)
		slider.drag_ended.connect(func(_changed):
			_dragging = false
			# A click sets the value before the drag starts (already saved and played): only a real drag saves and plays here.
			if slider.value != _drag_from:
				AudioSettings.set_volume(volume_name, int(slider.value))
				_play_sample(volume_name))


## Godot's Slider drops a drag without drag_ended when the screen hides or leaves: save what the drag reached then.
func _notification(what: int) -> void:
	if (what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree()) or what == NOTIFICATION_EXIT_TREE:
		_end_drag()


func _end_drag() -> void:
	if not _dragging:
		return
	_dragging = false
	for volume_name in ROWS:
		var slider := get_node_or_null(ROWS[volume_name]) as HSlider
		if slider != null and int(slider.value) != AudioSettings.saved(volume_name):
			AudioSettings.set_volume(volume_name, int(slider.value))


func refresh() -> void:
	for volume_name in ROWS:
		(get_node(ROWS[volume_name]) as HSlider).set_value_no_signal(AudioSettings.saved(volume_name))


func _on_changed(value: float, volume_name: String) -> void:
	if _dragging:
		AudioSettings.apply(volume_name, int(value))  # heard at once; saved when the drag ends
		return
	AudioSettings.set_volume(volume_name, int(value))
	_play_sample(volume_name)  # a keyboard, pad or click step plays and saves at once


func _play_sample(volume_name: String) -> void:
	if volume_name == "sfx":
		if _sample != null and _sample.stream != null:
			_sample.play()
	elif is_inside_tree():
		get_tree().call_group("sound_board", "play", "Confirm")
