## The 3D pack demo (playtest 2026-11-18): the Descent pack as the 3D foil pouch, plain metallic (the user's pick, used in the
## game) beside holographic. The packs turn slowly to show both sides; dragging with the left button spins them; the light
## follows the pointer. (The flat foil looks first compared here were removed once the user picked the 3D pack.)
##   godot --path client-godot res://game/dev/pack_foil_demo.tscn [--screen 2] [-- --shot <png> [--spin <radians>]]
extends Control

const THEME := "res://presentation/demo/ui/ui_theme.tres"
const PACK_ID := "descent-pack"
const SOLID := [["3D metallic foil", 0.0], ["3D holographic foil", 0.3]]

var _solid: Array[Dictionary] = []   # {container, pack: CardPack3D, light: OmniLight3D}
var _time: float = 0.0
var _spin: float = 0.0
var _dragging: bool = false
var _holding: bool = false   # a picture at a fixed angle (--spin)


func _ready() -> void:
	theme = load(THEME)
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
	title.text = "3D pack: it turns on its own; drag to spin it, the light follows the pointer"
	title.theme_type_variation = &"Title"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	var bottom := _row(column)
	for option in SOLID:
		var container := SubViewportContainer.new()
		container.stretch = true
		container.custom_minimum_size = Vector2(700, 900)
		var viewport := SubViewport.new()
		viewport.own_world_3d = true
		viewport.transparent_bg = true
		viewport.msaa_3d = Viewport.MSAA_4X
		container.add_child(viewport)
		var environment := WorldEnvironment.new()
		environment.environment = CardPack3D.foil_environment()
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
	for entry in _solid:
		var rect: Rect2 = (entry["container"] as Control).get_global_rect()
		var local := (mouse - rect.get_center()) / (rect.size * 0.5)
		local = local.clamp(Vector2(-1.5, -1.5), Vector2(1.5, 1.5))
		var pack: CardPack3D = entry["pack"]
		pack.rotation = Vector3(0.18 * sin(_time * 0.6), _spin, 0.0)
		(entry["light"] as OmniLight3D).position = Vector3(local.x * 1.4, -local.y * 1.4, 1.6)
