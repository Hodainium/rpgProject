## Floating text in the 3D world (spec vfx-content-pass 2.5): a damage number. An outlined, billboarded Label3D that pops
## in, rises and fades away on the FX clock; an optional small tag line sits above it ("Crit!"). Everything a designer
## tunes is a field here or a parameter: bind `text`, `modulate` (the colour), `outline_modulate`, `outline_size` and
## `font_size`; the tag line reads the parameters named `label` (its text, empty = none) and `label_color`.
## Presentation only: no state, no hashes; the numbers shown are display copies.
class_name FxTextLayer
extends FxLayer

@export var text: String = "0"
@export var font: Font
@export var font_size: int = 64
@export var outline_size: int = 12
@export var color: Color = Color.WHITE
@export var outline_color: Color = Color(0.05, 0.05, 0.08, 1.0)
## World size of one pixel of text.
@export var pixel_size: float = 0.0095
## Where the text starts above its socket (the effect attaches to Top), and how far it rises (world units).
@export var height: float = 0.85
@export var rise: float = 0.9
## Where around the target the number appears (world units, a random spot from the layer's own unseeded RNG, within this
## range sideways and up/down), so a multi-hit does not stack on one spot.
@export var scatter: float = 0.5
@export var scatter_y: float = 0.35
## Total life in seconds: pop-in, hold, then fade.
@export var seconds: float = 1.1
## The arrival (Honkai style): the text starts large and transparent and settles to normal size while it fades fully in. The
## share of the life it takes (0..1) and the scale it starts at (a multiple of the normal size).
@export_range(0.0, 0.5) var pop_share: float = 0.18
@export var pop_scale: float = 2.0
## The last share of the life spent fading out.
@export_range(0.0, 1.0) var fade_share: float = 0.4
## The tag line ("Crit!") is this fraction of the number's size.
@export var tag_scale: float = 0.55

const TAG: StringName = &"fx_text_tag"
const ORIGIN: StringName = &"fx_text_origin"
const BASE: StringName = &"fx_text_base"

var _rng := RandomNumberGenerator.new()


func kind() -> StringName:
	return &"text"


func native_space() -> int:
	return Space.WORLD_3D


func build() -> Node:
	var label := Label3D.new()
	_style(label)
	var tag := Label3D.new()
	_style(tag)
	tag.name = "Tag"
	label.add_child(tag)
	label.set_meta(TAG, tag)
	return label


func apply(node: Node, params: Dictionary, anchor: FxAnchor, quality: int, definition: FxDefinition) -> void:
	var label := node as Label3D
	label.text = text
	label.modulate = color
	label.outline_modulate = outline_color
	label.outline_size = outline_size
	label.font_size = font_size
	super(node, params, anchor, quality, definition)
	var tag: Label3D = label.get_meta(TAG)
	var tag_text := String(params.get("label", ""))
	tag.visible = tag_text != ""
	tag.text = tag_text
	tag.font_size = roundi(label.font_size * tag_scale)
	tag.outline_size = roundi(label.outline_size * tag_scale)
	tag.modulate = params.get("label_color", label.modulate)
	tag.outline_modulate = label.outline_modulate
	tag.position = Vector3(0, label.font_size * label.pixel_size * 0.95, 0)
	label.set_meta(ORIGIN, Vector3(_rng.randf_range(-scatter, scatter), height + _rng.randf_range(-scatter_y, scatter_y), _rng.randf_range(-0.2, 0.2)))
	label.position = label.get_meta(ORIGIN)


func start(node: Node) -> void:
	super(node)
	var label := node as Label3D
	label.set_meta(BASE, [label.modulate, (label.get_meta(TAG) as Label3D).modulate, label.outline_modulate])


func update(node: Node, local_time: float, length_seconds: float, _params: Dictionary) -> void:
	var label := node as Label3D
	var u := progress(local_time, length_seconds)
	var origin: Vector3 = label.get_meta(ORIGIN, Vector3.ZERO)
	# Rise on an ease-out curve; the pop-in scales up past 1 and settles.
	label.position = origin + Vector3(0, rise * (1.0 - pow(1.0 - u, 2.0)), 0)
	# Arrival: big and transparent, shrinking to normal size as it becomes fully opaque; then it holds and fades out.
	var pop := 1.0
	var alpha := 1.0
	if pop_share > 0.0 and u < pop_share:
		var arrive := u / pop_share
		pop = lerpf(pop_scale, 1.0, 1.0 - pow(1.0 - arrive, 2.0))
		alpha = arrive
	label.scale = Vector3.ONE * pop
	if fade_share > 0.0 and u > 1.0 - fade_share:
		alpha = 1.0 - (u - (1.0 - fade_share)) / fade_share
	var base: Array = label.get_meta(BASE, [label.modulate, label.modulate, label.outline_modulate])
	label.modulate = Color(base[0].r, base[0].g, base[0].b, base[0].a * alpha)
	var tag: Label3D = label.get_meta(TAG)
	tag.modulate = Color(base[1].r, base[1].g, base[1].b, base[1].a * alpha)
	label.outline_modulate = Color(base[2].r, base[2].g, base[2].b, base[2].a * alpha)
	tag.outline_modulate = label.outline_modulate


func reset(node: Node) -> void:
	super(node)
	node.scale = Vector3.ONE


func natural_length(_node: Node, _params: Dictionary) -> float:
	return seconds


func _style(label: Label3D) -> void:
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.shaded = false
	label.double_sided = true
	label.pixel_size = pixel_size
	label.render_priority = 10
	label.outline_render_priority = 9
	if font != null:
		label.font = font
