## Demo run-end screen (placeholder): won, lost or stopped by a runner error; the run's summary (spec playable-demo
## 3.6: run_summary()), the seed and the run hash; Play again (same seed, party and run), New run (new seed), Menu.
extends Control

var _main: GameMain

@onready var _text: Label = %Text
@onready var _play_again: Button = %PlayAgain
@onready var _new_run: Button = %NewRun


func setup(main: GameMain) -> void:
	_main = main
	%Back.pressed.connect(func(): _main.back_to_menu())
	_play_again.pressed.connect(func(): _restart(str(_main.run.state.run_seed)))
	_new_run.pressed.connect(func(): _restart(RunSeeds.random_code()))
	main.mode_changed.connect(_on_mode)
	visible = false


func _on_mode(mode: String) -> void:
	visible = mode == "end"
	if not visible:
		return
	var run := _main.run
	var replayable := run != null and run.state != null and not run.state.sandbox and not run.run_log.is_empty()
	_play_again.visible = replayable
	_new_run.visible = replayable
	if run == null or run.state == null:
		_text.text = "The run could not start.\n" + (run.runner_error if run != null else "")
		return
	var summary := run.run_summary()
	var headline := "Stopped: " + run.runner_error if run.runner_error != "" else \
		"Victory!" if run.state.status == RunState.WON else "Run %s" % run.state.status.to_lower()
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
	_text.text = "\n".join(lines)


## A resource's display_name when it has one, else its id.
static func _name(resource: Resource, fallback: String) -> String:
	var shown = resource.get("display_name") if resource != null else null
	return shown if shown is String and shown != "" else fallback


## Same party and run as the run that just ended (its start_run entry), with `seed_text`.
func _restart(seed_text: String) -> void:
	var run := _main.run
	var party: Array = run.run_log[0]["party"].duplicate()
	_main.start_run(party, seed_text, run.state.run_structure_id)
