## Demo 3D room (placeholder): a 13 x 7 box with door gaps, units as cubes on their spawn cells, pedestals and shop
## slots as small cubes. In battle it plays each ability's animation on the acting unit's cube through the ViewGate.
extends Node3D

const COLUMNS: int = 13
const ROWS: int = 7
## The floor slab: the room's cells and the wall ring around them.
const FLOOR_SIZE: Vector3 = Vector3(COLUMNS + 2, 0.2, ROWS + 2)
## One wall block (placed 0.2 below the cells' height, so it stands on the floor's top at -0.5).
const WALL_SIZE: Vector3 = Vector3(1, 0.6, 1)
## The floor's top in cell space (spec cube-style Set K: a PropView's origin stands on it).
const FLOOR_TOP: Vector3 = Vector3(0, -0.5, 0)

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
## Spec floor-chests D4: the lid swinging up, and each pickup's jump out of the chest (staggered, on an arc this high).
const LID_SECONDS: float = 0.4
const POP_SECONDS: float = 0.5
const POP_STAGGER: float = 0.15
const POP_HEIGHT: float = 0.8
## The serial of the chest that just opened (its next build pops its pickups out), else -1, and the frame it opened on.
var _popping: int = -1
var _popping_frame: int = 0
## A pop-out is played only by a build this many frames after the open, at most (a fresh open, never a stale one).
const POP_FRAMES: int = 3


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
	GameplayMessages.listen(GameplayMessageRouter.RUN_CHEST_OPENED, _on_chest_opened)  # spec floor-chests D4: the pop-out
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
	if _between_waves(outcome):
		return  # spec floor-rooms: the next wave starts at once; the room stays in battle (camera, no props, no rebuild)
	_props_root.visible = true  # hidden for the fight (spec cube-style Set K); the rebuild below refills them
	UnitStyle.explore_framing().tween_to(_camera, CAMERA_SECONDS)  # spec cube-style 3.9
	_celebrate = outcome == Battle.VICTORY
	_queue_build()


## Spec floor-rooms: a won wave of a challenge room that is not its last (battle_finished comes just before the run starts the
## next wave, so the cell still holds the wave that was fought).
func _between_waves(outcome: String) -> bool:
	var run := _main.run
	if outcome != Battle.VICTORY or run == null or run.state == null or run.state.map == null:
		return false
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	var room_content: Dictionary = data["content"]
	return str(room_content.get("kind", "")) == "waves" and not data["cleared"] \
		and int(data.get("wave", 0)) + 1 < room_content["waves"].size()


## Rebuilds the room once, at the end of this frame: a won battle fires battle_finished, party_changed (rewards, XP, drops)
## and room_cleared in one frame, which rebuilt the whole room five times (playtest fix 2026-11-13, the battle-end hitch).
## The one rebuild reads the final state; nothing is drawn in between.
func _queue_build() -> void:
	if _build_queued:
		return
	_build_queued = true
	_build_now.call_deferred()


func _build_now() -> void:
	if not _build_queued:  # done early (`style props` builds a waiting rebuild first, so it cannot clear the showcase)
		return
	_build_queued = false
	if _battle != null:  # a battle started in the same frame: its own views are up, the room waits
		_celebrate = false
		return
	_build()
	# Spec floor-rooms: between a challenge room's waves the next one is already waiting; the party celebrates only after the last.
	if _celebrate and _main.run != null and not _main.run.pending_battle.is_empty():
		_celebrate = false
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
	_sync_box(run)
	_free_views(func(id: StringName) -> bool: return not String(id).begins_with("P"))  # the battle's enemies (faded out)
	_sync_party(room)
	_units_root.visible = true  # `style props` hid it
	_props_root.visible = true
	for child in _props_root.get_children():
		child.queue_free()
	if room == null:
		_build_chests(run, data, null)  # spec floor-chests: a room with no definition still shows its chests
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
				# Spec floor-rooms: a battle room's reward shows once it is cleared (a challenge room is drawn between its waves).
				if not data["cleared"] and str(data["content"].get("kind", "")) in ["encounter", "waves"]:
					continue
				for pickup in data["pickups"]:
					if pickup["placement"] == number + 1 and not pickup["taken"]:
						var item: ItemDefinition = run.content.items.get(pickup["item"])
						var piece: EquipmentDefinition = run.content.equipment.get(pickup["item"])  # armor (item-pass)
						var price := " (%d)" % pickup["price"] if pickup["price"] > 0 else ""
						if _styled_prop(placement.cell, pickup, piece, price, run.content):
							continue  # spec cube-style Set K: a key or an armor piece drawn by the style registry
						var title := item.display_name if item != null else (piece.display_name if piece != null else "?")
						_prop(placement.cell, Color.GOLD if piece == null else Color.SILVER, title + price, item)
	_build_chests(run, data, room)


## Spec floor-chests 2.6: the room's chests on free floor tiles (not a placement, not a door lane, not under the party; nearest
## the room's centre first), closed or open and empty, and what an open chest put out on the free tiles around it. A chest that
## has just opened (Message.Run.ChestOpened) swings its lid up and its pickups jump out of it onto their tiles. View only.
func _build_chests(run: RunController, data: Dictionary, room: RoomDefinition) -> void:
	var chests: Array = data.get("chests", [])
	if chests.is_empty():
		_popping = -1
		return
	var taken := {}
	if room != null:
		for placement in room.placements:
			if placement != null:
				taken[placement.cell] = true
	for spot in UnitStyle.battle_positions(true, run.state.party.size()):  # the party's formation, out of battle too
		taken[_cell_of(spot)] = true
	for member in run.state.party:  # with no formation the party stands on its spawn cells, or these fallbacks
		taken[Vector2i(2, int(member["slot"]) + 1)] = true
	if Engine.get_process_frames() - _popping_frame > POP_FRAMES:
		_popping = -1  # stale: not a build right after the open
	var centre := Vector2i(COLUMNS / 2, ROWS / 2)
	var free: Array[Vector2i] = []
	for y in ROWS:
		for x in COLUMNS:
			var cell := Vector2i(x, y)
			if x != centre.x and y != centre.y and not taken.has(cell):  # the door lanes cross at the centre
				free.append(cell)
	var registry := UnitStyle.registry()
	for held in chests:
		var at := _nearest(free, centre)
		if at == Vector2i(-1, -1):
			break
		free.erase(at)
		var popping: bool = held["opened"] and int(held["serial"]) == _popping
		var look: ChestLook = registry.chest_look(held["chest"]) if registry != null else null
		if look != null:
			# Playtest-fixes B27: no text over a chest (the pickup panel's Open row names it).
			var view := PropView.chest(look, ChestLook.State.OPEN_EMPTY if held["opened"] else ChestLook.State.CLOSED, "")
			view.position = _world(at) + FLOOR_TOP
			_props_root.add_child(view)
			if popping and view.lid_pivot != null:  # the lid swings up from closed
				var open_x := view.lid_pivot.rotation_degrees.x
				view.lid_pivot.rotation_degrees.x = 0.0
				view.create_tween().tween_property(view.lid_pivot, ^"rotation_degrees:x", open_x, LID_SECONDS)
		else:
			_prop(at, Color.SADDLE_BROWN, "")
		var order := 0
		for pickup in run.chest_pickups(run.state.current_cell, int(held["serial"])):
			if pickup["taken"]:
				continue
			var tile := _nearest(free, at)
			if tile == Vector2i(-1, -1):
				break
			free.erase(tile)
			var before := _props_root.get_child_count()
			var item: ItemDefinition = run.content.items.get(pickup["item"])
			var piece: EquipmentDefinition = run.content.equipment.get(pickup["item"])
			if not _styled_prop(tile, pickup, piece, "", run.content):
				var name_text := item.display_name if item != null else (piece.display_name if piece != null else "?")
				_prop(tile, Color.GOLD if piece == null else Color.SILVER, name_text, item)
			if popping:
				for index in range(before, _props_root.get_child_count()):
					_pop_out(_props_root.get_child(index), _world(at) + FLOOR_TOP, order)
			order += 1
	_popping = -1


## Spec floor-chests D4: `node` jumps from inside the chest at `from` to where it stands now, on an arc, `order` places late.
func _pop_out(node: Node3D, from: Vector3, order: int) -> void:
	var to := node.position
	var start := Vector3(from.x, to.y + 0.3, from.z)  # inside the chest, a little above its floor
	node.position = start
	node.scale = Vector3.ONE * 0.2
	var tween := node.create_tween()
	tween.tween_interval(LID_SECONDS * 0.5 + order * POP_STAGGER)
	tween.tween_method(func(t: float) -> void:
		node.position = start.lerp(to, t) + Vector3(0, sin(t * PI) * POP_HEIGHT, 0)
		node.scale = Vector3.ONE * lerpf(0.2, 1.0, minf(t * 2.0, 1.0)), 0.0, 1.0, POP_SECONDS)


## The free tile nearest `to` (ties: the row nearer the camera, then the lower column, so nothing hides behind a chest), or
## (-1, -1) when none is left.
func _nearest(free: Array[Vector2i], to: Vector2i) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_distance := 1 << 30
	for cell in free:
		var distance := (cell - to).length_squared()
		if distance < best_distance or (distance == best_distance and cell.y > best.y):
			best = cell
			best_distance = distance
	return best


## The room cell nearest a world position (the inverse of _world).
func _cell_of(position: Vector3) -> Vector2i:
	return Vector2i(roundi(position.x + (COLUMNS - 1) / 2.0), roundi(position.z + (ROWS - 1) / 2.0))


## Only an open the player just made pops (the next build, within a few frames): a replayed open_chest (a resume tail, a conflict
## rebuild) or one whose build waits for a battle shows the chest already open.
func _on_chest_opened(_channel: StringName, message: VerbMessage) -> void:
	_popping = int(message.data.get("serial", -1))
	_popping_frame = Engine.get_process_frames()


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


## The walls, floor and mood of the room the party is in, rebuilt only when the room changed.
func _sync_box(run: RunController) -> void:
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	var key := "%d|%d|%d|%s" % [run.state.floor_index, run.state.current_cell, data["doors"], run.state.chapter_id]
	if key == _box_key:
		return
	_box_key = key
	for child in _box_root.get_children():
		child.queue_free()
	_rig.apply(UnitStyle.mood_for(run.state.chapter_id))  # spec cube-style 3.6: the chapter's mood
	_build_box(data["doors"])


func _on_battle_started(battle: Battle) -> void:
	_battle = battle
	# Playtest-fixes B20: a room entered by a click starts its battle in the same frame, before the queued rebuild runs (which
	# then waits for the battle), so the fight showed the previous room's walls and the doors moved when it ended.
	_sync_box(_main.run)
	_props_root.visible = false  # spec cube-style Set K: no pickup or event prop during a fight; the rebuild after it shows them
	_units_root.visible = true  # `style props` may have hidden the party just before the fight
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


## Spec cube-style 6a Set K: a shop key or an armor piece as the style registry draws it (an armor icon by its slot, in its rarity's
## colour); false when the registry has no look for it (today's cube then).
func _styled_prop(cell: Vector2i, pickup: Dictionary, piece: EquipmentDefinition, price: String, content: ContentIndex = null) -> bool:
	var registry := UnitStyle.registry()
	if registry == null:
		return false
	var view: PropView = null
	var item_look := registry.item_look()
	if pickup.get("kind", "") == FloorGenerator.KEYS_KIND:
		var look := registry.key_look()
		var keys := int(pickup.get("keys", 1))
		if look != null:
			var key_name := "Key" if keys == 1 else "%d Keys" % keys
			view = PropView.pickup(look, key_name + price) if item_look == null else \
				_beside_cards(look, ItemPropView.label_for(item_look, key_name, int(pickup.get("price", 0))), null, item_look)
	elif piece != null:
		var look := registry.armor_look(piece.slot)
		if look != null:
			var color: Variant = registry.rarity_color(piece.tags, null)  # no rarity: own colours
			view = PropView.pickup(look, piece.display_name + price, color) if item_look == null else \
				_beside_cards(look, ItemPropView.label_for(item_look, piece.display_name, int(pickup.get("price", 0))), color, item_look)
			_armor_aura(view, piece, item_look, registry)
	elif item_look != null and content != null and content.items.has(pickup.get("item", &"")):
		# Spec item-cards: an item as its card, its price on a shop shelf.
		view = ItemPropView.for_item(item_look, content, pickup["item"], registry, int(pickup.get("price", 0)))
	if view == null:
		return false
	view.position = _world(cell) + FLOOR_TOP
	_props_root.add_child(view)
	return true


## Spec cube-style 6a Set K (console `style props`): every prop look laid out in the current room until the next rebuild: the key,
## an armor icon per slot in each rarity, and each chest in its three states. Returns what it placed, one line each.
func show_prop_showcase(content: ContentIndex) -> PackedStringArray:  # empty in a battle or with no registry
	var lines := PackedStringArray()
	var registry := UnitStyle.registry()
	if registry == null or _battle != null:  # never on a battle's stage (no props during a fight)
		return lines
	if _build_queued:
		_build_now()  # a rebuild waiting for the end of the frame would clear the showcase
	_props_root.visible = true
	for child in _props_root.get_children():
		child.queue_free()
	var entries: Array = []  # [row, PropView, line]
	var key := registry.key_look()
	if key != null:
		entries.append([0, PropView.pickup(key, "Key (15)"), "key"])
	for chest_id in _chest_ids(content):
		var look := registry.chest_look(chest_id)
		var chest: ChestDefinition = content.chests.get(chest_id) if content != null else null
		for state in ChestLook.STATE_NAMES.size():
			if look != null:
				var title := chest.display_name if chest != null and chest.display_name != "" else String(chest_id)
				var text := title if state == ChestLook.State.CLOSED else ChestLook.STATE_NAMES[state]
				entries.append([0, PropView.chest(look, state, text),
					"chest %s %s" % [chest_id, ChestLook.STATE_NAMES[state]]])
	var rarities: Array[StringName] = [&"Item.Rarity.Common", &"Item.Rarity.Rare", &"Item.Rarity.Epic", &"Item.Rarity.Legendary"]
	for r in rarities.size():  # a row per rarity, a column per slot
		for slot in _slots(content):
			var look := registry.armor_look(slot)
			if look != null:
				var text := "%s %s" % [String(rarities[r]).get_slice(".", 2), String(slot).get_slice(".", 2)] if r == 0 else ""
				var armor_view := PropView.pickup(look, text, registry.rarity_color([rarities[r]], look.outline_color))
				_armor_aura(armor_view, null, registry.item_look(), registry, [rarities[r]])
				entries.append([r + 1, armor_view, "armor %s %s" % [slot, rarities[r]]])
	_units_root.visible = false  # the party would stand in the way; the next build shows it again
	var per_row: Dictionary = {}
	for entry in entries:
		per_row[entry[0]] = per_row.get(entry[0], 0) + 1
	var placed: Dictionary = {}
	for entry in entries:
		var index: int = placed.get(entry[0], 0)
		placed[entry[0]] = index + 1
		var view: PropView = entry[1]
		var spread := 1.6 if entry[0] == 0 else 1.5
		view.position = Vector3((index - (per_row[entry[0]] - 1) / 2.0) * spread, 0, -2.6 + entry[0] * 1.25) + FLOOR_TOP
		_props_root.add_child(view)
		lines.append(entry[2])
	return lines


## Spec item-cards: a key or an armor piece on the floor beside the cards, labelled at the cards' label height (a shop's labels
## line up) and the way the cards are. Its size is its own look's (user, 2026-11-21: keys x1.2, armor x1.3, in the registry).
func _beside_cards(look: PropLook, text: String, color: Variant, item_look: ItemCardLook) -> PropView:
	return PropView.pickup(look, text, color, item_look.label_height)


## Spec item-cards Q2: with an item look, an armor piece plays the items' tiered aura in its rarity's colour (the same map) instead
## of its own glow; its shape stays.
func _armor_aura(view: PropView, piece: EquipmentDefinition, item_look: ItemCardLook, registry: StyleRegistry, tags: Array = []) -> void:
	if view == null or item_look == null or item_look.aura == null:
		return
	var piece_tags: Array = piece.tags if piece != null else tags
	view._set_effect(item_look.aura, {&"tier": float(item_look.tier_of(piece_tags))}, registry.rarity_color(piece_tags, view.colour))


## Spec item-cards 2.1 (console `style items`): floor cards laid out in the current room until the next rebuild.
## `mode` "labels": a row per label mode (name and price, price only, none), each with three items lying free and two for sale;
## "sizes": a row per card height (the look's meta `showcase_sizes`), a column per tier (Common, Rare, Epic, Legendary,
## corrupted); "tiers": an item per tier; "shop": everything a shop sells; "pop": one open chest putting out one item at a time, its tier written above. Returns one line each.
func show_item_showcase(content: ContentIndex, mode: String, item_look: ItemCardLook) -> PackedStringArray:
	var lines := PackedStringArray()
	var registry := UnitStyle.registry()
	if registry == null or _battle != null or content == null or item_look == null:
		return lines
	if _build_queued:
		_build_now()
	_props_root.visible = true
	for child in _props_root.get_children():
		child.queue_free()
	_units_root.visible = false
	var picks := showcase_items(content)
	var tier_names := ["Common", "Rare", "Epic", "Legendary", "Corrupted"]
	var tier_ids: Array = [picks["common"], picks["rare"], picks["epic"], picks["legendary"], picks["void"]]
	var saved_label := ItemPropView.override_label
	match mode:
		"labels":
			# Free items: Common, Epic, corrupted; for sale: a Rare at 15 and a Legendary at 30 gold.
			var row_items: Array = [[picks["common"], 0], [picks["epic"], 0], [picks["void"], 0], [picks["shop"], 15],
				[picks["legendary"], 30]]
			for mode_index in ItemCardLook.LABEL_NAMES.size():
				ItemPropView.override_label = mode_index
				var z := -2.4 + mode_index * 2.0
				_showcase_text(ItemCardLook.LABEL_TITLES[mode_index], Vector3(-6.0, 0.6, z))
				for i in row_items.size():
					if row_items[i][0] == &"":
						continue
					var view := ItemPropView.for_item(item_look, content, row_items[i][0], registry, row_items[i][1])
					view.position = Vector3((i - 2) * 2.2, 0, z) + FLOOR_TOP
					_props_root.add_child(view)
					lines.append("%s %s price=%d" % [ItemCardLook.LABEL_NAMES[mode_index], row_items[i][0], row_items[i][1]])
		"shop":
			# Everything a shop can sell, priced: an item per tier and a food item (cards), then a key and an armor piece for each
			# slot, each labelled the way the look says (the same label for cards, keys and armor).
			var front: Array = []  # [view, line]
			var prices := [5, 15, 25, 40, 30]
			for r in tier_ids.size():
				if tier_ids[r] != &"":
					front.append([ItemPropView.for_item(item_look, content, tier_ids[r], registry, prices[r]),
						"%s %s %d" % [tier_names[r], tier_ids[r], prices[r]]])
			if picks["food"] != &"":
				front.append([ItemPropView.for_item(item_look, content, picks["food"], registry, 5), "food %s 5" % picks["food"]])
			var back := _key_and_armor_row(content, registry, item_look)
			for row in [[front, -1.6], [back, 1.2]]:
				_showcase_row(row[0], row[1], 1.6, lines)
		"tiers":
			# The aura's tiers side by side (gate 2): an item per tier, no labels, its tier written above it.
			ItemPropView.override_label = ItemCardLook.LabelMode.NONE
			var entries: Array = []
			for r in tier_ids.size():
				if tier_ids[r] != &"":
					entries.append([ItemPropView.for_item(item_look, content, tier_ids[r], registry), "tier %s %s" % [tier_names[r], tier_ids[r]],
						tier_names[r]])
			_showcase_row(entries, 0.0, 2.2, lines)
			for entry in entries:  # each caption over its own card, however many tiers the content has
				var placed: Node3D = entry[0]
				_showcase_text(entry[2], placed.position - FLOOR_TOP + Vector3(0, 2.0, 0))
		"sizes":
			# One row per card height (the look's `size`, raised so the card clears the floor), a column per tier, no labels.
			ItemPropView.override_label = ItemCardLook.LabelMode.NONE
			var heights: Array = item_look.get_meta(&"showcase_sizes", [0.7, 0.9, 1.1, 1.3])
			var gap := 4.8 / maxf(heights.size() - 1, 1)
			for row in heights.size():
				var sized := item_look.duplicate() as ItemCardLook
				sized.size = float(heights[row])
				sized.offset = Vector3(0, 0.35 + sized.size * 0.55, 0)
				_showcase_text("%.2f" % sized.size, Vector3(-6.2, 0.6, -2.6 + row * gap))
				for r in tier_ids.size():
					if tier_ids[r] == &"":
						continue
					var view := ItemPropView.for_item(sized, content, tier_ids[r], registry)
					view.position = Vector3((r - 2) * 2.2, 0, -2.6 + row * gap) + FLOOR_TOP
					_props_root.add_child(view)
					lines.append("size %.2f %s %s" % [sized.size, tier_names[r], tier_ids[r]])
		"pop":
			# One chest in the middle putting out one item at a time (Common, Rare, Epic, Legendary, corrupted, round and round,
			# every 2.5 s), the tier written above it.
			var ids := _chest_ids(content)
			var one_chest: ChestLook = registry.chest_look(ids[0] if not ids.is_empty() else &"")
			var from := Vector3(0, 0, -0.6) + FLOOR_TOP
			if one_chest != null:
				var chest := PropView.chest(one_chest, ChestLook.State.OPEN_EMPTY, "")
				chest.position = from
				_props_root.add_child(chest)
			var caption := Label3D.new()
			caption.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			caption.font_size = 56
			caption.position = Vector3(0, 2.6, 0.6) + FLOOR_TOP
			_props_root.add_child(caption)
			var ticker := Timer.new()
			ticker.wait_time = 2.5
			_props_root.add_child(ticker)
			var state := {"next": 0}
			var drop := func() -> void:
				for node in _props_root.get_children():
					if node is ItemPropView:
						node.queue_free()
				var r: int = state["next"] % tier_ids.size()
				state["next"] = r + 1
				if tier_ids[r] == &"":
					return
				var view := ItemPropView.for_item(item_look, content, tier_ids[r], registry)
				view.position = from + Vector3(0, 0, 1.6)
				_props_root.add_child(view)
				_pop_out(view, from, 0)
				caption.text = tier_names[r]
			ticker.timeout.connect(drop)
			drop.call()
			ticker.start()
			for r in tier_ids.size():
				lines.append("pop %s %s" % [tier_names[r], tier_ids[r]])
	ItemPropView.override_label = saved_label
	return lines


## The showcase's items: the first Common, Rare, Epic and Legendary item by id (not corrupted, not food), the first corrupted
## one, a shop item (the second Rare) and the first food item. Missing ones are &"".
static func showcase_items(content: ContentIndex) -> Dictionary:
	var ids: Array[String] = []
	for id in content.items:
		ids.append(String(id))
	ids.sort()
	var picks := {"common": &"", "rare": &"", "epic": &"", "legendary": &"", "void": &"", "food": &"", "shop": &""}
	for id in ids:
		var item: ItemDefinition = content.items[StringName(id)]
		if TagMatch.has(item.tags, FloorGenerator.DEV_TAG):
			continue
		if TagMatch.has(item.tags, &"Item.Corrupted"):
			if picks["void"] == &"":
				picks["void"] = StringName(id)
			continue
		if TagMatch.has_any(item.tags, CardFaces.FOOD_TAGS):
			if picks["food"] == &"":
				picks["food"] = StringName(id)
			continue
		for rarity in ["Common", "Rare", "Epic", "Legendary"]:
			if picks[rarity.to_lower()] == &"" and TagMatch.has(item.tags, StringName("Item.Rarity." + rarity)):
				picks[rarity.to_lower()] = StringName(id)
		if picks["shop"] == &"" and picks["rare"] != StringName(id) and TagMatch.has(item.tags, &"Item.Rarity.Rare"):
			picks["shop"] = StringName(id)
	return picks


## A key for sale and one armor piece per equipment slot (the first by id in each, in its own rarity), priced by rarity, as the
## look draws them beside the cards: [[view, line], ...].
func _key_and_armor_row(content: ContentIndex, registry: StyleRegistry, item_look: ItemCardLook) -> Array:
	var entries: Array = []
	var key_look := registry.key_look()
	if key_look != null:
		entries.append([_beside_cards(key_look, ItemPropView.label_for(item_look, "Key", 5), null, item_look), "key 5"])
	var price_by_tier := [5, 15, 25, 40]
	for slot in _slots(content):
		var piece := _showcase_piece(content, slot)
		var armor_look := registry.armor_look(slot) if piece != null else null
		if armor_look == null:
			continue
		var price: int = price_by_tier[clampi(item_look.tier_of(piece.tags), 0, 3)]
		var armor := _beside_cards(armor_look, ItemPropView.label_for(item_look, piece.display_name, price),
			registry.rarity_color(piece.tags, null), item_look)
		_armor_aura(armor, piece, item_look, registry)
		entries.append([armor, "armor %s %s %d" % [slot, piece.id, price]])
	return entries


## Lays `entries` ([view, line]) out in a row at depth `z`, `spread` apart, centred.
func _showcase_row(entries: Array, z: float, spread: float, lines: PackedStringArray) -> void:
	for i in entries.size():
		var view: PropView = entries[i][0]
		view.position = Vector3((i - (entries.size() - 1) / 2.0) * spread, 0, z) + FLOOR_TOP
		_props_root.add_child(view)
		lines.append(entries[i][1])


## The first armor piece by id in `slot` (not corrupted), or null.
func _showcase_piece(content: ContentIndex, slot: StringName) -> EquipmentDefinition:
	var ids: Array[String] = []
	for id in content.equipment:
		ids.append(String(id))
	ids.sort()
	for id in ids:
		var piece: EquipmentDefinition = content.equipment[StringName(id)]
		if piece.slot == slot and not TagMatch.has(piece.tags, &"Item.Corrupted"):
			return piece
	return null


func _showcase_text(text: String, at: Vector3) -> void:
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 40
	label.position = at + FLOOR_TOP
	_props_root.add_child(label)


func _chest_ids(content: ContentIndex) -> Array:
	var ids: Array = content.chests.keys() if content != null else []
	ids.sort()
	return ids


## The content's equipment slots in a fixed order (Weapon first), from the pieces it has.
func _slots(content: ContentIndex) -> Array[StringName]:
	var order: Array[StringName] = [&"Equipment.Slot.Weapon", &"Equipment.Slot.Head", &"Equipment.Slot.Body", &"Equipment.Slot.Arms",
		&"Equipment.Slot.Legs", &"Equipment.Slot.Accessory"]
	var found: Array[StringName] = []
	for slot in order:
		if content == null or content.equipment.values().any(func(e: EquipmentDefinition) -> bool: return e.slot == slot):
			found.append(slot)
	return found


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
	if text == "":
		return
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
