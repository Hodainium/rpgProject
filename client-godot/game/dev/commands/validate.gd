## Runs the content validator on the game's content root (spec dev-tools 3.7).
extends DevCommand


func _init() -> void:
	name = "validate"
	usage = "validate [errors]"
	help = "Checks the content for broken references, empty pools, bad rooms; errors hides warnings."
	cheat = false
	arg_kinds.assign(["on_off"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	var root := ctx.game.content_root if ctx.game != null else "res://content/"
	var issues := ContentValidator.validate(ContentIndex.new(root), {"generate_seeds": 20})
	if args.size() > 0 and args[0] == "errors":
		issues = issues.filter(func(issue: ValidationIssue) -> bool: return issue.is_error())
	var text := ContentValidator.report(issues)
	return ctx.fail(text) if ContentValidator.error_count(issues) > 0 else text
