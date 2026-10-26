## Spec ui-framework 2.6: the UI without a mouse (console parity). `ui` prints the state tags, each layer's stack and
## each slot's panels; `ui push <scene path> [layer]` opens a screen; `ui back` is Esc; `ui press <name or text> [n]`
## presses the n-th (default first) visible, enabled button whose node name or text matches, so window scripts can
## drive menus (`ui press Details 3`, `ui press "Start run"`).
extends DevCommand


func _init() -> void:
	name = "ui"
	usage = "ui [push <scene> [layer] | back | press <name or text> [n]]"
	help = "Shows the UI stacks and slots; opens a screen, goes back, or presses a button."
	cheat = false
	arg_kinds.assign(["text", "text", "text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	var game := ctx.game
	if game == null or game.ui == null:
		return ctx.fail("no UI (no GameMain, or its UI policy failed to load)")
	var manager: UIManager = game.ui
	manager.apply_now()
	if args.is_empty():
		return manager.dump()
	match args[0]:
		"back":
			return "back" if manager.back() else "nothing to close"
		"push":
			if args.size() < 2 or not ResourceLoader.exists(args[1]):
				return ctx.fail("usage: ui push <scene path> [layer]")
			var screen := manager.push(StringName(args[2]) if args.size() > 2 else &"UI.Layer.Menu", load(args[1]))
			return ctx.fail("could not push %s: %s" % [args[1], "; ".join(manager.problems)]) if screen == null \
				else "pushed %s" % screen.name
		"press":
			if args.size() < 2:
				return ctx.fail("usage: ui press <name or text> [n]")
			var wanted := maxi(int(args[2]) if args.size() > 2 else 1, 1)
			var found := _buttons(manager.layout, args[1])
			if found.size() < wanted:
				return ctx.fail("no button '%s' #%d (found %d)" % [args[1], wanted, found.size()])
			var button: BaseButton = found[wanted - 1]
			var path := button.get_path()  # before: pressing may free it (a dialog closing)
			if button.toggle_mode:
				button.button_pressed = not button.button_pressed
			else:
				button.pressed.emit()
			return "pressed %s" % path
	return ctx.fail("usage: " + usage)


## Visible, enabled buttons named or labelled `key`, in tree order.
static func _buttons(root: Node, key: String) -> Array[BaseButton]:
	var found: Array[BaseButton] = []
	if root is BaseButton and root.is_visible_in_tree() and not root.disabled:
		if String(root.name) == key or (root is Button and root.text == key):
			found.append(root)
	for child in root.get_children():
		found.append_array(_buttons(child, key))
	return found
