## Spec ff7-ui 2.11 (console parity for Tab): `tab on` turns the floor-info view on (the minimap grows, the floor toast
## stays up), `tab off` turns it off, like one press of Tab each (playtest-fixes B28: Tab toggles, UIToggles).
## Presentation only: the run never sees it.
extends DevCommand

const ACTION: StringName = &"show_floor_info"


func _init() -> void:
	name = "tab"
	usage = "tab on|off"
	help = "Turns the Tab view (show_floor_info) on or off: the minimap grows and the floor toast stays up."
	cheat = false
	arg_kinds.assign(["text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null:
		return ctx.fail("no game scene")
	if args.is_empty() or not args[0] in ["on", "off"]:
		return ctx.fail("usage: " + usage)
	var held := args[0] == "on"
	UIToggles.set_on(ACTION, held)
	var touched := 0
	for node in _all(ctx.game):
		if node.has_method("set_held"):
			node.set_held(held)
			touched += 1
		elif node is UIToastHost:
			node.update()  # it reads UIToggles
			touched += 1
	return "tab %s (%d panel(s))" % [args[0], touched]


static func _all(root: Node) -> Array[Node]:
	var found: Array[Node] = [root]
	for child in root.get_children():
		found.append_array(_all(child))
	return found
