## In battle: the waiting party member uses an ability (target: a unit id like E1 or P2).
extends DevCommand


func _init() -> void:
	name = "act"
	usage = "act <ability tag> [target]"
	help = "In battle: the waiting member uses <ability> on <target> (E1, P2...)."
	cheat = false
	arg_kinds.assign(["ability", "text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.recorder == null or ctx.recorder.waiting_for == &"":
		return ctx.fail("no party member is waiting for an action")
	if args.is_empty():
		return ctx.fail("usage: " + usage)
	var unit := ctx.recorder.waiting_for
	ctx.recorder.submit_action(StringName(args[0]), StringName(args[1]) if args.size() > 1 else &"")
	return "%s: %s" % [unit, args[0]]
