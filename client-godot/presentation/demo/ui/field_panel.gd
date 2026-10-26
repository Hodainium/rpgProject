## HUD panel (UI.Slot.Hud.Left while UI.State.Run.Map): what the party can do on the map: take off worn armor, put
## on armor from the bag (it is never worn on its own), field spells and usable items.
extends UIScreen

@export var take_off_format: String = "%d: take off %s"
@export var item_suffix: String = " [item]"

var _busy: bool = false


func bind(context: UIContext) -> void:
	for signal_name in [&"party_changed", &"room_entered", &"room_cleared", &"floor_entered"]:
		context.on_run(self, signal_name, func(_a = null): refresh.call_deferred())
	%Bag.entry_filled.connect(func(row, _item):
		if not row.equipped.is_connected(_after):
			row.equipped.connect(_after))


func refresh() -> void:
	var run := ctx.run
	if run == null or run.state == null or _busy:
		return
	var worn: Array = []
	for member in run.state.party:
		for slot_tag in run.equipment_slots():
			var piece: EquipmentDefinition = run.content.equipment.get(member["equipment"].get(slot_tag, &""))
			if piece != null:
				worn.append({"text": take_off_format % [member["slot"], piece.display_name],
					"action": func(): _after(run.unequip(member["slot"], slot_tag))})
	%Worn.set_items(worn)
	%BagLabel.visible = not run.state.armor.is_empty()
	%Bag.set_items(run.state.armor.map(func(piece_id) -> Dictionary: return {"run": run, "piece": piece_id}))
	var actions: Array = []
	for option in run.field_options():
		var tag := String(option["ability"])
		var title := "%d: %s%s" % [option["slot"], tag.get_slice(".", tag.get_slice_count(".") - 1),
			item_suffix if option["item"] != &"" else ""]
		if option["targets"].is_empty():
			actions.append({"text": title, "action": _use.bind(option["slot"], option["ability"], 0)})
		for target in option["targets"]:
			actions.append({"text": "%s -> %d" % [title, target], "action": _use.bind(option["slot"], option["ability"], target)})
	%Actions.set_items(actions)
	%ActionsLabel.visible = not actions.is_empty()


func _use(slot: int, ability: StringName, target: int) -> void:
	_busy = true
	var problem: Array = await ctx.run.use_field(slot, ability, target)
	_busy = false
	if not problem.is_empty():
		ctx.main.refuse("%s: %s" % problem)
	refresh()


## Wear / take off result: the message and the sound, then a fresh panel.
func _after(problem: String) -> void:
	if problem != "":
		ctx.main.refuse(problem)
	else:
		get_tree().call_group("sound_board", "play", "Item")
	refresh()
