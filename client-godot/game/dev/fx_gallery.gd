## The effects gallery (spec vfx-framework 6): a test level for making and tuning effects fast. A 3D room with three unit
## cubes, three mock cards, a hybrid stage with a 3D card, and a button per effect that plays it where it belongs
## (a UI effect on a card, a 3D effect on a cube, a hybrid effect on the stage card, a screen effect on the window).
## Pick a rarity colour and a quality tier, toggle looping effects, stop everything. Dev builds and the editor only.
##   godot --path client-godot res://game/dev/fx_gallery.tscn                       (a window)
##   ... -- --play fx.hit_spark,fx.card_glow --shots <dir> [--shot-at 0.1,0.4,0.8]  (play, screenshot, quit)
## Claude uses the second form to look at an effect: one PNG per effect and time in <dir>. `--tiers high,low,medium,off` changes
## the quality tier between frames instead (the mid-game Settings change).
extends Node

const RARITIES: Dictionary = {"Common": Color(0.8, 0.82, 0.86), "Rare": Color(0.35, 0.6, 1.0), "Epic": Color(0.7, 0.4, 1.0),
	"Legendary": Color(1.0, 0.65, 0.15)}
const CARD_SIZE: Vector2 = Vector2(190, 270)

var _cubes: Array[MeshInstance3D] = []
var _cards: Array[Panel] = []
var _stage: FxStage
var _stage_card: MeshInstance3D
var _color: Color = RARITIES["Legendary"]
var _use_color: bool = false
var _loops: Dictionary = {}  # effect id -> FxHandle
var _status: Label


func _ready() -> void:
	# The inspector's Preview button (FxPreviewRequest): register that effect (it may not be in the registry yet) and play it.
	var preview_path := FxPreviewRequest.take()
	var preview := load(preview_path) as FxDefinition if preview_path != "" and ResourceLoader.exists(preview_path) else null
	if preview != null:
		FxManager.register(preview)
	_build_world()
	_build_hud()
	# P1..P3 are the three cubes (a cue's `target_ids`, a rule's units).
	FxManager.unit_resolver = func(unit_id: StringName) -> Node3D:
		return _cubes[clampi(String(unit_id).trim_prefix("E").trim_prefix("P").to_int() - 1, 0, _cubes.size() - 1)]
	if preview != null:
		get_tree().create_timer(0.5).timeout.connect(func() -> void: _play(preview.id))
	var args := OS.get_cmdline_user_args()
	if args.has("--play"):
		_run_shots(args)
	elif args.has("--rules"):
		_run_rules(args)


func _process(delta: float) -> void:
	if is_instance_valid(_stage_card):
		_stage_card.rotate_y(delta * 0.4)


# --- Layout ----------------------------------------------------------------------------------------------------------

func _build_world() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(0, 7, 8)
	camera.rotation_degrees = Vector3(-42, 0, 0)
	add_child(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, 30, 0)
	add_child(light)
	var floor_mesh := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(16, 0.2, 7)
	floor_mesh.mesh = plane
	floor_mesh.position = Vector3(0, -0.6, 0)
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.2, 0.21, 0.26)
	floor_mesh.material_override = floor_material
	add_child(floor_mesh)
	var palette := [Color(0.35, 0.55, 0.95), Color(0.95, 0.5, 0.3), Color(0.5, 0.85, 0.5)]
	for index in 3:
		var cube := MeshInstance3D.new()
		cube.mesh = BoxMesh.new()
		var material := StandardMaterial3D.new()
		material.albedo_color = palette[index]
		cube.material_override = material
		cube.position = Vector3(-5.0 + index * 2.4, 0.0, 0.5)
		cube.name = "Cube%d" % index
		add_child(cube)
		_cubes.append(cube)


func _build_hud() -> void:
	var hud := Control.new()
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)
	# Effect buttons, left.
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(12, 12)
	scroll.size = Vector2(250, 760)
	hud.add_child(scroll)
	var column := VBoxContainer.new()
	scroll.add_child(column)
	_status = Label.new()
	_status.text = "pick an effect"
	column.add_child(_status)
	for id in FxManager.catalog():
		var definition := FxManager.definition(id)
		var button := Button.new()
		button.text = "%s%s" % [id, " (loop)" if definition.is_looping() else ""]
		button.pressed.connect(_play.bind(id))
		column.add_child(button)
	var stop := Button.new()
	stop.text = "Stop all"
	stop.pressed.connect(func() -> void:
		_loops.clear()
		FxManager.stop_all())
	column.add_child(stop)
	# Rarity colours and quality.
	var options := HBoxContainer.new()
	options.position = Vector2(280, 12)
	hud.add_child(options)
	var colour_pick := OptionButton.new()
	colour_pick.add_item("effect default")
	for rarity in RARITIES:
		colour_pick.add_item(rarity)
	colour_pick.item_selected.connect(func(index: int) -> void:
		_use_color = index > 0
		if index > 0:
			_color = RARITIES[RARITIES.keys()[index - 1]])
	options.add_child(colour_pick)
	var quality_pick := OptionButton.new()
	for tier in FxQuality.NAMES:
		quality_pick.add_item("quality: " + tier)
	quality_pick.selected = FxManager.quality
	quality_pick.item_selected.connect(func(index: int) -> void: FxManager.quality = index)
	options.add_child(quality_pick)
	# Mock cards, bottom centre.
	for index in 3:
		var card := Panel.new()
		card.size = CARD_SIZE
		card.position = Vector2(420 + index * 240, 760)
		card.pivot_offset = CARD_SIZE * 0.5
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.16, 0.18, 0.24)
		style.set_corner_radius_all(14)
		style.set_border_width_all(3)
		style.border_color = Color(0.45, 0.5, 0.6)
		card.add_theme_stylebox_override("panel", style)
		var label := Label.new()
		label.text = "Card %d" % (index + 1)
		label.position = Vector2(16, 16)
		card.add_child(label)
		hud.add_child(card)
		_cards.append(card)
	# The hybrid stage, right.
	var frame := Panel.new()
	frame.position = Vector2(1180, 60)
	frame.size = Vector2(640, 520)
	hud.add_child(frame)
	_stage = FxStage.new()
	_stage.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_stage.position = Vector2(1180, 60)
	_stage.size = Vector2(640, 520)
	hud.add_child(_stage)
	_stage_card = MeshInstance3D.new()
	var slab := BoxMesh.new()
	slab.size = Vector3(1.8, 2.5, 0.08)
	_stage_card.mesh = slab
	var slab_material := StandardMaterial3D.new()
	slab_material.albedo_color = Color(0.25, 0.3, 0.45)
	_stage_card.material_override = slab_material
	_stage.world_root.add_child(_stage_card)


# --- Playing ---------------------------------------------------------------------------------------------------------

## Where an effect belongs: a card for a UI effect, a cube for a 3D one, the stage's card for a hybrid, the window for a screen.
func _anchor_for(definition: FxDefinition) -> FxAnchor:
	match definition.space:
		FxDefinition.Space.UI:
			return FxAnchor.control(_cards[1])
		FxDefinition.Space.WORLD_3D:
			return FxAnchor.node3d(_cubes[1])
		FxDefinition.Space.HYBRID:
			return FxAnchor.on_stage(_stage, _stage_card)
	return FxAnchor.screen()


func _play(id: StringName) -> FxHandle:
	# `cue:<Cue.Fx.Tag>` plays what a cue plays: its effect with the cue scene's literal parameters (a status look as the game shows it).
	if String(id).begins_with("cue:"):
		return _play_cue(StringName(String(id).trim_prefix("cue:")))
	var definition := FxManager.definition(id)
	if definition == null:
		return null
	if _loops.has(id) and _loops[id].is_playing():
		_loops[id].stop(0.3)
		_loops.erase(id)
		_status.text = "stopped " + String(id)
		return null
	var params := {}
	if _use_color and definition.param(&"color") != null:
		params["color"] = _color
	var handle := FxManager.play(definition, _anchor_for(definition), params)
	if definition.is_looping():
		_loops[id] = handle
	_status.text = "%s -> %s" % [id, "playing" if handle.is_playing() else "did not play"]
	return handle


## `cue:<Cue.Fx.Tag>` executes a cue through the real GodotGAS cue manager on the first cube (the caster P1), with the payload an ability would
## pass: `target_ids` P2 and P3 (the other two cubes). A status look is a persistent cue, a tick or an ultimate a one-shot.
func _play_cue(tag: StringName) -> FxHandle:
	var scene := GameplayCueManager._scene_for(tag) as PackedScene
	var probe := scene.instantiate() as FxCueNotify if scene != null else null
	if probe == null:
		_status.text = "no cue " + String(tag)
		return null
	var persistent := not probe.auto_destroy
	probe.free()
	var payload := {"target_ids": [&"P2", &"P3"]}
	if persistent:
		GameplayCueManager.add_persistent_cue(tag, _cubes[0], payload)
	else:
		GameplayCueManager.execute_cue(tag, _cubes[0], payload)
	_status.text = "%s -> executed" % tag
	return null


# --- Screenshots ------------------------------------------------------------------------------------------------------

func _run_shots(args: PackedStringArray) -> void:
	var ids: PackedStringArray = _arg(args, "--play", "").split(",", false)
	var dir := _arg(args, "--shots", "")
	var times: Array[float] = []
	for text in _arg(args, "--shot-at", "0.12,0.35,0.7").split(",", false):
		times.append(text.to_float())
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
	if args.has("--color"):
		_use_color = true
		_color = Color.from_string(_arg(args, "--color", "#ffa626"), Color.WHITE)
	await get_tree().create_timer(0.4).timeout
	var tiers: PackedStringArray = _arg(args, "--tiers", "").split(",", false)
	for id in ids:
		var handle := _play(StringName(id))
		var frames: Array[Image] = []
		var last := 0.0
		# --tiers high,low,medium,off: change the quality tier while the (looping) effect plays and take a frame after each
		# change (a mid-game Settings change; spec vfx-framework). The first frame is taken before any change.
		if not tiers.is_empty():
			for tier_name in tiers:
				FxManager.quality = FxQuality.from_text(tier_name)
				await get_tree().create_timer(0.5).timeout
				if dir != "":
					await RenderingServer.frame_post_draw
					frames.append(get_viewport().get_texture().get_image())
			times = []
		for time in times:
			await get_tree().create_timer(maxf(time - last, 0.001)).timeout
			last = time
			if dir != "":
				await RenderingServer.frame_post_draw
				frames.append(get_viewport().get_texture().get_image())
		if dir != "" and not frames.is_empty():
			_save_sheet(frames, FxManager.definition(StringName(id)), "%s/%s.png" % [dir, id.replace(":", "_")])
		if handle != null:
			handle.stop(0.0)
		FxManager.stop_all()
		_loops.clear()
		await get_tree().create_timer(0.15).timeout
	get_tree().quit()


## `--rules --shots <dir>` (spec vfx-content-pass): attaches the battle FX rule set, maps P1..P3 to the three cubes and broadcasts
## sample battle messages (a fire crit, a resisted ice hit, a plain physical hit, a poison tick, a heal), taking a contact sheet
## of each, so the damage numbers and per-type effects are seen through the real message bus.
func _run_rules(args: PackedStringArray) -> void:
	var dir := _arg(args, "--shots", "")
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
	for rules in (load("res://presentation/demo/fx/fx_registry.tres") as FxRegistry).all_rule_sets():
		rules.attach(self)
	FxManager.unit_resolver = func(unit_id: StringName) -> Node3D:
		return _cubes[clampi(String(unit_id).trim_prefix("E").trim_prefix("P").to_int() - 1, 0, _cubes.size() - 1)]
	var scenarios := [
		["fire_crit", GameplayMessageRouter.BATTLE_DAMAGE, &"Verb.Damage", 245600, [&"Damage.Type.Fire", &"Hit.Critical", &"Hit.Weakness"]],
		["ice_resisted", GameplayMessageRouter.BATTLE_DAMAGE, &"Verb.Damage", 31200, [&"Damage.Type.Ice", &"Hit.Resisted"]],
		["physical", GameplayMessageRouter.BATTLE_DAMAGE, &"Verb.Damage", 87400, [&"Damage.Type.Physical"]],
		["break", GameplayMessageRouter.BATTLE_DAMAGE, &"Verb.Damage", 150000, [&"Damage.Type.Physical", &"Hit.Break"]],
		["poison_tick", GameplayMessageRouter.BATTLE_HP_CHANGED, &"Verb.Damage", 4000, [&"Status.Debuff.Poison"]],
		["heal", GameplayMessageRouter.BATTLE_HP_CHANGED, &"Verb.Heal", 56000, []]]
	var only := _arg(args, "--rules-only", "")
	await get_tree().create_timer(0.4).timeout
	for scenario in scenarios:
		if only != "" and not only.split(",").has(scenario[0]):
			continue
		var message := VerbMessage.make(scenario[2], scenario[6] if scenario.size() > 6 else &"", &"P2", scenario[3], scenario[4],
			scenario[5] if scenario.size() > 5 else {})
		GameplayMessages.broadcast(scenario[1], message)
		var frames: Array[Image] = []
		var last := 0.0
		for time in (scenario[7] if scenario.size() > 7 else [0.12, 0.4, 0.8]):
			await get_tree().create_timer(time - last).timeout
			last = time
			await RenderingServer.frame_post_draw
			frames.append(get_viewport().get_texture().get_image())
		_save_sheet(frames, null, "%s/%s.png" % [dir, scenario[0]])
		FxManager.stop_all()
		await get_tree().create_timer(0.2).timeout
	get_tree().quit()


## One PNG per effect: the frames side by side, cropped to where the effect plays.
func _save_sheet(frames: Array[Image], definition: FxDefinition, path: String) -> void:
	var crop := Rect2i(0, 0, 1920, 1080)
	match definition.space if definition != null else FxDefinition.Space.WORLD_3D:
		FxDefinition.Space.UI:
			crop = Rect2i(470, 660, 560, 420)
		FxDefinition.Space.WORLD_3D:
			crop = Rect2i(560, 300, 440, 380)
		FxDefinition.Space.HYBRID:
			crop = Rect2i(1100, 20, 800, 600)
	var size := crop.size
	var scale_down := 1.0 if definition == null or definition.space != FxDefinition.Space.SCREEN else 0.4
	var cell := Vector2i(Vector2(size) * scale_down)
	var sheet := Image.create(cell.x * frames.size(), cell.y, false, Image.FORMAT_RGBA8)
	for index in frames.size():
		var piece := frames[index].get_region(crop)
		piece.convert(Image.FORMAT_RGBA8)
		if scale_down != 1.0:
			piece.resize(cell.x, cell.y, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(piece, Rect2i(Vector2i.ZERO, cell), Vector2i(index * cell.x, 0))
	sheet.save_png(path)


static func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
