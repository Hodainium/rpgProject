## Cheat: kills enemies, the party or one member through GAS, at the next party decision (spec dev-tools 3.6).
extends DevCommand


func _init() -> void:
	name = "kill"
	usage = "kill [enemies|party|<slot>]"
	help = "In battle: HP to 0 at the next party decision (real death handling)."
	cheat = true
	arg_kinds.assign(["target"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var targets := args[0] if args.size() > 0 else "enemies"
	if not (targets in ["enemies", "party"] or targets.is_valid_int()):
		return ctx.fail("usage: " + usage)
	var error := ctx.run.dev_battle("kill", RunController.dev_effect("dev_kill"), targets, ctx.recorder)
	return ctx.fail(error) if error != "" else "kill %s queued for the next party decision" % targets
