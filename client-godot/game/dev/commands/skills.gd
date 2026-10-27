## Lists a member's level table (spec skill-points D18): each row's level, ability and what it replaces, learned or
## not yet; with no slot, every member.
extends DevCommand


func _init() -> void:
	name = "skills"
	usage = "skills [slot]"
	help = "Lists a party member's level skills (all members without a slot): learned, and those unlocked at a later level."
	cheat = false
	arg_kinds.assign(["slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var lines := PackedStringArray()
	for member in ctx.run.state.party:
		if args.size() > 0 and str(member["slot"]) != args[0]:
			continue
		var character: UnitDefinition = ctx.run.content.units.get(member["character"])
		if character == null:
			continue
		var level := int(member["level"])
		lines.append("%d. %s, level %d" % [member["slot"], character.display_name, level])
		for row in character.level_skills:
			if row == null or row.ability == null:
				continue
			var replaces := " (replaces %s)" % row.replaces if row.replaces != &"" else ""
			lines.append("   Lv %d %s%s: %s" % [row.level, SkillTags.tag_of(row.ability), replaces,
				"learned" if row.level <= level else "unlocked at level %d" % row.level])
		if character.level_skills.is_empty():
			lines.append("   no level skills")
	if lines.is_empty():
		return ctx.fail("no party member in slot %s" % args[0])
	return "\n".join(lines)
