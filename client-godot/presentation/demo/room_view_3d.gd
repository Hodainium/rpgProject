## Demo 3D room (placeholder): a 13 x 7 box with door gaps, units as cubes on their spawn cells, pedestals and shop
## slots as small cubes. In battle it plays each ability's animation on the acting unit's cube through the ViewGate.
extends Node3D

const COLUMNS: int = 13
const ROWS: int = 7
## The floor slab: the room's cells and the wall ring around them.
const FLOOR_SIZE: Vector3 = Vector3(COLUMNS + 2, 0.2, ROWS + 2)
## One wall block (placed 0.2 below the cells' height, so it stands on the floor's top at -0.5).
const WALL_SIZE: Vector3 = Vector3(1, 0.6, 1)

var _main: GameMain
var _room_root: Node3D
## Playtest fix 2026-11-13 (nothing rebuilt that is already there): the walls and floor, rebuilt only when the room changes
## (_box_key); the props (pedestals, shop slots, the event marker), rebuilt with each build; the units, whose party cubes are
## made once and kept across rooms and battles.
var _box_root: Node3D
var _props_root: Node3D
var _units_root: Node3D
var _box_key: String = ""
var _views: Dictionary = {}  # unit id ("P1", "E2") -> unit view
var _battle: Battle
var _gate: ViewGate
## A rebuild is waiting for the end of this frame (_queue_build); the party celebrates after it.
var _build_queued: bool = false
var _celebrate: bool = false
## Spec cube-style: the chapter's mood (environment and lights; with no style registry, today's one light) and the camera.
var _rig: StageRig
var _camera: Camera3D

## Spec cube-style 3.9: how long the camera takes to move between the exploration and the battle framing.
const CAMERA_SECONDS: float = 0.45


func setup(main: GameMain) -> void:
	_main = main
	add_to_group(&"style_listeners")  # spec cube-style 3.8: the console's `style` restyles the room
	_camera = Camera3D.new()
	add_child(_camera)
	UnitStyle.explore_framing().apply_to(_camera)  # today's (0, 9, 8), -50° unless the registry says otherwise
	_rig = StageRig.new()
	_rig.active = false  # hidden until a mode other than the menu (see visible below and _on_mode)
	add_child(_rig)
	_room_root = Node3D.new()
	add_child(_room_root)
	for part in ["Box", "Props", "Units"]:
		var node := Node3D.new()
		node.name = part
		_room_root.add_child(node)
	_box_root = _room_root.get_node(^"Box")
	_props_root = _room_root.get_node(^"Props")
	_units_root = _room_root.get_node(^"Units")
	main.run_changed.connect(_bind)
	main.battle_prepared.connect(_on_battle_prepared)
	main.mode_changed.connect(_on_mode)
	visible = false


func _on_mode(mode: String) -> void:
	visible = mode != "menu"
	_rig.active = visible  # the mood's environment never tints a menu


func _on_battle_prepared(_recorder: ActionRecorder, gate: ViewGate) -> void:
	_gate = gate
	_gate.ability_began.connect(_on_ability_began)


func _bind(run: RunController) -> void:
	UnitStyle.explore_framing().apply_to(_camera)  # spec cube-style 3.9: a new run never starts in a battle framing
	run.floor_entered.connect(func(_floor): _queue_build())
	run.room_entered.connect(func(_cell): _queue_build())
	run.room_cleared.connect(func(_cell): _queue_build())
	run.party_changed.connect(_on_party_changed)
	run.battle_started.connect(_on_battle_started)
	run.battle_finished.connect(_on_battle_finished)


func _on_party_changed() -> void:
	if _battle == null:
		_queue_build()


func _on_battle_finished(outcome: String) -> void:
	_battle = null
	UnitStyle.explore_framing().tween_to(_camera, CAMERA_SECONDS)  # spec cube-style 3.9
	_celebrate = outcome == Battle.VICTORY
	_queue_build()


## Rebuilds the room once, at the end of this frame: a won battle fires battle_finished, party_changed (rewards, XP, drops)
## and room_cleared in one frame, which rebuilt the whole room five times (playtest fix 2026-11-13, the battle-end hitch).
## The one rebuild reads the final state; nothing is drawn in between.
func _queue_build() -> void:
	if _build_queued:
		return
	_build_queued = true
	_build_now.call_deferred()


func _build_now() -> void:
	_build_queued = false
	if _battle != null:  # a battle started in the same frame: its own views are up, the room waits
		_celebrate = false
		return
	_build()
	if _celebrate:  # spec animation-sets: the living party celebrates
		_celebrate = false
		for id in _views:
			if String(id).begins_with("P") and _views[id].has_method("celebrate"):
				_views[id].celebrate()


## Shows the current room from run state (out of battle): the walls only when the room changed, the props again, the party
## cubes kept (made only for a member who has none), the enemy cubes of a finished battle freed.
func _build() -> void:
	var run := _main.run
	if run == null or run.state == null or run.state.map == null:
		for child in _props_root.get_children() + _box_root.get_children():
			child.queue_free()
		_free_views(func(_id: StringName) -> bool: return true)
		_box_key = ""
		return
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	var room: RoomDefinition = run.content.rooms.get(data["room"])
	var key := "%d|%d|%d|%s" % [run.state.floor_index, run.state.current_cell, data["doors"], run.state.chapter_id]
	if key != _box_key:
		_box_key = key
		for child in _box_root.get_children():
			child.queue_free()
		_rig.apply(UnitStyle.mood_for(run.state.chapter_id))  # spec cube-style 3.6: the chapter's mood
		_build_box(data["doors"])
	_free_views(func(id: StringName) -> bool: return not String(id).begins_with("P"))  # the battle's enemies (faded out)
	_sync_party(room)
	for child in _props_root.get_children():
		child.queue_free()
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
						var piece: EquipmentDefinition = run.content.equipment.get(pickup["item"])  # armor (item-pass)
						var price := " (%d)" % pickup["price"] if pickup["price"] > 0 else ""
						var title := item.display_name if item != null else (piece.display_name if piece != null else "?")
						_prop(placement.cell, Color.GOLD if piece == null else Color.SILVER, title + price, item)


## Spec cube-style 3.10: the party stands in its formation out of battle too (slot order), else on the room's spawn cells. Each
## member keeps its cube ("P<slot>", the id it has in battle); a cube is made only for a slot with none or another character,
## and the pose changes only when the member's state does (so a celebration or a fall is never restarted).
func _sync_party(room: RoomDefinition) -> void:
	var run := _main.run
	var members: Array = run.state.party.duplicate()
	members.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["slot"]) < int(b["slot"]))
	var spots := UnitStyle.battle_positions(true, members.size())
	var kept: Array[StringName] = []
	for order in members.size():
		var member: Dictionary = members[order]
		var id := StringName("P%d" % member["slot"])
		var character: UnitDefinition = run.content.units.get(member["character"])
		var placed := order < spots.size()  # the formation spot first, the room's spawn cell only without one
		var at := Vector2i.ZERO if placed else _spawn(room, RoomPlacement.Kind.PLAYER_SPAWN, member["slot"],
			Vector2i(2, member["slot"] + 1))
		var view := _kept_view(id, character)
		if view == null:
			view = _unit(at, character, id)
			view.set_dead(not member["alive"])
		elif _is_dead(view) != (not member["alive"]):
			view.set_dead(not member["alive"])
		view.position = spots[order] if placed else _world(at)
		view.set_stats("%s\nHP %d" % [_name(character), member["hp"] / 100])
		_views[id] = view
		kept.append(id)
	_free_views(func(id: StringName) -> bool: return String(id).begins_with("P") and not kept.has(id))


## The live view kept under `id` when it still shows `definition`, else null (a stale one is freed).
func _kept_view(id: StringName, definition: UnitDefinition) -> Node3D:
	var view: Node3D = _views.get(id)
	if view == null or not is_instance_valid(view) or view.is_queued_for_deletion():
		_views.erase(id)
		return null
	var shows: StringName = view.get_meta(&"definition_id", &"")
	if definition == null or shows != definition.id:
		view.queue_free()
		_views.erase(id)
		return null
	return view


func _is_dead(view: Node3D) -> bool:
	return view is UnitAnimator and view.is_dead


## Frees the views whose id `pick` accepts.
func _free_views(pick: Callable) -> void:
	for id in _views.keys():
		if pick.call(id):
			if is_instance_valid(_views[id]):
				_views[id].queue_free()
			_views.erase(id)


func _on_battle_started(battle: Battle) -> void:
	_battle = battle
	UnitStyle.battle_framing().tween_to(_camera, CAMERA_SECONDS)  # spec cube-style 3.9
	var ids: Array[StringName] = []
	for unit in battle.units():
		ids.append(unit.unit_id)
	# The party's cubes stay as they are; anything else (a stale enemy) goes, and the enemies are made new.
	_free_views(func(id: StringName) -> bool: return not ids.has(id) or not String(id).begins_with("P"))
	var run := _main.run
	var room: RoomDefinition = run.content.rooms.get(run.state.map.cells[run.state.current_cell]["room"])
	var spots := _formation_spots(battle)  # spec cube-style 3.10: the style's battle formation, else the room's spawn cells
	for unit in battle.units():
		var kind := RoomPlacement.Kind.PLAYER_SPAWN if unit.is_party() else RoomPlacement.Kind.ENEMY_SPAWN
		var fallback := Vector2i(2 if unit.is_party() else 10, unit.slot + 1)
		var placed: bool = spots.has(unit.unit_id)  # the formation spot first, the room's spawn cell only without one
		var at := Vector2i.ZERO if placed else _spawn(room, kind, unit.slot, fallback)
		var view := _kept_view(unit.unit_id, unit.definition)
		if view == null:
			view = _unit(at, unit.definition, unit.unit_id)
			view.set_dead(not unit.alive)
		elif _is_dead(view) != (not unit.alive):
			view.set_dead(not unit.alive)
		view.position = spots[unit.unit_id] if placed else _world(at)
		_views[unit.unit_id] = view
	FxManager.prepare_stencil(get_viewport().get_camera_3d())  # spec vfx-stencil: compile this battle's effect shader copies now
	battle.execution_resolved.connect(_on_execution)
	battle.unit_died.connect(_set_dead.bind(true))
	battle.unit_revived.connect(_set_dead.bind(false))
	battle.damage_dealt.connect(_on_damage_dealt)
	battle.turn_started.connect(func(_id, _turn): _refresh_stats())
	_refresh_stats()


## Spec cube-style 3.10: unit id -> its position in the style's battle formation, each side in slot order; empty with no formation.
func _formation_spots(battle: Battle) -> Dictionary:
	var spots := {}
	for party in [true, false]:
		var side: Array = battle.units().filter(func(unit: BattleUnit) -> bool: return unit.is_party() == party)
		side.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)
		var placed := UnitStyle.battle_positions(party, side.size())
		for i in placed.size():
			spots[side[i].unit_id] = placed[i]
	return spots


## Spec animation-sets: `death` (after any cast the unit is still playing) or `revive`.
func _set_dead(unit_id: StringName, dead: bool) -> void:
	if _views.has(unit_id):
		if _views[unit_id].has_method("die") and dead:
			_views[unit_id].die()
		elif _views[unit_id].has_method("revive") and not dead:
			_views[unit_id].revive()
		else:
			_views[unit_id].set_dead(dead)


## The additive flinch on whoever was hit (a blocked hit uses the set's `block`).
func _on_damage_dealt(_source_id: StringName, target_id: StringName, _amount: int, hit_tags: Array[StringName]) -> void:
	if _views.has(target_id) and _views[target_id].has_method("flinch"):
		_views[target_id].flinch(hit_tags.has(&"Hit.Blocked"))


func _on_ability_began(unit_id: StringName, ability: BattleAbility) -> void:
	if _views.has(unit_id) and is_instance_valid(_views[unit_id]):
		_views[unit_id].play(ability, _gate)
	else:
		_gate.release_finished()


func _on_execution(_unit_id: StringName, _row_id: StringName, _target_ids: Array[StringName]) -> void:
	_refresh_stats()


## Spec cube-style 3.8: the console changed the style (a registry, a mood override): the room, the camera and the units again.
func restyle() -> void:
	if _main == null or _main.run == null or _main.run.state == null:
		return
	if _battle == null:
		UnitStyle.explore_framing().apply_to(_camera)
		_box_key = ""  # the walls and floor take the new mood
		_build()
		for view in _views.values():
			if is_instance_valid(view) and view is UnitAnimator:
				view.restyle()
		return
	UnitStyle.battle_framing().apply_to(_camera)
	_rig.apply(UnitStyle.mood_for(_main.run.state.chapter_id))
	for child in _box_root.get_children():  # the floor and walls _build_box marked take the new mood's materials
		match child.get_meta(&"style_part", &""):
			&"floor":
				child.mesh = _rig.floor_mesh(FLOOR_SIZE)
				child.material_override = _rig.floor_material()
			&"wall":
				child.mesh = _rig.wall_mesh(WALL_SIZE)
				child.material_override = _rig.wall_material()
	var spots := _formation_spots(_battle)  # a variant may bring another formation
	for id in _views:
		var view = _views[id]
		if not is_instance_valid(view):
			continue
		if spots.has(id):
			view.position = spots[id]
		if view is UnitAnimator:
			view.restyle()


func _refresh_stats() -> void:
	if _battle == null:
		return
	for unit in _battle.units():
		if _views.has(unit.unit_id):
			_views[unit.unit_id].set_stats("%s\nHP %d" % [_name(unit.definition), unit.stat(BattleUnit.HP) / 100])


func _build_box(doors: int) -> void:
	var floor_mesh := MeshInstance3D.new()
	# Under the wall ring too: the bevelled walls stand on the floor, so their chamfered bottom edges and the grooves between
	# blocks show floor, never the background; its corners are chamfered like the walls on them (spec cube-style 3.6).
	floor_mesh.mesh = _rig.floor_mesh(FLOOR_SIZE)
	floor_mesh.material_override = _rig.floor_material()  # spec cube-style: the mood's floor (null = today's)
	floor_mesh.set_meta(&"style_part", &"floor")  # restyle() finds it in battle
	floor_mesh.position = Vector3(0, -0.6, 0)
	_box_root.add_child(floor_mesh)
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
	wall.mesh = _rig.wall_mesh(WALL_SIZE)  # spec cube-style 3.6: bevelled by the mood
	wall.material_override = _rig.wall_material()  # spec cube-style: the mood's walls (null = today's)
	wall.set_meta(&"style_part", &"wall")
	wall.position = _world(cell) + Vector3(0, -0.2, 0)
	_box_root.add_child(wall)


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
	_props_root.add_child(prop)
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = _world(cell) + Vector3(0, 0.6, 0)
	_props_root.add_child(label)


## A new view for `definition` as unit `id` ("P1", "E2"). The id is set before the view is ready, so its attachments are built
## facing the right way once (a later id rebuilds them), and it takes its battle position's stencil value at once.
func _unit(cell: Vector2i, definition: UnitDefinition, id: StringName) -> Node3D:
	var view: Node3D = UnitAnimator.instantiate_for(definition, _main.unit_view)  # its own view, or the cube
	view.set_meta(&"definition_id", definition.id if definition != null else &"")  # _kept_view: any kind of view
	if view is UnitAnimator:
		view.unit_id = id  # spec vfx-framework: effects find a unit's view by this id
	_units_root.add_child(view)
	if view is UnitAnimator:
		view.assign_stencil()  # spec vfx-stencil 3.1: the stencil value of its battle position (0 with stencil off)
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
