## Spec card-collection 6 (e2e): a script states that a command must be refused.
extends DevCommand


func _init() -> void:
	name = "refused"
	usage = "refused <text> <command ...>"
	help = "Runs the command and passes only when it fails with a reply containing <text> (a script's way to say 'this must be refused', e.g. refused 1403 dust first). Anything else fails the line."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.size() < 2:
		return ctx.fail("usage: " + usage)
	var result: Dictionary = await ctx.console.execute(" ".join(args.slice(1)))
	if result["ok"]:
		return ctx.fail("expected '%s' to be refused, but it worked: %s" % [" ".join(args.slice(1)), result["text"]])
	if not str(result["text"]).contains(args[0]):
		return ctx.fail("refused, but not with '%s': %s" % [args[0], result["text"]])
	return "refused as expected: " + str(result["text"])
