## UIList entry of the party panel: one member. Item: {"run", "member", "values" (×100 stats), "alive", "leveled"}.
extends VBoxContainer

@export var level_format: String = "  Lv %d"
@export var xp_format: String = " · XP %d/%d"
@export var xp_max_format: String = " · XP %d (max)"
@export var level_up_text: String = "  LEVEL UP!"
@export var dead_text: String = "  [DEAD]"


func set_item(item: Dictionary, _ctx: UIContext) -> void:
	var run: RunController = item["run"]
	var member: Dictionary = item["member"]
	var values: Dictionary = item["values"]
	var character: UnitDefinition = run.content.units.get(member["character"])
	var level := int(member["level"])
	var title := "%d. %s%s" % [member["slot"], character.display_name if character != null else String(member["character"]),
		level_format % level]
	var curve: Array[int] = run.structure.xp_to_level if run.structure != null else []
	if not curve.is_empty():
		title += xp_format % [member.get("xp", 0), curve[level - 1]] if level - 1 < curve.size() \
			else xp_max_format % member.get("xp", 0)
	if item["leveled"]:
		title += level_up_text
	if not item["alive"]:
		title += dead_text
	%Title.text = title
	%Bars.text = "%s%s%s" % [_pair("HP", values, BattleUnit.HP, BattleUnit.MAX_HP),
		_pair("  MP", values, BattleUnit.MP, BattleUnit.MAX_MP),
		_pair("  Ult", values, BattleUnit.ENERGY, BattleUnit.MAX_ENERGY)]
	var held := PackedStringArray()
	var tips := PackedStringArray()
	for item_id in member["items"]:
		held.append(_item_name(run, item_id))
		tips.append(_item_tip(run, item_id))
	for use_slot in member["use_slots"]:
		held.append("[%s%s]" % [_item_name(run, use_slot["item"]),
			" cd %d" % use_slot["cooldown"] if use_slot["cooldown"] > 0 else ""])
		tips.append(_item_tip(run, use_slot["item"]))
	%Items.text = ", ".join(held)
	var gear := PackedStringArray()
	for slot_tag in run.equipment_slots():
		var piece: EquipmentDefinition = run.content.equipment.get(member["equipment"].get(slot_tag, &""))
		gear.append("%s: %s" % [String(slot_tag).get_slice(".", 2), piece.display_name if piece != null else "-"])
		if piece != null and piece.description != "":
			tips.append("%s: %s" % [piece.display_name, piece.description])
	%Gear.text = ", ".join(gear)
	for label in [%Bars, %Items, %Gear]:
		label.visible = label.text != ""
	tooltip_text = "\n".join(Array(tips).filter(func(tip) -> bool: return tip != ""))


## "HP 669/1000" (values are ×100); just the current value when the set has no maximum; "" when absent.
static func _pair(title: String, values: Dictionary, current: String, maximum: String) -> String:
	if not values.has(current):
		return ""
	if not values.has(maximum):
		return "%s %d" % [title, values[current] / 100]
	return "%s %d/%d" % [title, values[current] / 100, values[maximum] / 100]


static func _item_name(run: RunController, item_id: StringName) -> String:
	var item: ItemDefinition = run.content.items.get(item_id)
	return item.display_name if item != null else String(item_id)


static func _item_tip(run: RunController, item_id: StringName) -> String:
	var item: ItemDefinition = run.content.items.get(item_id)
	return "%s: %s" % [item.display_name, item.description] if item != null and item.description != "" else ""
