## Demo 3D room (placeholder): a 13 x 7 box with door gaps, units as cubes on their spawn cells, pedestals and shop
## slots as small cubes. In battle it plays each ability's animation on the acting unit's cube through the ViewGate.
extends Node3D

const COLUMNS: int = 13
const ROWS: int = 7

var _main: GameMain
var _room_root: Node3D
var _views: Dictionary = {}  # unit id ("P1", "E2") -> unit view
var _battle: Battle
var _gate: ViewGate


func setup(main: GameMain) -> void:
	_main = main
	var camera := Camera3D.new()
	camera.position = Vector3(0, 9, 8)
	camera.rotation_degrees = Vector3(-50, 0, 0)
	add_child(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, 30, 0)
	add_child(light)
	_room_root = Node3D.new()
	add_child(_room_root)
	main.run_changed.connect(_bind)
	main.battle_prepared.connect(_on_battle_prepared)
	main.mode_changed.connect(_on_mode)
	visible = false


func _on_mode(mode: String) -> void:
	visible = mode != "menu"


func _on_battle_prepared(_recorder: ActionRecorder, gate: ViewGate) -> void:
	_gate = gate
	_gate.ability_began.connect(_on_ability_began)


func _bind(run: RunController) -> void:
	run.floor_entered.connect(func(_floor): _build())
	run.room_entered.connect(func(_cell): _build())
	run.room_cleared.connect(func(_cell): _build())
	run.party_changed.connect(_on_party_changed)
	run.battle_started.connect(_on_battle_started)
	run.battle_finished.connect(_on_battle_finished)


func _on_party_changed() -> void:
	if _battle == null:
		_build()


func _on_battle_finished(_outcome: String) -> void:
	_battle = null
	_build()


## Rebuilds the current room from run state (out of battle).
func _build() -> void:
	for child in _room_root.get_children():
		child.queue_free()
	_views.clear()
	var run := _main.run
	if run == null or run.state == null or run.state.map == null:
		return
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	var room: RoomDefinition = run.content.rooms.get(data["room"])
	_build_box(data["doors"])
	for member in run.state.party:
		var character: UnitDefinition = run.content.units.get(member["character"])
		var view := _unit(_spawn(room, RoomPlacement.Kind.PLAYER_SPAWN, member["slot"], Vector2i(2, member["slot"] + 1)),
			character)
		view.set_stats("%s\nHP %d" % [_name(character), member["hp"] / 100])
		view.set_dead(not member["alive"])
		# Same id as in battle, so a starting battle replaces this cube instead of drawing a second one on top.
		_views[StringName("P%d" % member["slot"])] = view
	if room == null:
		return
	for number in room.placements.size():
		var placement: RoomPlacement = room.placements[number]
		if placement == null:
			continue
		match placement.kind:
			RoomPlacement.Kind.EVENT_PROP:
				if not data["cleared"]:
					_prop(placement.cell, Color.CYAN, "?")
			RoomPlacement.Kind.ITEM_PEDESTAL, RoomPlacement.Kind.SHOP_SLOT:
				for pickup in data["pickups"]:
					if pickup["placement"] == number + 1 and not pickup["taken"]:
						var item: ItemDefinition = run.content.items.get(pickup["item"])
						var price := " (%d)" % pickup["price"] if pickup["price"] > 0 else ""
						_prop(placement.cell, Color.GOLD, (item.display_name if item != null else "?") + price, item)


func _on_battle_started(battle: Battle) -> void:
	_battle = battle
	for view in _views.values():
		view.queue_free()
	_views.clear()
	var run := _main.run
	var room: RoomDefinition = run.content.rooms.get(run.state.map.cells[run.state.current_cell]["room"])
	for unit in battle.units():
		var kind := RoomPlacement.Kind.PLAYER_SPAWN if unit.is_party() else RoomPlacement.Kind.ENEMY_SPAWN
		var fallback := Vector2i(2 if unit.is_party() else 10, unit.slot + 1)
		var view := _unit(_spawn(room, kind, unit.slot, fallback), unit.definition)
		_views[unit.unit_id] = view
		view.set_dead(not unit.alive)
	battle.execution_resolved.connect(_on_execution)
	battle.unit_died.connect(_set_dead.bind(true))
	battle.unit_revived.connect(_set_dead.bind(false))
	battle.turn_started.connect(func(_id, _turn): _refresh_stats())
	_refresh_stats()


func _set_dead(unit_id: StringName, dead: bool) -> void:
	if _views.has(unit_id):
		_views[unit_id].set_dead(dead)


func _on_ability_began(unit_id: StringName, ability: BattleAbility) -> void:
	if _views.has(unit_id) and is_instance_valid(_views[unit_id]):
		_views[unit_id].play(ability, _gate)
	else:
		_gate.release_finished()


func _on_execution(_unit_id: StringName, _row_id: StringName, target_ids: Array[StringName]) -> void:
	for id in target_ids:
		if _views.has(id):
			_views[id].flash()
	_refresh_stats()


func _refresh_stats() -> void:
	if _battle == null:
		return
	for unit in _battle.units():
		if _views.has(unit.unit_id):
			_views[unit.unit_id].set_stats("%s\nHP %d" % [_name(unit.definition), unit.stat(BattleUnit.HP) / 100])


func _build_box(doors: int) -> void:
	var floor_mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(COLUMNS, 0.2, ROWS)
	floor_mesh.mesh = box
	floor_mesh.position = Vector3(0, -0.6, 0)
	_room_root.add_child(floor_mesh)
	# Walls of unit blocks, with a gap in the middle of each side that has a door.
	for x in range(-1, COLUMNS + 1):
		for y in [-1, ROWS]:
			var door := RoomDefinition.DOOR_N if y == -1 else RoomDefinition.DOOR_S
			if not (x == COLUMNS / 2 and doors & door):
				_wall(Vector2i(x, y))
	for y in range(0, ROWS):
		for x in [-1, COLUMNS]:
			var door := RoomDefinition.DOOR_W if x == -1 else RoomDefinition.DOOR_E
			if not (y == ROWS / 2 and doors & door):
				_wall(Vector2i(x, y))


func _wall(cell: Vector2i) -> void:
	var wall := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1, 0.6, 1)
	wall.mesh = box
	wall.position = _world(cell) + Vector3(0, -0.2, 0)
	_room_root.add_child(wall)


func _prop(cell: Vector2i, color: Color, text: String, item: ItemDefinition = null) -> void:
	var prop := MeshInstance3D.new()
	if item != null and item.mesh != null:
		prop.mesh = item.mesh
	else:
		var box := BoxMesh.new()
		box.size = Vector3(0.4, 0.4, 0.4)
		prop.mesh = box
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		prop.material_override = material
	prop.position = _world(cell)
	_room_root.add_child(prop)
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = _world(cell) + Vector3(0, 0.6, 0)
	_room_root.add_child(label)


func _unit(cell: Vector2i, definition: UnitDefinition) -> Node3D:
	var view: Node3D = _main.unit_view.instantiate()
	_room_root.add_child(view)
	view.position = _world(cell)
	view.setup(_name(definition), definition.display_color if definition != null else Color.WHITE)
	return view


## The cell of the placement of `kind` for `slot`, or the fallback.
func _spawn(room: RoomDefinition, kind: RoomPlacement.Kind, slot: int, fallback: Vector2i) -> Vector2i:
	if room != null:
		for placement in room.placements:
			if placement != null and placement.kind == kind and placement.slot == slot:
				return placement.cell
	return fallback


func _world(cell: Vector2i) -> Vector3:
	return Vector3(cell.x - (COLUMNS - 1) / 2.0, 0, cell.y - (ROWS - 1) / 2.0)


func _name(definition: UnitDefinition) -> String:
	if definition == null:
		return "?"
	return definition.display_name if definition.display_name != "" else String(definition.id)
