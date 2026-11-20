## Spec class-pick 2.6: the dev run setup (D10): the run, the seed and the content root the class pick's Lock in uses, set here
## instead of on the player's screen. Dev and full builds only; for this session only (GameMain.dev_run_setup).
extends DevCommand

const MODAL: String = "res://game/dev/run_setup.tscn"


func _init() -> void:
	name = "runsetup"
	usage = "runsetup [open | show | clear | content <root> | run <run id> | seed <code>]"
	help = "The dev run setup the class pick's Lock in uses (this session only; empty = the content's default run and a random or server-issued seed). open: the modal with the content root, run and seed pickers. show: the values. clear: back to the defaults. content <root>: switches the content root now (GameMain.content_roots). run <id>: the run structure to start. seed <code>: the seed (local mode only; the server issues seeds online)."


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null:
		return ctx.fail("no game")
	var verb := args[0] if args.size() > 0 else "show"
	var setup: Dictionary = ctx.game.dev_run_setup
	match verb:
		"show":
			pass
		"open":
			if ctx.game.ui == null:
				return ctx.fail("no game UI")
			if ctx.game.ui.push(&"UI.Layer.Modal", load(MODAL)) == null:
				return ctx.fail("could not open the run setup")
		"clear":
			if ctx.game.mode != "menu" and ctx.game.dev_run_setup.has("content_root"):
				return ctx.fail("the content root changes only from the menus (mode is %s)" % ctx.game.mode)
			clear(ctx.game)
		"content":
			if ctx.game.mode != "menu":
				return ctx.fail("the content root changes only from the menus (mode is %s)" % ctx.game.mode)
			var root := args[1] if args.size() > 1 else ""
			if not GameMain.content_roots().has(root):
				return ctx.fail("unknown content root %s (%s)" % [root, ", ".join(GameMain.content_roots())])
			use_content_root(ctx.game, root)
		"run":
			var id := args[1] if args.size() > 1 else ""
			if not ctx.game.runs().any(func(entry: Dictionary) -> bool: return String(entry["id"]) == id):
				return ctx.fail("no run %s in %s" % [id, ctx.game.content_root])
			setup["run_id"] = id
		"seed":
			if ctx.game.server != null:
				return ctx.fail("server mode: the server issues the seeds")
			if args.size() < 2:
				return ctx.fail("usage: runsetup seed <code>")
			if RunSeeds.parse(args[1]) < 0:
				return ctx.fail("not a seed: %s (a seed code or a whole number)" % args[1])
			setup["seed"] = args[1]
		_:
			return ctx.fail("usage: " + usage)
	_refresh_class_pick(ctx)
	return describe(ctx.game)


## Switches the content root now (the screens follow content_changed) and keeps it in the setup, so `clear` can go back.
static func use_content_root(game: GameMain, root: String) -> void:
	game.set_content_root(root, false)   # for this session only (Q5): the Settings keep their root
	game.dev_run_setup.erase("run_id")   # a run of the old root
	if root == GameMain.CONTENT_ROOTS[0]:
		game.dev_run_setup.erase("content_root")
	else:
		game.dev_run_setup["content_root"] = root


## Back to the defaults: the default content root, the default run, a random or server-issued seed.
static func clear(game: GameMain) -> void:
	if game.dev_run_setup.has("content_root") and game.content_root != GameMain.CONTENT_ROOTS[0]:
		use_content_root(game, GameMain.CONTENT_ROOTS[0])
	game.dev_run_setup.clear()


static func describe(game: GameMain) -> String:
	var setup: Dictionary = game.dev_run_setup
	return "content %s · run %s · seed %s" % [game.content_root, str(setup.get("run_id", "")) if str(setup.get("run_id", "")) != ""
		else "(default)", str(setup.get("seed", "")) if str(setup.get("seed", "")) != "" else "(random or server)"]


static func _refresh_class_pick(ctx: DevContext) -> void:
	if ctx.game.ui == null:
		return
	var screen: UIScreen = ctx.game.ui.top(&"UI.Layer.Menu")
	if screen != null:
		screen.refresh()
