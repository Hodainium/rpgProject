## Spec class-pick 6: drives the class pick headless (tool parity: every button of the screen is a command).
extends DevCommand

const SCREEN: String = "res://presentation/demo/ui/class_pick/class_pick.tscn"
const CardUi = preload("res://game/dev/commands/cardui.gd")


func _init() -> void:
	name = "classpick"
	usage = "classpick [open | state | turn <n> | select <character id> | add | remove <slot 1-4> | preset <id> | lockin | bench [seconds]]"
	help = "The class pick (New run). open: pushes it (main menu only). state: what it shows (the class in front, its state and hint, the party, the footer, the message, every class's ownership). turn <n>: turns the ring n classes (negative = left), like the arrows. select <id>: turns the ring to that class (the shortest way). add: Add / Remove on the class in front (refused for a locked class). remove <slot>: takes the member in that slot (1-4) out, like a click. preset <id>: loads a recommended party. lockin: Lock in (a continuable run's confirm is answered with ui press). bench [seconds]: the frame time of the main menu, then of the class pick with every cube live, vsync off (default 5 s each)."


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.ui == null:
		return ctx.fail("no game UI")
	var verb := args[0] if args.size() > 0 else "state"
	if verb == "open":
		var opened := await _open(ctx)
		return ctx.fail(ctx.error) if opened == null else "class pick open\n" + _state(opened)
	if verb == "bench":
		return await _bench(ctx, float(args[1]) if args.size() > 1 else 5.0)
	var screen := _screen(ctx)
	if screen != null:
		await _settled(ctx, screen)
	if screen == null or not is_instance_valid(screen) or not screen.is_inside_tree():
		return ctx.fail("the class pick is not open (classpick open)")
	match verb:
		"state":
			return _state(screen)
		"turn":
			if args.size() < 2 or not args[1].is_valid_int():
				return ctx.fail("usage: classpick turn <n>")
			screen.turn(int(args[1]))
		"select":
			var index := _index_of(screen, args[1] if args.size() > 1 else "")
			if index < 0:
				return ctx.fail("no class %s on the ring" % (args[1] if args.size() > 1 else "?"))
			screen.get_node("%Carousel").select(index)
		"add":
			var character: CharacterDefinition = screen.selected()
			if character == null:
				return ctx.fail("no class in front")
			if screen.get_node("%Add").disabled:
				return ctx.fail("refused: " + (screen.get_node("%Hint").text if screen.get_node("%Hint").text != "" else "Add is disabled"))
			screen.toggle_selected()
		"remove":
			var slot := int(args[1]) - 1 if args.size() > 1 and args[1].is_valid_int() else -1
			if slot < 0 or slot >= screen.max_party:
				return ctx.fail("usage: classpick remove <slot 1-%d>" % screen.max_party)
			screen.remove_slot(slot)
		"preset":
			var wanted := args[1] if args.size() > 1 else ""
			for preset in (screen.presets.presets if screen.presets != null else []):
				if preset != null and String(preset.id) == wanted:
					screen.apply_preset(preset)
					return _state(screen)
			return ctx.fail("no preset %s" % wanted)
		"lockin":
			if screen.get_node("%LockIn").disabled:
				return ctx.fail("refused: " + screen.get_node("%Footer").text)
			screen.lock_in()
			return "Lock in pressed"
		_:
			return ctx.fail("usage: " + usage)
	return _state(screen)


static func _open(ctx: DevContext) -> UIScreen:
	var screen := _screen(ctx)
	if screen == null:
		if ctx.game.mode != "menu":
			ctx.fail("the class pick opens from the main menu (mode is %s)" % ctx.game.mode)
			return null
		screen = ctx.game.ui.push(&"UI.Layer.Menu", load(SCREEN))
	if screen == null:
		ctx.fail("could not open the class pick")
		return null
	await _settled(ctx, screen)
	return screen


static func _screen(ctx: DevContext) -> UIScreen:
	var screen: UIScreen = ctx.game.ui.top(&"UI.Layer.Menu")
	return screen if screen != null and screen.scene_file_path == SCREEN else null


## Waits while the account's ownership is being read (server mode; at most 60 s).
static func _settled(ctx: DevContext, screen: UIScreen) -> void:
	await ctx.console.tree.process_frame
	var deadline := Time.get_ticks_msec() + 60000
	while is_instance_valid(screen) and screen.loading and Time.get_ticks_msec() < deadline:
		Watchdog.beat("classpick")
		await ctx.console.tree.process_frame


static func _index_of(screen: UIScreen, id: String) -> int:
	var characters: Array = screen.get_node("%Carousel").characters
	for i in characters.size():
		if String(characters[i].id) == id or String(characters[i].id).get_slice(".", 2) == id:
			return i
	return -1


static func _state(screen: UIScreen) -> String:
	var character: CharacterDefinition = screen.selected()
	var lines := PackedStringArray()
	lines.append("front: %s (%s)" % [String(character.id) if character != null else "-",
		screen.states.get(String(character.id), "?") if character != null else "-"])
	lines.append("add: %s%s" % [screen.get_node("%Add").text, " (disabled)" if screen.get_node("%Add").disabled else ""])
	if screen.get_node("%Hint").text != "":
		lines.append("hint: " + screen.get_node("%Hint").text)
	lines.append("party: [%s]" % ", ".join(screen.party.map(func(id) -> String: return String(id) if id != &"" else "-")))
	lines.append("footer: " + screen.get_node("%Footer").text)
	lines.append("lockin: %s" % ("disabled" if screen.get_node("%LockIn").disabled else "enabled"))
	if screen.get_node("%Message").visible:
		lines.append("message: " + screen.get_node("%Message").text)
	if screen.get_node("%DevLine").visible:
		lines.append(screen.get_node("%DevLine").text)
	var ids: Array = screen.states.keys()
	ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	lines.append("classes: " + ", ".join(ids.map(func(id) -> String: return "%s=%s" % [String(id).get_slice(".", 2), screen.states[id]])))
	return "\n".join(lines)


## The frame time of the main menu, then of the class pick (every cube and look effect live), vsync off (spec 6).
func _bench(ctx: DevContext, seconds: float) -> String:
	if ctx.game.mode != "menu":
		return ctx.fail("the bench runs from the main menu (mode is %s)" % ctx.game.mode)
	var tree := ctx.console.tree
	var open := _screen(ctx)
	if open != null:
		ctx.game.ui.back()
		await tree.process_frame
	var vsync := DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var menu: Dictionary = await CardUi._measure(tree, seconds)
	var screen := await _open(ctx)
	if screen == null:
		DisplayServer.window_set_vsync_mode(vsync)
		return ctx.fail(ctx.error)
	var full: Dictionary = await CardUi._measure(tree, seconds)
	DisplayServer.window_set_vsync_mode(vsync)
	var views: int = screen.get_node("%Carousel").views.size()
	var size: Vector2i = screen.get_node("%Viewport").size
	return "bench class pick (%d cubes live, stage %dx%d px), %.0f s each, vsync off\n  main menu:  %s\n  class pick: %s" % [views,
		size.x, size.y, seconds, CardUi._times(menu), CardUi._times(full)]
