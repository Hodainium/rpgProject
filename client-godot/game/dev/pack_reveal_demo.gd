## The pack reveal demo (playtest 2026-11-18): opens made-up packs on the real PackStage to compare the big reveal effects of
## Legendary and Mythic cards, the screen flash and the shake. Nothing reaches a server or the account: the cards come from the
## content's own catalog (PackReveal.demo), like `cardui pack demo`. A window scene:
##   godot --path client-godot res://game/dev/pack_reveal_demo.tscn [--screen 1 --fullscreen]
## Click a card or press Space to flip it; R opens the last pack again.
extends Control

const THEME := "res://presentation/demo/ui/ui_theme.tres"
const DEMO_PACK := "descent-pack"
## The big reveal effects on offer: id → name. The current pick comes first.
const EFFECTS := {
	&"fx.reveal_halo": "Halo (Legendary now)",
	&"fx.reveal_rays": "Rays, short (Mythic now)",
	&"fx.legendary_rays": "Rays, long",
	&"fx.reveal_starburst": "Starburst",
	&"fx.reveal_foil": "Foil sweep",
	&"": "None",
}
const PACKS := {
	"Legendary + Mythic": ["rare", "epic", "legendary", "mythic"],
	"One of each": ["common", "rare", "epic", "legendary", "mythic"],
	"Two Legendaries": ["legendary", "legendary"],
	"Mythic": ["mythic"],
	"Commons only": [],
}

var stage: PackStage
var plan: PackChoreography
var content: ContentIndex
var style: CardStyle
var _rarities: Array = PACKS["Legendary + Mythic"]
var _legendary: OptionButton
var _mythic: OptionButton
var _flash: CheckBox
var _shake: CheckBox
var _status: Label
var _opening: bool = false


func _ready() -> void:
	theme = load(THEME)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	style = CardStyle.current()
	plan = style.pack_choreography().duplicate(true)
	content = ContentIndex.new("res://content/")
	var background := ColorRect.new()
	background.color = Color(0.06, 0.05, 0.1)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 24)
	add_child(row)
	row.add_child(_build_panel())
	stage = PackStage.new()
	stage.name = "Stage"
	stage.style = style
	stage.plan_override = plan
	stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(stage)
	stage.card_pressed.connect(func(index: int) -> void: stage.flip(index))
	stage.all_revealed.connect(func() -> void: _say("All revealed. Open another pack, or press R for the same one."))
	_apply()
	open_pack.call_deferred(_rarities)


func _build_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var title := Label.new()
	title.text = "Pack reveal demo"
	title.theme_type_variation = &"Title"
	box.add_child(title)
	box.add_child(_muted("Made-up packs: nothing is sent to the server or the account."))
	box.add_child(_heading("Legendary reveal"))
	_legendary = _effect_picker(plan.rays_fx)
	box.add_child(_legendary)
	box.add_child(_heading("Mythic reveal"))
	_mythic = _effect_picker(plan.mythic_fx if plan.mythic_fx != &"" else plan.rays_fx)
	box.add_child(_mythic)
	_flash = CheckBox.new()
	_flash.text = "Screen flash on a Mythic"
	_flash.button_pressed = plan.screen_flash_tier <= 4
	_flash.toggled.connect(func(_on: bool) -> void: _apply())
	box.add_child(_flash)
	_shake = CheckBox.new()
	_shake.text = "Screen shake (Legendary and Mythic)"
	_shake.button_pressed = plan.shake_from_tier <= 4
	_shake.toggled.connect(func(_on: bool) -> void: _apply())
	box.add_child(_shake)
	box.add_child(_heading("Open a pack"))
	for label in PACKS:
		var button := Button.new()
		button.text = label
		button.pressed.connect(func() -> void: open_pack(PACKS[label]))
		box.add_child(button)
	var reveal_all := Button.new()
	reveal_all.text = "Reveal all"
	reveal_all.pressed.connect(func() -> void: stage.flip_all())
	box.add_child(reveal_all)
	_status = _muted("")
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	return panel


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _muted(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"Muted"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _effect_picker(current: StringName) -> OptionButton:
	var picker := OptionButton.new()
	for id in EFFECTS:
		picker.add_item(EFFECTS[id])
		picker.set_item_metadata(picker.item_count - 1, id)
		if id == current:
			picker.select(picker.item_count - 1)
	picker.item_selected.connect(func(_index: int) -> void: _apply())
	return picker


func _picked(picker: OptionButton) -> StringName:
	return picker.get_item_metadata(picker.selected) if picker.selected >= 0 else &""


## The choices go into the stage's choreography (in memory only; the style's file is not touched).
func _apply() -> void:
	plan.rays_fx = _picked(_legendary)
	plan.mythic_fx = _picked(_mythic)
	if plan.mythic_fx == &"":
		plan.mythic_fx = &"none"   # "None" on the Mythic means none, not the Legendary pick
	plan.screen_flash_tier = 4 if _flash.button_pressed else 99
	plan.shake_from_tier = 3 if _shake.button_pressed else 99
	_say("Legendary: %s. Mythic: %s." % [EFFECTS[_picked(_legendary)], EFFECTS[_picked(_mythic)]])


## Clears the stage and opens a made-up pack holding `rarities` (the rest Common).
func open_pack(rarities: Array) -> void:
	if _opening:
		return
	_opening = true
	_rarities = rarities
	stage.clear()
	var look := style.pack(DEMO_PACK)
	stage.socket_pack(look, look.label if look.label != "" else "Demo")
	await get_tree().create_timer(0.3).timeout
	var open := PackReveal.from_response(PackReveal.demo(CardCatalog.cards(content), rarities))
	if not is_instance_valid(stage):
		return
	var rows := {}
	for row in CardCatalog.cards(content):
		rows[str(row["id"])] = row
	var faces: Array = []
	for slot in open.slots:
		faces.append(CardFaces.face_of(content, style, rows.get(slot["id"], {"id": slot["id"], "rarity": slot["rarity"]})))
	await stage.burst(open, faces, look)
	_opening = false


func _say(text: String) -> void:
	if _status != null:
		_status.text = text


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			open_pack(_rarities)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_SPACE and stage.reveal != null:
			var next := stage.reveal.next_hidden()
			if next >= 0:
				stage.flip(next)
			get_viewport().set_input_as_handled()
