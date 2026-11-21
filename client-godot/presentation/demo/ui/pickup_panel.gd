## HUD panel (UI.Slot.Hud.Right while UI.State.Run.Pickup): the room's closed chests (spec floor-chests), then its untaken
## pedestals, shop items and chest pickups, one pickup_row each.
extends UIScreen

@export var key_name: String = "Key"
@export var keys_format: String = "%d Keys"
@export var key_description: String = "Opens one locked room or Gilded Chest."


func bind(context: UIContext) -> void:
	for signal_name in [&"pickups_shown", &"room_entered", &"room_cleared", &"party_changed"]:
		context.on_run(self, signal_name, func(_a = null): queue_refresh())
	%Rows.entry_filled.connect(func(row, _item):
		if not row.has_meta(&"taken_wired"):
			row.set_meta(&"taken_wired", true)
			row.taken.connect(_after_take.bind(row)))
	UIFlash.listen(self, func(data: Dictionary) -> Array:  # spec ui-feedback rows 2, 6, 8, 9
		var hits: Array = []
		for row in UIFlash.entries(%Rows):
			if row.has_method("refused_controls"):
				hits.append_array(row.refused_controls(data))
		return hits)


func refresh() -> void:
	var run := ctx.run
	if run == null or run.state == null or run.state.map == null:
		return
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	var rows: Array = []
	# Spec floor-chests 2.6: each closed chest of the room first, as an OPEN row; what an open chest put out follows as
	# ordinary pickup rows (the chest's pickups carry "chest").
	var chests := run.room_chests()
	var chest_names := {}  # serial -> name, for the "from the X" of a chest's pickup row
	for chest in chests:
		chest_names[chest["serial"]] = chest["name"]
		if chest["opened"]:
			continue
		var shown := ItemDefinition.new()
		shown.display_name = chest["name"]
		shown.description = chest["description"] if chest["can_open"] else "%s\n%s" % [chest["description"], chest["why"]]
		rows.append({"run": run, "pickup": {"placement": -1, "price": 0}, "thing": shown, "equipment": false,
			"chest": chest})
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
			rows.append({"run": run, "pickup": pickup, "thing": thing, "equipment": equipment,
				"chest_name": chest_names.get(int(pickup.get("chest", -1)), "")})
	%Rows.set_items(rows)


func _after_take(problem: String, row: Node = null) -> void:
	if problem != "":
		ctx.main.refuse(problem, &"", row.refusal if row != null and "refusal" in row else {})
	refresh()
