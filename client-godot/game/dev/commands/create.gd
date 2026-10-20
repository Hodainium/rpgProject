## The dock's Create without a window: a new asset from its template (spec dev-tools 3.8).
extends DevCommand


func _init() -> void:
	name = "create"
	usage = "create <type> <id> [folder]"
	help = "New content from a template (never overwrites; folder default content/demo/<type>s/)."
	cheat = false
	arg_kinds.assign(["type", "text", "text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.size() < 2:
		return ctx.fail("usage: %s  (types: %s)" % [usage, ", ".join(ContentTemplates.TYPES.keys())])
	var content := ContentIndex.new(ctx.game.content_root if ctx.game != null else "res://content/")
	var folder := args[2] if args.size() > 2 else ContentTemplates.default_folder(args[0])
	var result := ContentTemplates.save_new(args[0], args[1], folder, content)
	if result["error"] != "":
		return ctx.fail(result["error"])
	if ctx.game != null:
		ctx.game.load_content()
	return "created " + result["path"]
