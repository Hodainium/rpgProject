## A pack as a 3D foil pouch (playtest 2026-11-18, the user asked whether the pack can be 3D; compared in
## game/dev/pack_foil_demo.tscn): the flat CardPackView rendered once into a texture on the front, a printed back with the fin
## seam down its middle, both on a mesh shaped like a real foil pack: a mostly flat body that softens only near its edges, and
## flat pressed seals at the top and bottom (the crimp teeth clamped shut, with ridges). The metallic material
## (game/cards/shaders/pack_foil_3d.gdshader) reflects the scene's lights and sky, so the foil shines as the pack turns; `holo`
## adds an angle-dependent rainbow. Presentation only.
class_name CardPack3D
extends Node3D

## The pack's height in world units (its width follows the flat pack's 150 x 228).
@export var height: float = 1.52
## How far the front's body stands off the seal plane, and the back's, as a share of the width (playtest: not a balloon).
@export var puff: float = 0.045
@export var back_puff: float = 0.035
## The pressed seal at each end, as a share of the height (flat, where front and back are clamped together).
@export var seal: float = 0.085
@export var metal: float = 0.75
@export var rough: float = 0.25
@export var holo: float = 0.0
## Pixels of the picture the pack is drawn at.
@export var picture_height: int = 912

const COLUMNS := 40
const ROWS := 72
## Ridges across each seal (the crimp).
const RIDGES := 44
## Built meshes by their shape (every pack of one size shares them; building one takes a few ms).
static var _meshes: Dictionary = {}

var viewport: SubViewport
var back_viewport: SubViewport
var view: CardPackView
var front: MeshInstance3D
var back: MeshInstance3D
var material: ShaderMaterial
var back_material: ShaderMaterial


## Shows the pack of `look` labelled `label`.
func show_pack(look: CardPackLook, label: String, name_font: Font = null) -> void:
	var picture := Vector2i(int(picture_height * 150.0 / 228.0), picture_height)
	if viewport == null:
		viewport = _picture_viewport("Picture")
		view = CardPackView.new()
		view.glare_period = 0.0   # the light on the metal is the glare now
		viewport.add_child(view)
		viewport.add_child(SealRidges.new(seal))
		back_viewport = _picture_viewport("BackPicture")
		back_viewport.add_child(PackBack.new())
		back_viewport.add_child(SealRidges.new(seal))
	for port in [viewport, back_viewport]:
		port.size = picture
		for child in port.get_children():
			(child as Control).custom_minimum_size = Vector2.ONE
			(child as Control).size = Vector2(picture)
	view.look = look
	view.label = label
	view.name_font = name_font
	(back_viewport.get_child(0) as PackBack).look = look
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	back_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	if material == null:
		material = ShaderMaterial.new()
		material.shader = load("res://game/cards/shaders/pack_foil_3d.gdshader")
		back_material = ShaderMaterial.new()
		back_material.shader = material.shader
	material.set_shader_parameter(&"pack", viewport.get_texture())
	back_material.set_shader_parameter(&"pack", back_viewport.get_texture())
	apply_foil()
	var width := height * 150.0 / 228.0
	if front == null:
		front = MeshInstance3D.new()
		front.name = "Front"
		add_child(front)
		back = MeshInstance3D.new()
		back.name = "Back"
		add_child(back)
	front.mesh = pouch(width, height, puff * width, seal, false)
	front.material_override = material
	back.mesh = pouch(width, height, back_puff * width, seal, true)
	back.material_override = back_material


func _picture_viewport(port_name: String) -> SubViewport:
	var port := SubViewport.new()
	port.name = port_name
	port.transparent_bg = true
	port.disable_3d = true
	add_child(port)
	return port


## Re-reads `metal`, `rough` and `holo` into the materials (the back gets half the rainbow).
func apply_foil() -> void:
	for target in [material, back_material]:
		if target == null:
			continue
		target.set_shader_parameter(&"metal", metal)
		target.set_shader_parameter(&"rough", rough)
		target.set_shader_parameter(&"holo", holo if target == material else holo * 0.5)


## One face of the pouch: a grid standing off the seal plane by `bulge`, flat across the middle and rounding off only near the
## sides, and exactly flat (z = 0, where the front and the back meet) over the `seal` share at each end, so the crimped teeth
## lie pressed together. `flip` makes the back (facing -z, its picture mirrored so it reads from behind).
static func pouch(width: float, tall: float, bulge: float, seal_share: float, flip: bool) -> ArrayMesh:
	var key := "%s|%s|%s|%s|%s" % [width, tall, bulge, seal_share, flip]
	if _meshes.has(key):
		return _meshes[key]
	var mesh := _build_pouch(width, tall, bulge, seal_share, flip)
	_meshes[key] = mesh
	return mesh


static func _build_pouch(width: float, tall: float, bulge: float, seal_share: float, flip: bool) -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sign := -1.0 if flip else 1.0
	for row in ROWS + 1:
		for column in COLUMNS + 1:
			var u := float(column) / COLUMNS
			var v := float(row) / ROWS
			var across := 1.0 - pow(absf(2.0 * u - 1.0), 6.0)
			var body := (v - seal_share) / maxf(1.0 - 2.0 * seal_share, 0.01)
			var along := 0.0
			if body > 0.0 and body < 1.0:
				along = 1.0 - pow(absf(2.0 * body - 1.0), 8.0)
			tool.set_uv(Vector2(1.0 - u if flip else u, v))
			tool.add_vertex(Vector3((u - 0.5) * width, (0.5 - v) * tall, sign * bulge * across * along))
	for row in ROWS:
		for column in COLUMNS:
			var a := row * (COLUMNS + 1) + column
			var b := a + 1
			var c := a + COLUMNS + 1
			var d := c + 1
			# Godot's front faces wind clockwise as seen from the side they face (+z for the front, -z for the back).
			for index in ([a, c, b, b, c, d] if flip else [a, b, c, b, d, c]):
				tool.add_index(index)
	tool.generate_normals()
	tool.generate_tangents()
	return tool.commit()


## The back of the pack: its body in the pack's colours (darker toward the bottom), the fin seam down the middle, and the
## crimped ends (the alpha cuts the teeth, like the front).
class PackBack:
	extends Control

	var look: CardPackLook:
		set(value):
			look = value
			queue_redraw()

	func _draw() -> void:
		var pack: CardPackLook = look if look != null else CardPackLook.new()
		var area := Rect2(Vector2.ZERO, size)
		var points := PackedVector2Array()
		var depth := area.size.y * 0.03
		for index in CardPackView.CRIMPS + 1:
			points.append(Vector2(area.size.x * index / CardPackView.CRIMPS, depth if index % 2 == 0 else 0.0))
		for index in range(CardPackView.CRIMPS, -1, -1):
			points.append(Vector2(area.size.x * index / CardPackView.CRIMPS, area.size.y - (depth if index % 2 == 0 else 0.0)))
		var colors := PackedColorArray()
		for point in points:
			colors.append(pack.color_light.darkened(0.25).lerp(pack.color_dark.darkened(0.2), point.y / maxf(area.size.y, 1.0)))
		draw_polygon(points, colors)
		var fin := area.size.x * 0.07
		var middle := area.size.x * 0.5
		draw_rect(Rect2(middle - fin * 0.5, depth, fin, area.size.y - depth * 2.0), pack.color_dark.lightened(0.15))
		draw_line(Vector2(middle - fin * 0.5, depth), Vector2(middle - fin * 0.5, area.size.y - depth), pack.color_dark.darkened(0.5), 3.0)
		draw_line(Vector2(middle + fin * 0.5, depth), Vector2(middle + fin * 0.5, area.size.y - depth), pack.color_light, 2.0)
		if pack.glyph != null:
			var side := area.size.x * 0.18
			draw_texture_rect(pack.glyph, Rect2(Vector2(area.size.x * 0.72 - side * 0.5, area.size.y * 0.78), Vector2(side, side)),
				false, Color(pack.accent, 0.7))


## The crimp ridges over the pressed seals: thin light and dark stripes across both ends, which the metal catches.
class SealRidges:
	extends Control

	var share: float

	func _init(seal_share: float = 0.085) -> void:
		share = seal_share
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var band := size.y * share
		var step := size.x / RIDGES
		for index in RIDGES:
			var x := index * step
			for top in [0.0, size.y - band]:
				draw_rect(Rect2(x, top, step * 0.5, band), Color(1, 1, 1, 0.16))
				draw_rect(Rect2(x + step * 0.5, top, step * 0.5, band), Color(0, 0, 0, 0.22))
		draw_line(Vector2(0, band), Vector2(size.x, band), Color(0, 0, 0, 0.35), 2.0)
		draw_line(Vector2(0, size.y - band), Vector2(size.x, size.y - band), Color(0, 0, 0, 0.35), 2.0)
