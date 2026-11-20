## Spec class-pick 2.6: the dev run setup modal (dev console `runsetup open`; never in the player build): the content root
## (when there is more than one), the run (the default marked) and the seed with Random (local mode only). Writes
## GameMain.dev_run_setup for this session; Clear goes back to the defaults; Back closes it.
extends UIScreen

@export var server_seed_text: String = "issued by the server"
@export var random_seed_text: String = "blank = random"
@export var default_mark: String = "  (default)"

const RunSetupCommand = preload("res://game/dev/commands/runsetup.gd")


func bind(context: UIContext) -> void:
	%ContentRoot.item_selected.connect(func(index: int) -> void:
		var roots := GameMain.content_roots()
		if index >= 0 and index < roots.size() and roots[index] != ctx.main.content_root:
			RunSetupCommand.use_content_root(ctx.main, roots[index])
		refresh())
	%RunPicker.item_selected.connect(func(index: int) -> void:
		ctx.main.dev_run_setup["run_id"] = str(%RunPicker.get_item_metadata(index))
		_changed())
	%Seed.text_changed.connect(func(text: String) -> void:
		var code := text.strip_edges()
		if code != "" and RunSeeds.parse(code) >= 0:
			ctx.main.dev_run_setup["seed"] = code   # only a seed that parses (as `runsetup seed` checks)
		else:
			ctx.main.dev_run_setup.erase("seed")    # empty or not (yet) a seed: none, never a stale prefix
		_changed())
	%Random.pressed.connect(func() -> void:
		%Seed.text = RunSeeds.random_code()
		ctx.main.dev_run_setup["seed"] = %Seed.text
		_changed())
	%Clear.pressed.connect(func() -> void:
		var refused: String = RunSetupCommand.clear(ctx.main)
		if refused != "":
			ctx.main.show_message(refused)
		refresh())
	context.main.content_changed.connect(func(_content: ContentIndex) -> void: refresh())


func on_activated() -> void:
	refresh()


func refresh() -> void:
	var roots := GameMain.content_roots()
	%ContentRoot.clear()
	for path in roots:
		%ContentRoot.add_item(path)
	%ContentRoot.select(maxi(roots.find(ctx.main.content_root), 0))
	%ContentRoot.visible = roots.size() > 1
	var setup: Dictionary = ctx.main.dev_run_setup
	%RunPicker.clear()
	for entry in ctx.main.runs():
		%RunPicker.add_item("%s%s" % [entry["name"], default_mark if entry["default"] else ""])
		%RunPicker.set_item_metadata(%RunPicker.item_count - 1, String(entry["id"]))
		if String(entry["id"]) == str(setup.get("run_id", "")) or (str(setup.get("run_id", "")) == "" and entry["default"]):
			%RunPicker.select(%RunPicker.item_count - 1)
	var linked: bool = ctx.main.server != null
	if linked:
		setup.erase("seed")   # the server issues the seeds
	%Seed.editable = not linked
	%Random.disabled = linked
	%Seed.placeholder_text = server_seed_text if linked else random_seed_text
	%Seed.text = "" if linked else str(setup.get("seed", ""))
	_changed()


func _changed() -> void:
	%Summary.text = RunSetupCommand.describe(ctx.main)
	var below: UIScreen = ctx.ui.top(&"UI.Layer.Menu")
	if below != null:
		below.refresh()
