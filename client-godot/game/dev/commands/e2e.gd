## Spec dev-tools E3: a fault step for the end-to-end harness (tools/e2e.sh). Writes the action to
## <control>/request and waits for the harness to act and write <control>/done ("ok" or why not).
extends DevCommand

const ACTIONS: Array[String] = ["server-stop", "server-start", "redis-flush", "worker-start", "worker-stop", "tamper-battle"]
const DEFAULT_SECONDS: float = 60.0


func _init() -> void:
	name = "e2e"
	usage = "e2e server-stop | server-start | redis-flush | worker-start | worker-stop | tamper-battle [seconds]"
	help = "End-to-end harness only (dev_run --control): asks the harness for a fault and waits until it is done. worker-start / worker-stop: the verifier worker (stop kills it mid-job); tamper-battle: the stored log of the run's first battle is altered, so the verifier must reject it."
	cheat = false
	arg_kinds.assign(["text", "int"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.is_empty() or not ACTIONS.has(args[0]):
		return ctx.fail("usage: " + usage)
	var folder := ctx.console.control_dir
	if folder == "":
		return ctx.fail("no control folder: run the script with dev_run --control <folder> (tools/e2e.sh does)")
	var seconds := float(args[1]) if args.size() > 1 and args[1].is_valid_float() else DEFAULT_SECONDS
	var request := folder.path_join("request")
	var done := folder.path_join("done")
	DirAccess.make_dir_recursive_absolute(folder)
	if FileAccess.file_exists(done):
		DirAccess.remove_absolute(done)
	var file := FileAccess.open(request, FileAccess.WRITE)
	if file == null:
		return ctx.fail("can't write %s" % request)
	file.store_string(args[0])
	file.close()
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not FileAccess.file_exists(done):
		if Time.get_ticks_msec() > deadline:
			DirAccess.remove_absolute(request)
			return ctx.fail("the harness didn't do %s within %s s" % [args[0], seconds])
		Watchdog.beat("e2e " + args[0])
		await ctx.console.tree.create_timer(0.1).timeout
	var answer := FileAccess.get_file_as_string(done).strip_edges()
	DirAccess.remove_absolute(done)
	if FileAccess.file_exists(request):
		DirAccess.remove_absolute(request)
	return "%s: done" % args[0] if answer == "ok" else ctx.fail("%s: %s" % [args[0], answer])
