## The pack foil demo (playtest 2026-11-18): the Descent pack as it is now beside foil looks to pick from. Top row: the flat pack
## with a foil shader over it (holographic, brushed metal, chrome, glitter). Bottom row: the pack as a 3D foil pouch with real
## metallic lighting (plain metallic, holographic). Move the pointer: the light follows it and the 3D packs tilt toward it.
##   godot --path client-godot res://game/dev/pack_foil_demo.tscn [--screen 2] [-- --3d]
## `--3d`: only the 3D packs, bigger; they turn slowly to show both sides, and dragging with the left button spins them.
extends Control

const THEME := "res://presentation/demo/ui/ui_theme.tres"
const PACK_ID := "descent-pack"
const FLAT := [["Now (glare only)", 0], ["Holographic", 1], ["Brushed metal", 2], ["Chrome", 4], ["Glitter", 3]]
const SOLID := [["3D metallic foil", 0.0], ["3D holographic foil", 0.3]]

var _flat: Array[CardPackView] = []
var _solid: Array[Dictionary] = []   # {container, pack: CardPack3D, light: OmniLight3D}
var _time: float = 0.0
var _only_3d: bool = false
var _spin: float = 0.0
var _dragging: bool = false
var _holding: bool = false   # a picture at a fixed angle (--spin)


func _ready() -> void:
	theme = load(THEME)
	_only_3d = OS.get_cmdline_user_args().has("--3d")
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := CardStyle.current()
	var look := style.pack(PACK_ID)
	var background := ColorRect.new()
	background.color = Color(0.06, 0.05, 0.1)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 16)
	add_child(column)
	var title := Label.new()
	title.text = "Pack foil demo: move the pointer to move the light"
	if _only_3d:
		title.text = "3D pack: it turns on its own; drag to spin it, the light follows the pointer"
	title.theme_type_variation = &"Title"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	var top := _row(column)
	top.visible = not _only_3d
	for option in ([] if _only_3d else FLAT):
		var view := CardPackView.new()
		view.look = look
		view.name_font = style.name_font
		view.label = look.label
		view.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		view.size_flags_vertical = Control.SIZE_EXPAND_FILL
		view.custom_minimum_size = Vector2(280, 426)
		if option[1] > 0:
			var foil := ShaderMaterial.new()
			foil.shader = load("res://game/cards/shaders/pack_foil.gdshader")
			foil.set_shader_parameter(&"mode", option[1])
			foil.set_shader_parameter(&"auto_light", 0.0)
			view.foil = foil
			view.glare_period = 0.0   # the foil is the shine
		_flat.append(view)
		top.add_child(_captioned(view, option[0]))
	var bottom := _row(column)
	for option in SOLID:
		var container := SubViewportContainer.new()
		container.stretch = true
		container.custom_minimum_size = Vector2(700, 900) if _only_3d else Vector2(460, 470)
		var viewport := SubViewport.new()
		viewport.own_world_3d = true
		viewport.transparent_bg = true
		viewport.msaa_3d = Viewport.MSAA_4X
		container.add_child(viewport)
		var environment := WorldEnvironment.new()
		var env := Environment.new()
		env.background_mode = Environment.BG_CLEAR_COLOR
		var sky := Sky.new()
		var sky_material := ProceduralSkyMaterial.new()
		sky_material.sky_top_color = Color(0.35, 0.4, 0.6)
		sky_material.sky_horizon_color = Color(0.9, 0.85, 0.8)
		sky_material.ground_bottom_color = Color(0.08, 0.06, 0.12)
		sky_material.ground_horizon_color = Color(0.5, 0.45, 0.5)
		sky.sky_material = sky_material
		env.sky = sky
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
		env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		environment.environment = env
		viewport.add_child(environment)
		var camera := Camera3D.new()
		camera.position = Vector3(0, 0, 3.0)
		camera.fov = 40.0
		viewport.add_child(camera)
		var key := DirectionalLight3D.new()
		key.rotation_degrees = Vector3(-30, 25, 0)
		key.light_energy = 1.2
		viewport.add_child(key)
		var light := OmniLight3D.new()
		light.position = Vector3(0.5, 0.6, 1.6)
		light.omni_range = 6.0
		light.light_energy = 3.0
		viewport.add_child(light)
		var pack := CardPack3D.new()
		pack.holo = option[1]
		viewport.add_child(pack)
		pack.show_pack(look, look.label, style.name_font)
		_solid.append({"container": container, "pack": pack, "light": light})
		bottom.add_child(_captioned(container, option[0]))
	_shot_if_asked()


## `-- --shot <png>`: saves one picture after two seconds and quits (to check the looks without a person at the window).
func _shot_if_asked() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--shot")
	if at < 0 or at + 1 >= args.size():
		return
	var turn := args.find("--spin")
	if turn >= 0 and turn + 1 < args.size():
		_spin = float(args[turn + 1])
		_holding = true   # holds the angle for the picture
	await get_tree().create_timer(2.0).timeout
	get_viewport().get_texture().get_image().save_png(args[at + 1])
	get_tree().quit()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
		_spin += event.relative.x * 0.01


func _row(parent: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 48)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(row)
	return row


func _captioned(child: Control, text: String) -> Control:
	var box := VBoxContainer.new()
	box.add_child(child)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(label)
	return box


func _process(delta: float) -> void:
	_time += delta
	if not _dragging and not _holding:
		_spin += delta * 0.7
	var mouse := get_global_mouse_position()
	for view in _flat:
		if view.foil == null:
			continue
		var rect := view.get_global_rect()
		var local := (mouse - rect.position) / rect.size
		view.foil.set_shader_parameter(&"light", Vector2(clampf(local.x, -0.5, 1.5), clampf(local.y, -0.5, 1.5)))
	for entry in _solid:
		var rect: Rect2 = (entry["container"] as Control).get_global_rect()
		var local := (mouse - rect.get_center()) / (rect.size * 0.5)
		local = local.clamp(Vector2(-1.5, -1.5), Vector2(1.5, 1.5))
		var pack: CardPack3D = entry["pack"]
		if _only_3d:
			pack.rotation = Vector3(0.18 * sin(_time * 0.6), _spin, 0.0)
		else:
			pack.rotation = Vector3(local.y * 0.35 + sin(_time * 0.7) * 0.04, local.x * 0.55 + sin(_time * 0.5) * 0.06, 0.0)
		(entry["light"] as OmniLight3D).position = Vector3(local.x * 1.4, -local.y * 1.4, 1.6)
