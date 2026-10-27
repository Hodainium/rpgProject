## In battle: a unit's active statuses with their remaining turns and stacks (spec content-pass; the battle panel's
## status line, for Claude headless), and (spec skill-points) its level, SP, SP per basic and SP gain and cost.
extends DevCommand


func _init() -> void:
	name = "status"
	usage = "status [unit]"
	help = "In battle: a unit's (E1, P2...) or every unit's level, SP (SP per basic, gain and cost %) and active statuses (turns, stacks)."
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
		lines.append("%s: Lv %d%s · %s" % [unit.unit_id, unit.level, sp_text(unit), describe(unit.statuses())])
	return "\n".join(lines)


## " · SP 45/100 (+13 a basic, gain 128%, cost 100%)", or "" for a unit without SP (enemies).
@warning_ignore("integer_division")
static func sp_text(unit: BattleUnit) -> String:
	if not unit.is_party() or not unit.asc.has_attribute(BattleUnit.MAX_MP) or unit.stat(BattleUnit.MAX_MP) <= 0:
		return ""
	var text := " · SP %d/%d" % [unit.stat(BattleUnit.MP) / 100, unit.stat(BattleUnit.MAX_MP) / 100]
	if unit.asc.has_attribute("sp_basic"):
		text += " (+%d a basic, gain %d%%, cost %d%%)" % [AutoPolicy.basic_gain(unit) / 100, unit.stat("sp_gain") / 100,
			unit.stat("sp_cost") / 100]
	return text


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
