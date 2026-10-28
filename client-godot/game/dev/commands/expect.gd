## Spec dev-tools E3: checks one field of the run's report (DevReport.state_of, what the script runner writes as JSON),
## so a script states what it expects and fails when it doesn't hold.
extends DevCommand


func _init() -> void:
	name = "expect"
	usage = "expect <field|server.key> <value>"
	help = "Fails unless the report field (floor, status, runnerError, server.waitingForFloor…) equals the value as text."
	cheat = false
	arg_kinds.assign(["text", "text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.is_empty():
		return ctx.fail("usage: " + usage)
	var expected := " ".join(args.slice(1)).trim_prefix("\"").trim_suffix("\"")
	var report := DevReport.state_of(ctx.game.run if ctx.game != null else null)
	var value: Variant = report
	for key in args[0].split("."):
		if not (value is Dictionary and value.has(key)):
			return ctx.fail("%s: not in the report (%s)" % [args[0], ", ".join(report.keys())])
		value = value[key]
	var actual := _text(value)
	if actual != expected:
		return ctx.fail("%s is %s, expected %s" % [args[0], actual if actual != "" else "\"\"",
			expected if expected != "" else "\"\""])
	return "%s = %s" % [args[0], actual]


## Whole numbers without ".0" (JSON-like values), null as "".
static func _text(value: Variant) -> String:
	if value == null:
		return ""
	if value is float and is_equal_approx(value, roundf(value)):
		return str(int(value))
	return str(value)
