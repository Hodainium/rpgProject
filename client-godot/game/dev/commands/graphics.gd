## Playtest-fixes B25: the window's graphics settings (the Graphics screen): shows them, or applies and saves one.
## Presentation only, never a cheat.
extends DevCommand


func _init() -> void:
	name = "graphics"
	usage = "graphics [aa off|fxaa|msaa_2x|msaa_4x|msaa_8x | fullscreen on|off]"
	help = "Graphics settings: show the anti-aliasing and fullscreen, or apply and save one (the Graphics screen)."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	var viewport := ctx.console.tree.root
	if args.is_empty():
		return "anti-aliasing: %s (saved: %s); fullscreen: %s (saved: %s)" % [GraphicsSettings.current_aa(viewport),
			GraphicsSettings.saved_aa(), "on" if GraphicsSettings.is_fullscreen() else "off",
			"on" if GraphicsSettings.saved_fullscreen() else "off"]
	match args[0]:
		"aa":
			if args.size() < 2:
				return ctx.fail("usage: " + usage)
			var problem := GraphicsSettings.set_aa(viewport, args[1])
			if problem != "":
				return ctx.fail(problem)
			return "anti-aliasing: %s" % args[1]
		"fullscreen":
			if args.size() < 2 or not args[1] in ["on", "off"]:
				return ctx.fail("usage: " + usage)
			GraphicsSettings.set_fullscreen(args[1] == "on")
			return "fullscreen: %s" % args[1]
	return ctx.fail("usage: " + usage)
