## Cheat: full HP and MP through GAS (in battle: at the next party decision).
extends DevCommand


func _init() -> void:
	name = "heal"
	usage = "heal [slot]"
	help = "Full HP and MP for living members (or one). In battle: at the next party decision."
	cheat = true
	arg_kinds.assign(["slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var slot: Variant = ctx.arg_int(args, 0, 0)
	if slot == null:
		return ctx.fail("usage: " + usage)
	var effect := RunController.dev_effect("dev_heal")
	var error: String
	if not ctx.run.pending_battle.is_empty():
		error = ctx.run.dev_battle("heal", effect, str(slot) if slot > 0 else "party", ctx.recorder)
		return ctx.fail(error) if error != "" else "heal queued for the next party decision"
	error = ctx.run.dev_apply("heal", effect, [slot] if slot > 0 else [], false)
	return ctx.fail(error) if error != "" else "healed"
