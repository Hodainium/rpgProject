## HUD panel (UI.Slot.Hud.Right while UI.State.Run.Pickup): the room's untaken pedestals and shop items, one
## pickup_row each.
extends UIScreen

@export var key_name: String = "Key"
@export var keys_format: String = "%d Keys"
@export var key_description: String = "Opens one locked room or Gilded Chest."


func bind(context: UIContext) -> void:
	for signal_name in [&"pickups_shown", &"room_entered", &"room_cleared", &"party_changed"]:
		context.on_run(self, signal_name, func(_a = null): refresh.call_deferred())
	%Rows.entry_filled.connect(func(row, _item):
		if not row.taken.is_connected(_after_take):
			row.taken.connect(_after_take))


func refresh() -> void:
	var run := ctx.run
	if run == null or run.state == null or run.state.map == null:
		return
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	var rows: Array = []
	for pickup in data["pickups"]:
		if pickup["taken"]:
			continue
		if pickup.get("kind", "") == FloorGenerator.KEYS_KIND:
			# Spec keys-and-gear D12: keys for sale, shown as a plain item row with no "give to" picker.
			var key := ItemDefinition.new()
			key.display_name = key_name if int(pickup["keys"]) == 1 else keys_format % int(pickup["keys"])
			key.description = key_description
			rows.append({"run": run, "pickup": pickup, "thing": key, "equipment": false, "keys": true})
			continue
		var equipment: bool = pickup.get("kind", "") == FloorGenerator.EQUIPMENT_KIND
		var thing: Resource = (run.content.equipment if equipment else run.content.items).get(pickup["item"])
		if thing != null:
			rows.append({"run": run, "pickup": pickup, "thing": thing, "equipment": equipment})
	%Rows.set_items(rows)


func _after_take(problem: String) -> void:
	if problem != "":
		ctx.main.refuse(problem)
	refresh()
