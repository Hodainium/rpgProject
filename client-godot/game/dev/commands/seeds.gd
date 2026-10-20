## Opens the seed runner.
extends DevCommand


func _init() -> void:
	name = "seeds"
	usage = "seeds"
	help = "Opens the seed runner (floors for many seeds)."
	cheat = false
	arg_kinds.assign([])


const SCENE: String = "res://game/dev/seed_runner.tscn"


func run(ctx: DevContext, _args: PackedStringArray) -> String:
	if not ResourceLoader.exists(SCENE) or ctx.console.tree == null:
		return ctx.fail("the seed runner isn't available")
	ctx.console.tree.change_scene_to_file.call_deferred(SCENE)
	return "opening the seed runner"
