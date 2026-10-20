## Cheat: revives dead members at 1 HP through GAS, like a revive item.
extends DevCommand


func _init() -> void:
	name = "revive"
	usage = "revive [slot]"
	help = "Revives dead members (or one) at 1 HP, outside battle."
	cheat = true
	arg_kinds.assign(["slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var slot: Variant = ctx.arg_int(args, 0, 0)
	if slot == null:
		return ctx.fail("usage: " + usage)
	var dead: Array = []
	for member in ctx.run.state.party:
		if not member["alive"] and (slot == 0 or member["slot"] == slot):
			dead.append(member["slot"])
	if dead.is_empty():
		return ctx.fail("nobody to revive")
	var error := ctx.run.dev_apply("revive", RunController.dev_effect("dev_revive"), dead, true)
	return ctx.fail(error) if error != "" else "revived %s" % str(dead)
