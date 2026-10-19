## Demo pickup / shop panel (placeholder): the room's pedestal and shop items, a "give to" picker, Take / Buy.
extends Control

var _main: GameMain

@onready var _rows: VBoxContainer = %Rows


func setup(main: GameMain) -> void:
	_main = main
	main.run_changed.connect(_bind)
	main.mode_changed.connect(func(_mode): _refresh())
	visible = false


func _bind(run: RunController) -> void:
	for changed in [run.pickups_shown, run.room_entered, run.room_cleared, run.party_changed, run.battle_requested]:
		changed.connect(func(_a = null): _refresh.call_deferred())


func _refresh() -> void:
	for child in _rows.get_children():
		child.queue_free()
	var run := _main.run
	visible = false
	if run == null or run.state == null or run.state.map == null or _main.mode != "run" or not run.pending_battle.is_empty():
		return
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	if not data["cleared"]:
		return
	for pickup in data["pickups"]:
		if pickup["taken"]:
			continue
		var item: ItemDefinition = run.content.items.get(pickup["item"])
		if item == null:
			continue
		visible = true
		var row := HBoxContainer.new()
		if item.icon != null:
			var icon := TextureRect.new()
			icon.texture = item.icon
			icon.custom_minimum_size = Vector2(24, 24)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			row.add_child(icon)
		var label := Label.new()
		label.text = "%s%s%s" % [item.display_name, " (use)" if item.is_usable() else "",
			"  %d coins" % pickup["price"] if pickup["price"] > 0 else ""]
		label.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(label)
		var picker := OptionButton.new()
		for member in run.state.party:
			var character: UnitDefinition = run.content.units.get(member["character"])
			picker.add_item(character.display_name if character != null else String(member["character"]), member["slot"])
			if run.can_hold(member["slot"], item) != "":
				picker.set_item_disabled(picker.item_count - 1, true)
		row.add_child(picker)
		var take := Button.new()
		take.text = "Buy" if pickup["price"] > 0 else "Take"
		take.pressed.connect(_take.bind(pickup["placement"], picker))
		row.add_child(take)
		_rows.add_child(row)


func _take(placement: int, picker: OptionButton) -> void:
	var problem := _main.run.take(placement, picker.get_item_id(picker.selected))
	if problem != "":
		_main.show_message(problem)
	_refresh()
