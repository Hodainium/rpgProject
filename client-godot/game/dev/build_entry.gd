## Main scene of the dev and full exported builds (spec playable-demo 3.12; project setting
## application/run/main_scene.dev_build, custom feature `dev_build` on those presets). Export templates take no scene
## on the command line, so this opens the scene named by the user arg `--scene <res://...>` (dev_run.tscn,
## run_tests.tscn, seed_report.tscn...) and the game when there is none. Never in the player build.
extends Node

const GAME: String = "res://game/game_main.tscn"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--scene")
	var scene := args[at + 1] if at >= 0 and at + 1 < args.size() else GAME
	if not ResourceLoader.exists(scene):
		printerr("build_entry: no scene %s in this build" % scene)
		get_tree().quit(1)
		return
	get_tree().change_scene_to_file.call_deferred(scene)
