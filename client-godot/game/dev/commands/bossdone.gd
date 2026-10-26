## Cheat: the floor's boss counts as beaten (no battle, rewards or XP), so the stairs and route choice can be tested.
extends DevCommand


func _init() -> void:
	name = "bossdone"
	usage = "bossdone"
	help = "Marks this floor's boss as beaten: the stairs open (the last floor: the run is won)."
	cheat = true


func run(ctx: DevContext, _args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var error := ctx.run.dev_boss_done()
	if error != "":
		return ctx.fail(error)
	if ctx.run.state.status != RunState.ACTIVE:
		return "boss beaten; the run is %s" % ctx.run.state.status
	var choices := ctx.run.next_floor_choices().map(func(chapter: ChapterDefinition) -> String: return String(chapter.id))
	return "boss beaten; stairs open%s" % ((" (choose: %s)" % ", ".join(choices)) if choices.size() > 1 else "")
