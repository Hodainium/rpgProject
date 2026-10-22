## In battle: a party member casts its ult out of turn (spec ult-interrupts), as if the player pressed its ult button.
extends DevCommand


func _init() -> void:
	name = "ult"
	usage = "ult <unit> <ult tag> [target]"
	help = "In battle: <unit> (P1..P4) casts <ult> at the next ult window, on <target> (E1, P2...; retargeted if gone)."
	cheat = false
	arg_kinds.assign(["text", "ult", "text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.recorder == null or ctx.battle == null or not ctx.battle.is_running():
		return ctx.fail("no battle is running")
	if args.size() < 2:
		return ctx.fail("usage: " + usage)
	var unit := ctx.battle.unit_by_id(StringName(args[0]))
	if unit == null or not unit.is_party():
		return ctx.fail("%s is not a party member" % args[0])
	var ability := unit.ability_by_tag(StringName(args[1]))
	if ability == null or not ability.is_ultimate():
		var ults := unit.ultimate_abilities().map(func(ult: BattleAbility) -> String: return String(ult.ability_tag))
		return ctx.fail("%s has no ult %s (its ults: %s)" % [unit.unit_id, args[1], ", ".join(ults) if not ults.is_empty() else "none"])
	ctx.recorder.submit_ult(unit.unit_id, ability.ability_tag, StringName(args[2]) if args.size() > 2 else &"")
	return "%s: %s queued for the next ult window" % [unit.unit_id, ability.ability_tag]
