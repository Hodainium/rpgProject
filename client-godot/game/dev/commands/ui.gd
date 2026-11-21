## Spec ui-framework 2.6: the UI without a mouse (console parity). `ui` prints the state tags, each layer's stack and
## each slot's panels; `ui push <scene path> [layer]` opens a screen; `ui back` is Esc; `ui press <name or text> [n]`
## presses the n-th (default first) visible, enabled button whose node name, text or "ui_text" meta matches, so window
## scripts can drive menus (`ui press Details 3`, `ui press "Start run"`). Spec ui-feedback: `ui refused [last]` prints the
## last refusal's text and target; `ui flash <node name>` plays the refusal flash on the first visible control so named.
extends DevCommand


func _init() -> void:
	name = "ui"
	usage = "ui [push <scene> [layer] | back | press <name or text> [n] | refused [last] | flash <node name>]"
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
		"refused":
			var last: Dictionary = game.last_refusal
			if last.is_empty():
				return "no refusal yet"
			var data: Dictionary = last["data"]
			var extras := PackedStringArray()
			for key in data.keys().filter(func(k) -> bool: return str(k) != String(UIRefusal.TARGET)):
				extras.append("%s=%s" % [key, data[key]])
			return "%s · target %s%s" % [last["text"], str(data.get(UIRefusal.TARGET, "(none)")),
				(" " + " ".join(extras)) if not extras.is_empty() else ""]
		"flash":
			if args.size() < 2:
				return ctx.fail("usage: ui flash <node name>")
			var control := _control(manager.layout, args[1])
			if control == null:
				return ctx.fail("no visible control named '%s'" % args[1])
			UIFlash.refuse(control)
			return "flashed %s" % control.get_path()
	return ctx.fail("usage: " + usage)


## The first visible control named `key`, in tree order.
static func _control(root: Node, key: String) -> Control:
	if root is Control and root.is_visible_in_tree() and String(root.name) == key:
		return root
	for child in root.get_children():
		var found := _control(child, key)
		if found != null:
			return found
	return null


## Visible, enabled buttons named or labelled `key`, in tree order.
static func _buttons(root: Node, key: String) -> Array[BaseButton]:
	var found: Array[BaseButton] = []
	if root is BaseButton and root.is_visible_in_tree() and not root.disabled:
		# A button that draws its label in a child Label (list entries) names it in the "ui_text" meta.
		if String(root.name) == key or (root is Button and root.text == key) or str(root.get_meta("ui_text", "")) == key:
			found.append(root)
	for child in root.get_children():
		found.append_array(_buttons(child, key))
	return found
