## Headless safeguard (spec dev-tools, "Headless safeguards and parallel runs"): a headless run never idles silently.
## Active only when the display server is headless; the editor and the game are untouched.
##
## - The main scene's root script failed to load (a parse error leaves the node scriptless, and Godot would idle until
##   --quit-after): print why and quit with 70.
## - No Watchdog.beat(label) for --idle-limit seconds (default 180): print the last label (and any recent script or
##   engine errors) and quit with 124.
## - A script or engine error (ScriptErrorLog) and then no beat for 30 s: the error most likely killed the run's main
##   coroutine (it aborts the function and its callers carry on with null). Print the errors and quit with 71.
## - While beats arrive, print an "alive" line every 30 s, so a watcher outside sees progress as output.
## A frozen main thread stops this node too; tools/watch.sh catches that from outside.
##
## Silent runs (any display server): with the environment variable RPG_MUTE=1 (tools/watch.sh sets it, so every run
## Claude starts) or the user arg --mute, the Master bus is muted. Sounds still play, mix and report errors; only
## the speakers stay quiet. RPG_MUTE=0 tools/watch.sh ... runs with sound.
extends Node

const DEFAULT_IDLE_LIMIT: int = 180
const ALIVE_EVERY_MS: int = 30000
const EXIT_SCRIPT_FAILED: int = 70
const EXIT_STALLED: int = 124
const EXIT_ERROR_STALLED: int = 71
## How long a run may make no progress after a script or engine error before it is stopped.
const ERROR_GRACE_MS: int = 30000
## Errors kept for the stop message.
const ERRORS_SHOWN: int = 10

var active: bool = false
var idle_limit_ms: int = DEFAULT_IDLE_LIMIT * 1000
var beats: int = 0
var last_label: String = "start"

var _last_beat_ms: int = 0
var _last_alive_ms: int = 0
var _beats_at_alive: int = 0
var _errors := ScriptErrorLog.new()
var _recent_errors: Array[String] = []
## An error came after the last beat.
var _error_since_beat: bool = false


func _ready() -> void:
	if OS.get_environment("RPG_MUTE") == "1" or OS.get_cmdline_user_args().has("--mute"):
		AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
		print("Watchdog: audio muted (RPG_MUTE=1 or --mute); sounds still play into a muted Master bus")
	active = DisplayServer.get_name() == "headless"
	set_process(active)
	if not active:
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := OS.get_cmdline_user_args()
	var at := args.find("--idle-limit")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		idle_limit_ms = int(args[at + 1]) * 1000
	_last_beat_ms = Time.get_ticks_msec()
	_last_alive_ms = _last_beat_ms
	OS.add_logger(_errors)
	_check_main_scene.call_deferred()


## Progress: call it at each unit of work (a test, a seed, a battle, a script line).
func beat(label: String = "") -> void:
	beats += 1
	_last_beat_ms = Time.get_ticks_msec()
	_error_since_beat = false
	if label != "":
		last_label = label


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	var fresh := _errors.take()
	if not fresh.is_empty():
		_error_since_beat = true
		_recent_errors.append_array(fresh)
		_recent_errors = _recent_errors.slice(maxi(_recent_errors.size() - ERRORS_SHOWN, 0))
	if _error_since_beat and now - _last_beat_ms > ERROR_GRACE_MS:
		_stop("STOPPED: a script or engine error, then no progress for %d s (last: %s)" % [
			(now - _last_beat_ms) / 1000, last_label], EXIT_ERROR_STALLED)
		return
	if now - _last_beat_ms > idle_limit_ms:
		_stop("STALLED: no progress for %d s (last: %s)" % [(now - _last_beat_ms) / 1000, last_label], EXIT_STALLED)
		return
	if now - _last_alive_ms >= ALIVE_EVERY_MS:
		if beats > _beats_at_alive:
			print("[watchdog] alive: %d beats, last %s" % [beats, last_label])
		_beats_at_alive = beats
		_last_alive_ms = now


func _stop(why: String, code: int) -> void:
	print("[watchdog] %s; quitting with %d" % [why, code])
	if not _recent_errors.is_empty():
		print("[watchdog] the last script or engine errors:")
		for text in _recent_errors:
			print("  " + text)
	set_process(false)
	OS.remove_logger(_errors)
	get_tree().quit(code)


## A scene whose file gives its root a script, but whose root has none, failed to compile.
func _check_main_scene() -> void:
	for frame in 3:
		await get_tree().process_frame
	var scene := get_tree().current_scene
	if scene == null or scene.get_script() != null or scene.scene_file_path == "":
		return
	var packed := load(scene.scene_file_path) as PackedScene
	if packed == null:
		return
	var state := packed.get_state()
	for index in state.get_node_property_count(0):
		if state.get_node_property_name(0, index) == &"script":
			print("[watchdog] FAILED: %s's script did not load (a parse error?); quitting with %d" % [
				scene.scene_file_path, EXIT_SCRIPT_FAILED])
			get_tree().quit(EXIT_SCRIPT_FAILED)
			return
