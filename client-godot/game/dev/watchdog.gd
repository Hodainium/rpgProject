## Headless safeguard (spec dev-tools, "Headless safeguards and parallel runs"): a headless run never idles silently.
## Active only when the display server is headless; the editor and the game are untouched.
##
## - The main scene's root script failed to load (a parse error leaves the node scriptless, and Godot would idle until
##   --quit-after): print why and quit with 70.
## - No Watchdog.beat(label) for --idle-limit seconds (default 180): print the last label and quit with 124.
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

var active: bool = false
var idle_limit_ms: int = DEFAULT_IDLE_LIMIT * 1000
var beats: int = 0
var last_label: String = "start"

var _last_beat_ms: int = 0
var _last_alive_ms: int = 0
var _beats_at_alive: int = 0


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
	_check_main_scene.call_deferred()


## Progress: call it at each unit of work (a test, a seed, a battle, a script line).
func beat(label: String = "") -> void:
	beats += 1
	_last_beat_ms = Time.get_ticks_msec()
	if label != "":
		last_label = label


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_beat_ms > idle_limit_ms:
		print("[watchdog] STALLED: no progress for %d s (last: %s); quitting with %d" % [
			(now - _last_beat_ms) / 1000, last_label, EXIT_STALLED])
		set_process(false)
		get_tree().quit(EXIT_STALLED)
		return
	if now - _last_alive_ms >= ALIVE_EVERY_MS:
		if beats > _beats_at_alive:
			print("[watchdog] alive: %d beats, last %s" % [beats, last_label])
		_beats_at_alive = beats
		_last_alive_ms = now


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
