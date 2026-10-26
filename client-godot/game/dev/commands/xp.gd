## Cheat: XP or free levels through the run's own GainXp / GainLevel paths (level-ups, class growth, messages).
extends DevCommand


func _init() -> void:
	name = "xp"
	usage = "xp <amount> [slot] | xp level <count> [slot]"
	help = "Gives XP (or `level` free levels) to every living member, or the one in [slot]."
	cheat = true
	arg_kinds.assign(["text", "slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var levels := args.size() > 0 and args[0] == "level"
	var rest := args.slice(1) if levels else args
	var amount: Variant = ctx.arg_int(rest, 0, -1)
	var slot: Variant = ctx.arg_int(rest, 1, 0)
	if amount == null or amount <= 0 or slot == null:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.dev_xp(amount, levels, slot)
	if error != "":
		return ctx.fail(error)
	var lines := PackedStringArray()
	for member in ctx.run.state.party:
		lines.append("%d %s Lv %d (XP %d)" % [member["slot"], member["character"], member["level"], member.get("xp", 0)])
	return "\n".join(lines)
