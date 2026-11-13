## Saves the screen as a PNG (needs a window: the script runner with --window).
extends DevCommand


func _init() -> void:
	name = "shot"
	usage = "shot <name> [seconds]"
	help = "Screenshot to <shots folder>/<name>.png (needs a window); [seconds] waits first (a camera move, an effect)."
	cheat = false
	arg_kinds.assign(["text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if DisplayServer.get_name() == "headless":
		return ctx.fail("no window to capture (run the script runner with --window)")
	if args.is_empty() or ctx.console.tree == null:
		return ctx.fail("usage: " + usage)
	if args.size() > 1:
		if not args[1].is_valid_float() or float(args[1]) < 0.0:
			return ctx.fail("usage: " + usage)
		await ctx.console.tree.create_timer(float(args[1])).timeout
	await RenderingServer.frame_post_draw
	var image := ctx.console.tree.root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ctx.console.shots_dir))
	var path := ctx.console.shots_dir.path_join(args[0] + ".png")
	var error := image.save_png(path)
	return ctx.fail("could not save %s" % path) if error != OK else ProjectSettings.globalize_path(path)
