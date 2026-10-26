## Run-end screen (Menu layer while UI.State.End): won, lost or stopped; the run's summary (run_summary()), the seed
## and the run hash; Play again (same seed, party and run), New run (new seed), Menu.
extends UIScreen

@export var won_headline: String = "Victory!"
@export var lost_headline: String = "Run lost"
@export var stopped_format: String = "Stopped: %s"
@export var no_start_text: String = "The run could not start."


func bind(_context: UIContext) -> void:
	%Back.pressed.connect(func(): ctx.main.back_to_menu())
	%PlayAgain.pressed.connect(func(): _restart(str(ctx.run.state.run_seed)))
	%NewRun.pressed.connect(func(): _restart(RunSeeds.random_code()))


func refresh() -> void:
	var run := ctx.run
	var replayable := run != null and run.state != null and not run.state.sandbox and not run.run_log.is_empty()
	%PlayAgain.visible = replayable
	%NewRun.visible = replayable
	if run == null or run.state == null:
		%Text.text = no_start_text + "\n" + (run.runner_error if run != null else "")
		return
	var summary := run.run_summary()
	var headline := stopped_format % run.runner_error if run.runner_error != "" else \
		won_headline if run.state.status == RunState.WON else lost_headline
	var lines := PackedStringArray([headline, ""])
	lines.append("%s  ·  seed %s" % [run.structure.display_name if run.structure != null else summary["run"], summary["seed"]])
	lines.append("Party: " + ", ".join(run.state.party.map(func(member) -> String:
		var character: UnitDefinition = run.content.units.get(member["character"])
		return "%s Lv %d%s" % [character.display_name if character != null else String(member["character"]),
			member["level"], "" if member["alive"] else " (fallen)"])))
	lines.append("Floors cleared: %d / %d" % [summary["floorsCleared"], summary["floors"]])
	var ended: Dictionary = summary["endedIn"]
	if run.state.status == RunState.LOST:
		var where := "Fell on floor %d" % ended["floor"]
		if ended["room"] != "":
			where += ", in %s" % _name(run.content.rooms.get(StringName(ended["room"])), ended["room"])
		if ended["encounter"] != "":
			where += ", against %s" % _name(run.content.encounters.get(StringName(ended["encounter"])), ended["encounter"])
		lines.append(where)
	lines.append("Battles won: %d  ·  enemies defeated: %d" % [summary["battlesWon"], summary["enemiesDefeated"]])
	lines.append("Items taken: %d  ·  armor taken: %d  ·  event choices: %d" % [summary["itemsTaken"],
		summary["armorTaken"], summary["eventChoices"]])
	lines.append("Coins: %d earned, %d spent, %d left" % [summary["coinsEarned"], summary["coinsSpent"], summary["coins"]])
	lines.append("")
	lines.append("Run hash: %s" % run.state.run_hash())
	%Text.text = "\n".join(lines)


## A resource's display_name when it has one, else its id.
static func _name(resource: Resource, fallback: String) -> String:
	var shown = resource.get("display_name") if resource != null else null
	return shown if shown is String and shown != "" else fallback


## Same party and run as the run that just ended (its start_run entry), with `seed_text`.
func _restart(seed_text: String) -> void:
	var run := ctx.run
	ctx.main.start_run(run.run_log[0]["party"].duplicate(), seed_text, run.state.run_structure_id)
