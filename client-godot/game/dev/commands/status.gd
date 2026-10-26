## In battle: a unit's active statuses with their remaining turns and stacks (spec content-pass; the battle panel's
## status line, for Claude headless).
extends DevCommand


func _init() -> void:
	name = "status"
	usage = "status [unit]"
	help = "In battle: active statuses (turns, stacks) of a unit (E1, P2...) or of every unit."
	cheat = false
	arg_kinds.assign(["text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.battle == null or not is_instance_valid(ctx.battle):
		return ctx.fail("only in a battle")
	var units: Array[BattleUnit] = []
	if args.is_empty():
		units = ctx.battle.units()
	else:
		var unit := ctx.battle.unit_by_id(StringName(args[0]))
		if unit == null:
			return ctx.fail("no unit %s in this battle" % args[0])
		units.append(unit)
	var lines := PackedStringArray()
	for unit in units:
		lines.append("%s: %s" % [unit.unit_id, describe(unit.statuses())])
	return "\n".join(lines)


## "Burn 2 · Poison×3 2" ("-" when there are none). Turns are omitted for statuses that aren't turn-based.
static func describe(statuses: Array[Dictionary]) -> String:
	if statuses.is_empty():
		return "-"
	var parts := PackedStringArray()
	for status in statuses:
		var label: String = String(status["tag"]).get_slice(".", String(status["tag"]).get_slice_count(".") - 1)
		if int(status["stacks"]) > 1:
			label += "×%d" % status["stacks"]
		if int(status["turns"]) >= 0:
			label += " %d" % status["turns"]
		parts.append(label)
	return " · ".join(parts)
