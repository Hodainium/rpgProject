## Seed runner / generation viewer (spec dev-tools 2.5). One seed: its floor as a map with every room's content, no
## playing. Many seeds: SeedReport statistics. A copy of the floor's rules can be tuned live and saved. Basic on
## purpose; the same numbers come from game/tools/seed_report.tscn headless. Opened with F6 or the console's `seeds`.
extends Control

const ROLE_COLORS: Dictionary = {"start": Color(0.4, 0.8, 0.4), "normal": Color(0.75, 0.75, 0.75),
	"boss": Color(1.0, 0.4, 0.35), "special": Color(1.0, 0.85, 0.3)}
const RULE_FIELDS: Array[String] = ["base_rooms", "rooms_per_depth", "random_extra_rooms", "max_rooms", "branch_chance"]

var content: ContentIndex
var _seed: LineEdit
var _floor: SpinBox
var _count: SpinBox
var _map: GridContainer
var _details: RichTextLabel
var _rules: FloorGenRules
var _rules_original: FloorGenRules
var _rule_inputs: Dictionary = {}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	content = ContentIndex.new(PlayRequest.settings()["content_root"])
	var background := PanelContainer.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var page := VBoxContainer.new()
	background.add_child(page)

	var bar := HFlowContainer.new()
	page.add_child(bar)
	_seed = LineEdit.new()
	_seed.text = str(PlayRequest.settings()["seed"])
	_seed.placeholder_text = "seed or code"
	_seed.custom_minimum_size = Vector2(140, 0)
	bar.add_child(_seed)
	_floor = _spin(bar, "floor", 0, 20, 0)
	_button(bar, "Show", _show_one)
	_button(bar, "Play this seed", _play)
	_count = _spin(bar, "seeds", 1, 10000, 100)
	_button(bar, "Run seeds", _show_many)
	_button(bar, "Back to the game", func() -> void: get_tree().change_scene_to_file("res://game/game_main.tscn"))

	var rules_bar := HFlowContainer.new()
	page.add_child(rules_bar)
	for field in RULE_FIELDS:
		_rule_inputs[field] = _spin(rules_bar, field, 0, 100 if field == "branch_chance" else 200, 0)
	_button(rules_bar, "Reset rules", _load_rules)
	_button(rules_bar, "Save rules", _save_rules)

	var body := HSplitContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(body)
	_map = GridContainer.new()
	_map.custom_minimum_size = Vector2(520, 0)
	body.add_child(_map)
	_details = RichTextLabel.new()
	_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details.selection_enabled = true
	body.add_child(_details)
	_load_rules()
	_show_one()


## A copy of the rules of the floor's first chapter (tuned here, saved on request).
func _load_rules() -> void:
	_rules = null
	_rules_original = null
	if content.runs.size() != 1:
		return
	var slot: FloorSlot = content.runs.values()[0].floors[clampi(int(_floor.value), 0, content.runs.values()[0].floors.size() - 1)]
	if slot.chapters.is_empty() or slot.chapters[0].floor_gen_rules == null:
		return
	_rules_original = slot.chapters[0].floor_gen_rules
	_rules = _rules_original.duplicate()
	for field in RULE_FIELDS:
		_rule_inputs[field].set_value_no_signal(float(_rules.get(field)))


func _apply_rules() -> void:
	if _rules == null:
		return
	for field in RULE_FIELDS:
		_rules.set(field, _rule_inputs[field].value if field == "branch_chance" else int(_rule_inputs[field].value))


func _show_one() -> void:
	_apply_rules()
	var seed_value := RunSeeds.parse(_seed.text)
	for child in _map.get_children():
		child.queue_free()
	if seed_value < 0:
		_details.text = "not a seed: " + _seed.text
		return
	var result := SeedReport.floor_of(content, seed_value, int(_floor.value), _rules)
	if result["error"] != "":
		_details.text = "seed %s: %s" % [RunSeeds.display(seed_value), result["error"]]
		return
	var map: FloorMap = result["map"]
	_map.columns = map.size.x
	var lines := PackedStringArray(["seed %s (%d), floor %d, chapter %s, %d rooms, %d attempt(s)" % [
		RunSeeds.display(seed_value), seed_value, int(_floor.value), result["chapter"], map.cells.size(), map.attempts]])
	for index in map.size.x * map.size.y:
		var label := Label.new()
		label.custom_minimum_size = Vector2(56, 40)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 10)
		if map.cells.has(index):
			var data: Dictionary = map.cells[index]
			label.text = "%d\n%s" % [index, String(data["room"]).get_slice(".", String(data["room"]).get_slice_count(".") - 1)]
			label.modulate = ROLE_COLORS.get(data["role"], Color.WHITE)
			lines.append(_describe(index, data))
		_map.add_child(label)
	_details.text = "\n".join(lines)


func _describe(index: int, data: Dictionary) -> String:
	var cell_content: Dictionary = data["content"]
	var what := ""
	match cell_content["kind"]:
		"encounter":
			var elites: int = cell_content["enemies"].filter(func(enemy) -> bool: return enemy["variantId"] != null).size()
			what = "battle %s%s" % [cell_content["encounter"], " (%d elite)" % elites if elites > 0 else ""]
		"event":
			what = "event %s" % cell_content["event"]
	var pickups := PackedStringArray()
	for pickup in data["pickups"]:
		pickups.append("%s%s" % [pickup["item"], " $%d" % pickup["price"] if pickup["price"] > 0 else ""])
	return "%3d %-8s %-26s %s %s" % [index, data["role"], data["room"], what, ", ".join(pickups)]


func _show_many() -> void:
	_apply_rules()
	var seed_value := maxi(RunSeeds.parse(_seed.text), 0)
	_details.text = SeedReport.text(SeedReport.many(content, seed_value, int(_count.value), int(_floor.value), _rules))


func _save_rules() -> void:
	if _rules == null or _rules_original == null:
		return
	_apply_rules()
	for field in RULE_FIELDS:
		_rules_original.set(field, _rules.get(field))
	var error := ResourceSaver.save(_rules_original, _rules_original.resource_path)
	_details.text = "saved %s" % _rules_original.resource_path if error == OK else "could not save (%s)" % error_string(error)


func _play() -> void:
	var seed_text := _seed.text
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	var tree := get_tree()
	tree.root.add_child(game)
	tree.current_scene = game
	game.start_run(PlayRequest.party_for(game.content, PlayRequest.settings()["party"]), seed_text)
	queue_free()


func _spin(parent: Control, prefix: String, low: float, high: float, value: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.prefix = prefix
	spin.min_value = low
	spin.max_value = high
	spin.value = value
	parent.add_child(spin)
	return spin


func _button(parent: Control, text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)
