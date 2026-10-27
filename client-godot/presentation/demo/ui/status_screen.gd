## Spec ff7-ui 2.10 (F13): the Status screen. Pick a party member at the bottom (hover previews), then Info, Held
## Items or Status on the left (hover previews); the details show to the right. Info: the class description and the
## kit. Held Items: the member's passive items (hover one for what it does). Status: HP, MP, XP, ult, then the stats
## with the bonus over the class base at this level (RunController.member_stats, read-only).
extends DemoMenuFrame

const TABS: Array[String] = ["info", "held", "stats"]

@export var tab_texts: Dictionary = {"info": "Info", "held": "Held Items", "stats": "Status"}
@export var level_format: String = "%s · LV %d"
@export var no_items_text: String = "No held items."
## The stat labels shown, in order (keys of RunController.MEMBER_STATS).
@export var stat_labels: Dictionary = {"max_hp": "Max HP", "max_mp": "Max SP", "atk": "ATK", "def": "DEF",
	"spd": "SPD", "crit_rate": "Crit rate", "crit_dmg": "Crit damage", "weakness_dmg": "Weakness damage",
	"toughness_dmg": "Break power", "broken_dmg": "Damage to Broken", "heal_mult": "Healing done",
	"heal_taken": "Healing received", "def_pen": "DEF ignored", "debuff_turns": "Debuff turns"}
## Stats shown as percentages (×100 stored: 500 = 5%).
@export var percent_stats: Array[String] = ["crit_rate", "crit_dmg", "weakness_dmg", "toughness_dmg", "broken_dmg",
	"heal_mult", "heal_taken", "def_pen"]
@export var kit_hidden: Array[String] = ["Ult Charge", "Ult Charge Hit", "Break Physical", "Break Fire", "Break Ice",
	"Sp Gain"]
## Spec skill-points: after the description of a level skill not reached yet; its row is dimmed.
@export var unlock_format: String = "Unlocked at level %d."
@export var locked_alpha: float = 0.45

var _member: int = 0
var _member_preview: int = 0
var _tab: String = "info"
var _tab_preview: String = ""


func bind(context: UIContext) -> void:
	context.on_run(self, &"party_changed", func(): refresh.call_deferred())


func refresh() -> void:
	if ctx == null or ctx.run == null or ctx.run.state == null or ctx.run.state.party.is_empty():
		return
	if ctx.run.state.member(_member).is_empty():
		_member = ctx.run.state.party[0]["slot"]
	%Tabs.set_items(TABS.map(func(tab: String) -> Dictionary:
		return {"text": tab_texts.get(tab, tab), "variation": &"CommandButton", "action": _set_tab.bind(tab),
			"hover": _preview_tab.bind(tab), "unhover": _preview_tab.bind("")}))
	%Rows.set_items(DemoPartyRows.items(ctx.run, func(member: Dictionary) -> Dictionary:
		var slot: int = member["slot"]
		return {"pickable": true, "selected": slot == _member, "on_pick": _set_member.bind(slot),
			"on_hover": _preview_member.bind(slot), "on_unhover": _preview_member.bind(0)}))
	_draw_details()


func _set_tab(tab: String) -> void:
	_tab = tab
	_tab_preview = ""
	_draw_details()


func _preview_tab(tab: String) -> void:
	_tab_preview = tab
	_draw_details()


func _set_member(slot: int) -> void:
	_member = slot
	_member_preview = 0
	refresh()


func _preview_member(slot: int) -> void:
	_member_preview = slot
	_draw_details()


func _draw_details() -> void:
	var slot := _member_preview if _member_preview > 0 else _member
	var tab := _tab_preview if _tab_preview != "" else _tab
	var member := ctx.run.state.member(slot)
	if member.is_empty():
		return
	var character: UnitDefinition = ctx.run.content.units.get(member["character"])
	var shown := character.display_name if character != null else String(member["character"])
	%MemberName.text = shown
	%TabTitle.text = level_format % [str(tab_texts.get(tab, tab)).to_upper(), int(member["level"])]
	for child in %Body.get_children():
		child.queue_free()
	match tab:
		"info":
			_draw_info(slot, character)
		"held":
			_draw_held(member)
		"stats":
			_draw_stats(slot)
	describe({"name": shown, "kind": "LV %d" % int(member["level"]), "text": _description(character)})


func _draw_info(slot: int, character: UnitDefinition) -> void:
	var text := Label.new()
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.text = _description(character)
	%Body.add_child(text)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	for entry in ctx.run.member_kit(slot):
		if entry["name"] in kit_hidden:
			continue
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var label := Label.new()
		label.text = entry["name"]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var description := str(entry["hint"].get("description", ""))
		var unlock := int(entry.get("unlock_level", 0))
		if unlock > 0:
			description = (description + " " if description != "" else "") + unlock_format % unlock
			row.modulate.a = locked_alpha
		label.tooltip_text = description
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		var kind := Label.new()
		kind.text = entry["kind"]
		kind.theme_type_variation = &"Caption"
		row.add_child(label)
		row.add_child(kind)
		grid.add_child(row)
	%Body.add_child(grid)


func _draw_held(member: Dictionary) -> void:
	var run := ctx.run
	if member["items"].is_empty():
		var none := Label.new()
		none.text = no_items_text
		none.theme_type_variation = &"Muted"
		%Body.add_child(none)
		return
	var list := GridContainer.new()
	list.columns = 2
	list.add_theme_constant_override("h_separation", 14)
	var entry_scene: PackedScene = load("res://presentation/demo/ui/list_entry.tscn")
	for item_id in member["items"]:
		var item: ItemDefinition = run.content.items.get(item_id)
		var entry := entry_scene.instantiate()
		list.add_child(entry)
		entry.set_item({"text": item.display_name if item != null else String(item_id),
			"hover": func(): describe({"name": item.display_name if item != null else String(item_id),
				"kind": _rarity(item), "text": item.description if item != null else ""})}, ctx)
	%Body.add_child(list)


func _draw_stats(slot: int) -> void:
	var stats := ctx.run.member_stats(slot)
	if stats.is_empty():
		return
	var bars := DemoPartyRows.items(ctx.run).filter(func(row) -> bool: return row["name"] == %MemberName.text)
	if not bars.is_empty():
		var top := Label.new()
		var row: Dictionary = bars[0]
		top.text = "HP %d / %d    SP %d / %d    XP %d    ULT %d%%" % [row["hp"], row["hp_max"], row["mp"], row["mp_max"],
			stats["xp"], row["ult"]]
		%Body.add_child(top)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 28)
	for key in stat_labels:
		if not stats["current"].has(key):
			continue
		var current: int = stats["current"][key]
		var base: int = stats["base"].get(key, current)
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var label := Label.new()
		label.text = stat_labels[key]
		label.theme_type_variation = &"Muted"
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var value := Label.new()
		value.text = _value(key, current)
		var delta := Label.new()
		if current != base:
			delta.text = (" +" if current > base else " ") + _value(key, current - base)
			delta.theme_type_variation = &"FeedHeal" if current > base else &"FeedDown"
		row.add_child(label)
		row.add_child(value)
		row.add_child(delta)
		grid.add_child(row)
	%Body.add_child(grid)


func _value(key: String, value_x100: int) -> String:
	var shown := Fixed.to_display(value_x100)
	var text := str(int(shown)) if shown == int(shown) else str(shown)
	return text + ("%" if key in percent_stats else "")


static func _description(character: UnitDefinition) -> String:
	var description: Variant = character.get("description") if character != null else null
	return str(description) if description != null else ""


static func _rarity(item: ItemDefinition) -> String:
	if item == null:
		return ""
	for tag in item.tags:
		if String(tag).begins_with("Item.Rarity."):
			return String(tag).trim_prefix("Item.Rarity.").to_upper()
	return "PASSIVE ITEM"
