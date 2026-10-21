## Cheat: starts a fight with an encounter here, or puts an item (or one from a pool) in this room.
extends DevCommand


func _init() -> void:
	name = "spawn"
	usage = "spawn <encounter> | spawn item <item or equipment> [price] | spawn pool <tag> [price]"
	help = "A fight with <encounter> here; or a pedestal (price 0) / shop slot with an item, a piece of equipment, or one from a pool (items and equipment)."
	cheat = true
	arg_kinds.assign(["encounter", "item", "int"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	if args.is_empty():
		return ctx.fail("usage: " + usage)
	if args[0] in ["item", "pool"]:
		var price: Variant = ctx.arg_int(args, 2, 0)
		if args.size() < 2 or price == null:
			return ctx.fail("usage: " + usage)
		var item: Resource = null
		if args[0] == "item":
			item = ctx.content.equipment.get(StringName(args[1])) if ctx.content != null else null
			if item == null:
				item = ctx.find("item", args[1])
			if item == null:
				return ctx.fail(ctx.error)
		var error := ctx.run.dev_spawn_item(item, StringName(args[1]), price)
		if error != "":
			return ctx.fail(error)
		return "spawned %s%s" % ["a pickup" if item == null else String(item.id),
			"" if ctx.run.state.map.cells[ctx.run.state.current_cell]["cleared"] else " (takeable once the room is cleared)"]
	var encounter: EncounterDefinition = ctx.find("encounter", args[0])
	if encounter == null:
		return ctx.fail(ctx.error)
	var spawned := ctx.run.dev_spawn(encounter)
	return ctx.fail(spawned) if spawned != "" else "fight: %s" % encounter.id
