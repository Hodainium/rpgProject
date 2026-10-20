## The "RPG Content" dock (spec dev-tools 2.3): Create (a new asset from its template, opened in the inspector),
## Validate (content problems; click one to open its file) and the Play settings every Play button uses.
@tool
extends VBoxContainer

var _type: OptionButton
var _id: LineEdit
var _folder: LineEdit
var _status: Label
var _issues: ItemList
var _party: LineEdit
var _seed: LineEdit
var _depth: SpinBox
var _chapter: LineEdit
var _root: LineEdit


func _ready() -> void:
	var play := PlayRequest.settings()
	_heading("Create")
	_type = OptionButton.new()
	for type in ContentTemplates.TYPES:
		_type.add_item(type)
	_type.item_selected.connect(func(_index: int) -> void: _folder.text = _folder_for(_type_name(), play))
	add_child(_type)
	_id = _field("id, e.g. demo.enemy.slime")
	_folder = _field("folder")
	_folder.text = _folder_for(_type_name(), play)
	var create := Button.new()
	create.text = "Create"
	create.pressed.connect(_on_create)
	add_child(create)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	_heading("Validate")
	var validate := Button.new()
	validate.text = "Validate content"
	validate.pressed.connect(_on_validate)
	add_child(validate)
	_issues = ItemList.new()
	_issues.custom_minimum_size = Vector2(0, 140)
	_issues.item_activated.connect(_on_issue)
	add_child(_issues)

	_heading("Play settings")
	_party = _field("party: character ids, comma separated (empty = first two)")
	_party.text = ", ".join(play["party"].map(func(id): return str(id)))
	_seed = _field("seed (number or code)")
	_seed.text = str(play["seed"])
	_depth = SpinBox.new()
	_depth.prefix = "depth"
	_depth.max_value = 20
	_depth.value = int(play["depth"])
	add_child(_depth)
	_chapter = _field("chapter id (empty = automatic)")
	_chapter.text = str(play["chapter"])
	_root = _field("content root")
	_root.text = str(play["content_root"])
	for edit in [_party, _seed, _chapter, _root]:
		edit.text_changed.connect(func(_text: String) -> void: _save_play())
	_depth.value_changed.connect(func(_value: float) -> void: _save_play())


func _on_create() -> void:
	var content := ContentIndex.new(_root.text)
	var result := ContentTemplates.save_new(_type_name(), _id.text.strip_edges(), _folder.text.strip_edges(), content)
	if result["error"] != "":
		_status.text = result["error"]
		return
	_status.text = "Created " + result["path"]
	var folders: Dictionary = PlayRequest.settings()["folders"]
	folders[_type_name()] = _folder.text.strip_edges()
	PlayRequest.save_settings({"folders": folders})
	EditorInterface.get_resource_filesystem().update_file(result["path"])
	EditorInterface.edit_resource(result["resource"])


func _on_validate() -> void:
	_issues.clear()
	var issues := ContentValidator.validate(ContentIndex.new(_root.text), {"generate_seeds": 20})
	if issues.is_empty():
		_issues.add_item("No problems.")
	for issue in issues:
		var index := _issues.add_item(str(issue))
		_issues.set_item_metadata(index, issue.path.get_slice("::", 0))
		_issues.set_item_custom_fg_color(index, Color(1, 0.45, 0.4) if issue.is_error() else Color(1, 0.85, 0.4))


func _on_issue(index: int) -> void:
	var path: Variant = _issues.get_item_metadata(index)
	if path is String and ResourceLoader.exists(path):
		EditorInterface.edit_resource(load(path))


func _save_play() -> void:
	var party: Array = []
	for id in _party.text.split(",", false):
		if id.strip_edges() != "":
			party.append(id.strip_edges())
	PlayRequest.save_settings({"party": party, "seed": _seed.text.strip_edges(), "depth": int(_depth.value),
		"chapter": _chapter.text.strip_edges(), "content_root": _root.text.strip_edges()})


func _type_name() -> String:
	return _type.get_item_text(_type.selected)


static func _folder_for(type: String, play: Dictionary) -> String:
	return str(play["folders"].get(type, ContentTemplates.default_folder(type)))


func _heading(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	add_child(label)


func _field(placeholder: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	add_child(edit)
	return edit
