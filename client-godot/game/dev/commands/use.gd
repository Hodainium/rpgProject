## Uses a spell or held item on the map (a field action, like the party panel).
extends DevCommand


func _init() -> void:
	name = "use"
	usage = "use <slot> <ability tag> [target slot]"
	help = "Field action: member <slot> uses <ability> (on <target slot>)."
	cheat = false
	arg_kinds.assign(["slot", "text", "slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var slot: Variant = ctx.arg_int(args, 0, -1)
	var target: Variant = ctx.arg_int(args, 2, 0)
	if slot == null or target == null or args.size() < 2:
		return ctx.fail("usage: " + usage)
	var problem: Array = await ctx.run.use_field(slot, StringName(args[1]), target)
	return ctx.fail("%s: %s" % problem) if not problem.is_empty() else "used %s" % args[1]
