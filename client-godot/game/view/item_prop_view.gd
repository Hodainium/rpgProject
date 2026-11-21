## Spec item-cards 2.3 / 3.2: an item pickup on the floor (a pedestal, a shop shelf, an open chest's item) drawn from an
## ItemCardLook: the item's card (its live face, CardView3D, the card back on the reverse) turning and bobbing, a rim in the
## rarity's colour that glows brighter by tier, the tiered aura (item_aura: color, tier) and the floating label.
## A corrupted item is magenta at the top tier. Presentation only: nothing here reads or changes the run.
class_name ItemPropView
extends PropView

## Dev (console `style items label`): a label mode for this session over the look's (-1 = the look's).
static var override_label: int = -1
## Dev (console `style items bake on|off`): bake the faces into mipmapped textures (on: no shimmer) or show them live.
static var bake_faces: bool = true

var item_id: StringName
var tier: int = 0
var corrupted: bool = false
var card: CardView3D
var look: ItemCardLook
var _sway: float = 0.0

static var _rows: Dictionary = {}  # ContentIndex instance id -> {item id: catalog row}


## The view of item `id` of `content` with `look`, `price` gold on a shop shelf (0 = not for sale); the colour from `registry`'s
## rarity map (the armor icons' colours).
static func for_item(item_look: ItemCardLook, content: ContentIndex, id: StringName, registry: StyleRegistry, price: int = 0) -> ItemPropView:
	var entry: Resource = content.items.get(id) if content != null else null
	var tags: Array = entry.tags if entry != null else []
	var is_void := item_look.void_tag != &"" and TagMatch.has(tags, item_look.void_tag)
	var color: Color = item_look.void_color if is_void else (
		registry.rarity_color(tags, Color.WHITE) if registry != null else Color.WHITE)
	var style := CardStyle.current()
	var text := label_for(item_look, entry.display_name if entry != null else String(id), price)
	var view := item(item_look, face_for(content, style, id), style, color, item_look.tier_of(tags), is_void, text)
	view.item_id = id
	return view


## The floating label of any floor pickup (an item, a key, an armor piece) named `pickup_name` at `price` (0 = free) under
## `item_look`'s label mode (the session's override first): the shop's other pickups label the same way as its cards.
static func label_for(item_look: ItemCardLook, pickup_name: String, price: int) -> String:
	var mode := override_label if override_label >= 0 else int(item_look.label)
	return ItemCardLook.label_text(mode, pickup_name, price)


## The card face of item `id` (its catalog row; an item that is no card gets a plain common row).
static func face_for(content: ContentIndex, style: CardStyle, id: StringName) -> CardFace:
	if content == null:
		var blank := CardFace.new()
		blank.id = String(id)
		return blank
	var key := content.get_instance_id()
	if not _rows.has(key):
		var by_id := {}
		for row in CardCatalog.cards(content):
			by_id[row["id"]] = row
		_rows = {key: by_id}  # one content at a time
	var row: Dictionary = _rows[key].get(String(id), {"id": String(id), "kind": CardCatalog.KIND_ITEM, "rarity": "common"})
	return CardFaces.face_of(content, style, row)


## A view of `face`, rimmed and lit in `color` at `item_tier`, with `text` floating above it (empty = no label).
static func item(item_look: ItemCardLook, face: CardFace, style: CardStyle, color: Color, item_tier: int, is_void: bool,
		text: String) -> ItemPropView:
	var view := ItemPropView.new()
	view.name = "Item"
	view.look = item_look
	view.colour = color
	view.tier = item_tier
	view.corrupted = is_void
	view.holder = PropView._holder(item_look.offset, Vector3.ZERO, Vector3.ONE)
	view.add_child(view.holder)
	view.card = view._card(view.holder.get_child(0), face, style, item_look.size)
	view._spin = item_look.spin_speed
	view._sway = item_look.sway_degrees if item_look.spin_speed == 0.0 else 0.0
	view._bob_amount = item_look.bob_amount
	view._bob_speed = item_look.bob_speed
	view._rest = view.holder.position
	view._set_effect(item_look.aura, {&"tier": float(item_tier)}, color)
	view._label(text, item_look.label_height)
	return view


func _ready() -> void:
	super()
	_clock = float(hash(str(item_id, get_instance_id())) % 1000) / 1000.0 * 8.0  # each its own point in the turn and bob
	set_process(true)
	if card != null and card.face != null and bake_faces:
		card.bake()  # a mipmapped copy of the face and back: no shimmer at this size


func _process(delta: float) -> void:
	super(delta)
	if holder != null and _sway > 0.0:
		holder.rotation.y = deg_to_rad(sin(_clock * 0.25 * TAU) * _sway)


## The item's card (its live face and the card back), `height` tall, with the rarity rim on both sides.
func _card(parent: Node3D, face: CardFace, style: CardStyle, height: float) -> CardView3D:
	var view := CardView3D.new()
	view.name = "Card"
	parent.add_child(view)
	if face == null or style == null:
		return view
	view.show_face(face, style, style.face_scene(), height, look.card_render_scale)
	view.show_back(style, false)
	for material in [view.material, view.back_mesh.material_override]:
		var shader_material := material as ShaderMaterial
		if shader_material != null:
			shader_material.set_shader_parameter(&"rim_color", colour)
			shader_material.set_shader_parameter(&"rim_width", look.card_rim)
			shader_material.set_shader_parameter(&"rim_energy", look.rim_energy(tier))
	return view
