## Spec ff7-ui 2.11 (console parity for Tab): `tab on` holds the floor-info key (the minimap grows, the floor toast
## stays up), `tab off` releases it. Presentation only: the run never sees it.
extends DevCommand

const ACTION: StringName = &"show_floor_info"


func _init() -> void:
	name = "tab"
	usage = "tab on|off"
	help = "Holds or releases Tab (show_floor_info): the minimap grows and the floor toast stays up."
	cheat = false
	arg_kinds.assign(["text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null:
		return ctx.fail("no game scene")
	if args.is_empty() or not args[0] in ["on", "off"]:
		return ctx.fail("usage: " + usage)
	var held := args[0] == "on"
	var touched := 0
	for node in _all(ctx.game):
		if node.has_method("set_held"):
			node.set_held(held)
			touched += 1
		elif node is UIToastHost:
			node.hold(ACTION, held)
			touched += 1
	return "tab %s (%d panel(s))" % [args[0], touched]


static func _all(root: Node) -> Array[Node]:
	var found: Array[Node] = [root]
	for child in root.get_children():
		found.append_array(_all(child))
	return found
