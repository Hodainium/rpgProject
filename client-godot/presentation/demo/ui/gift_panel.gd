## Spec event-items (Modal screen while UI.State.Run.Gift): "Give <item> to:" for an item from an event or a chest that
## waits for its holder. One button per party member (greyed, with the reason, when dead or unable to hold it); a press
## is RunController.give_to. The next waiting item follows; the rule removes the panel when none is left.
extends UIScreen

@export var kicker_text: String = "GIVE TO"
@export var count_format: String = "GIVE TO  ·  %d more after this"
@export var member_format: String = "%s  ·  Lv %d"


func bind(context: UIContext) -> void:
	context.on_run(self, &"party_changed", func(): refresh.call_deferred())


func on_activated() -> void:
	refresh()


func refresh() -> void:
	var run := ctx.run if ctx != null else null
	var item: ItemDefinition = run.pending_gift() if run != null else null
	if item == null:
		return
	var more := run.state.pending_gifts.size() - 1
	%Kicker.text = count_format % more if more > 0 else kicker_text
	%Name.text = item.display_name
	var rarity := _rarity(item)
	if rarity != &"":
		%Name.add_theme_color_override("font_color", get_theme_color("font_color", rarity))
	else:
		%Name.remove_theme_color_override("font_color")
	%Text.text = item.description
	%Text.visible = item.description != ""
	var members: Array = []
	for member in run.state.party:
		var character: UnitDefinition = run.content.units.get(member["character"])
		var name := character.display_name if character != null else String(member["character"])
		var problem := run.can_hold(member["slot"], item)
		members.append({"text": member_format % [name, member["level"]], "disabled": problem != "",
			"tooltip": problem, "action": _give.bind(member["slot"])})
	%Members.set_items(members)


func _give(slot: int) -> void:
	var problem := ctx.run.give_to(slot)
	if problem != "":
		ctx.main.refuse(problem)
	else:
		get_tree().call_group("sound_board", "play", "Item")


## The theme variation Rarity<X> for the item's rarity, or &"" (no rarity, or the theme has no colour for it).
func _rarity(item: ItemDefinition) -> StringName:
	for tag in item.tags:
		var variation := StringName("Rarity" + String(tag).trim_prefix("Item.Rarity."))
		if String(tag).begins_with("Item.Rarity.") and has_theme_color("font_color", variation):
			return variation
	return &""
