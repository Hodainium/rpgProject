## Lists items and equipment (spec item-pass 3.5): id, kind (or equipment slot), pools and description.
extends DevCommand


func _init() -> void:
	name = "items"
	usage = "items [tag]"
	help = "Lists every item and piece of equipment, or only those carrying <tag> (e.g. Pool.Shop)."
	cheat = false
	arg_kinds.assign(["text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.content == null:
		return ctx.fail("no content loaded")
	var tag := StringName(args[0]) if args.size() > 0 else &""
	var lines := PackedStringArray()
	for table in [ctx.content.items, ctx.content.equipment]:
		var ids: Array = table.keys()
		ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))
		for id in ids:
			var entry: Resource = table[id]
			if tag != &"" and not TagMatch.has(entry.tags, tag):
				continue
			var kind := "equipment %s" % entry.slot if entry is EquipmentDefinition \
				else ("usable" if entry.is_usable() else "passive")
			lines.append("%s  %s  [%s]%s" % [id, kind, ", ".join(entry.tags),
				"  " + entry.description if entry.description != "" else ""])
	if lines.is_empty():
		return "no items" + (" with %s" % tag if tag != &"" else "")
	return "\n".join(lines)
