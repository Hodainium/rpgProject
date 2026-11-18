## Spec card-ui 3.3: builds the CardFace of every catalog card from the content (names, texts, tags, what an item grants) and the
## style (elements, rules, icons, portraits). Pure: reads a ContentIndex and a CardStyle, writes nothing, needs no Node, so it
## runs headless. Element resolution (3.2): the per-card override, then the first element rule that matches, then for a character
## the damage type most of its abilities carry (ties: physical, fire, ice), then the style's default.
class_name CardFaces
extends RefCounted

const DAMAGE_PREFIX: String = "Damage.Type."
## A character's tie order (spec 3.2).
const CHARACTER_ELEMENTS: Array[String] = ["physical", "fire", "ice"]
const FOOD_TAGS: Array[StringName] = [&"Item.Food", &"Pool.Food"]
const CORRUPTED_TAG: StringName = &"Item.Corrupted"
const UNKNOWN_TYPE: String = "Unknown card"

static var _scene_tags: Dictionary = {}  # scene or resource path → Array[StringName] (cached: scenes are read once)


## A face for every row of `rows` (CardCatalog.cards rows, or the server's catalog rows with the same keys); rows default to the
## content's own catalog. Server rows the content lacks become "Unknown card" faces (one warning each).
static func build(content: ContentIndex, style: CardStyle, rows: Array = []) -> Array[CardFace]:
	if rows.is_empty():
		rows = CardCatalog.cards(content)
	var faces: Array[CardFace] = []
	for row in rows:
		faces.append(face_of(content, style, row))
	return faces


## The face of one catalog row {"id", "kind", "rarity", "setId", "core", "pools"}.
static func face_of(content: ContentIndex, style: CardStyle, row: Dictionary) -> CardFace:
	var face := CardFace.new()
	face.id = str(row.get("id", ""))
	face.rarity = str(row.get("rarity", "common"))
	face.set_id = str(row.get("setId", ""))
	face.core = bool(row.get("core", false))
	for pool in row.get("pools", []):
		face.pools.append(str(pool).trim_prefix(CardCatalog.POOL_PREFIX))
	var id := StringName(face.id)
	var tags: Array[StringName] = []
	if str(row.get("kind", "")) == CardCatalog.KIND_CHARACTER and content.characters.has(id):
		var character: CharacterDefinition = content.characters[id]
		face.kind = CardFace.KIND_CHARACTER
		face.name = _name(character.display_name, face.id)
		face.text = character.description
		face.type_line = "Character — " + _role(character.role)
		tags = character.tags
		face.element = _element(style, face.id, tags, _abilities_tags(character.abilities, null), true)
		face.portrait = style.art_for(id)
		return face
	var entry: Resource = content.items.get(id)
	if entry == null:
		entry = content.equipment.get(id)
	if entry == null:
		face.unknown = true
		face.name = face.id
		face.type_line = UNKNOWN_TYPE
		face.element = style.default_element
		push_warning("CardFaces: the server lists %s, which this content does not have" % face.id)
		return face
	face.name = _name(entry.display_name, face.id)
	face.text = entry.description
	tags = entry.tags
	face.corrupted = TagMatch.has(tags, CORRUPTED_TAG)
	var granted: Array[StringName] = []
	if entry is EquipmentDefinition:
		face.kind = CardFace.KIND_EQUIPMENT
		face.slot = slot_name(entry.slot)
		face.type_line = "Armor — " + (face.slot if face.slot != "" else "Gear")
		granted = _abilities_tags([], entry.grants)
	else:
		face.kind = CardFace.KIND_ITEM
		face.type_line = "Item — " + _item_subtype(entry, face.pools)
		var scenes: Array[PackedScene] = []
		if entry.use_ability != null:
			scenes.append(entry.use_ability)
		granted = _abilities_tags(scenes, entry.grants)
	face.element = _element(style, face.id, tags, granted, false)
	face.icon = style.art_for(id)
	return face


## An armor slot tag's name: its last segment ("Equipment.Slot.Weapon" → "Weapon").
static func slot_name(slot: StringName) -> String:
	var parts := String(slot).split(".", false)
	return parts[-1] if not parts.is_empty() else ""


static func _name(display_name: String, id: String) -> String:
	return display_name if display_name != "" else id


## "Damage dealer: magic" → "Damage dealer"; "Damage dealer / off-tank" → "Damage dealer".
static func _role(role: String) -> String:
	var short := role.get_slice(":", 0).get_slice("/", 0).strip_edges()
	return short if short != "" else "Hero"


static func _item_subtype(item: ItemDefinition, pools: Array[String]) -> String:
	if TagMatch.has_any(item.tags, FOOD_TAGS):
		return "Food"
	if item.kind == ItemDefinition.Kind.USABLE:
		if item.use_mode == ItemDefinition.UseMode.CONSUMABLE:
			return "Consumable"
		var battles := maxi(item.cooldown_battles, 1)
		return "Usable · %d battle%s" % [battles, "" if battles == 1 else "s"]
	return "Passive" + (" · " + pools[0] if not pools.is_empty() else "")


## Spec 3.2: override → rules → (a character) its most common damage type → the default.
static func _element(style: CardStyle, id: String, tags: Array[StringName], granted: Array[StringName], character: bool) -> StringName:
	var override: StringName = style.element_overrides.get(StringName(id), &"")
	if override != &"":
		return override
	for rule in style.element_rules:
		if rule == null or rule.query == null or (character and rule.look_in_abilities):
			continue  # a character's abilities decide by majority below (spec 3.2), not by the first rule that sees one
		var against: Array = tags.duplicate()
		if rule.look_in_abilities:
			against.append_array(granted)
		if TagMatch.matches(rule.query, against) and _names_a_tag(rule.query):
			return rule.element
	if character:
		var counts := {}
		for tag in granted:
			var name := String(tag)
			if name.begins_with(DAMAGE_PREFIX):
				var element := name.trim_prefix(DAMAGE_PREFIX).get_slice(".", 0).to_lower()
				counts[element] = int(counts.get(element, 0)) + 1
		var best := ""
		for element in CHARACTER_ELEMENTS:  # the tie order: the first with the most wins
			if int(counts.get(element, 0)) > int(counts.get(best, 0)):
				best = element
		if best != "":
			return StringName(best)
	return style.default_element


## TagMatch treats an empty query as a match; an element rule must name something to match.
static func _names_a_tag(query: GameplayTagQuery) -> bool:
	var named: Array = []
	named.append_array(query.require_all_tags)
	named.append_array(query.require_any_tags)
	named.append_array(query.require_exact_tags)
	return not named.is_empty()


## The tags inside a card's abilities and effects (Damage.Type.* sits on the effect specs of an ability scene). One entry per
## ability or effect that carries the tag, so a character's count is "how many of its abilities".
static func _abilities_tags(scenes: Array, granted: AbilitySet) -> Array[StringName]:
	var found: Array[StringName] = []
	var all: Array = scenes.duplicate()
	if granted != null:
		all.append_array(granted.abilities)
		found.append_array(granted.tags)
		for effect in granted.effects:
			if effect != null:
				found.append_array(_resource_tags(effect))
	for scene in all:
		if scene != null:
			found.append_array(_resource_tags(scene))
	return found


## Every distinct tag a scene or resource carries anywhere inside it (cached by path).
static func _resource_tags(resource: Resource) -> Array[StringName]:
	var key := resource.resource_path
	if key != "" and _scene_tags.has(key):
		return _scene_tags[key]
	var found: Array[StringName] = []
	var seen := {}
	if resource is PackedScene:
		var state := (resource as PackedScene).get_state()
		for node in state.get_node_count():
			for index in state.get_node_property_count(node):
				_collect(state.get_node_property_value(node, index), found, seen, 0)
	else:
		_collect(resource, found, seen, 0)
	if key != "":
		_scene_tags[key] = found
	return found


static func _collect(value: Variant, found: Array[StringName], seen: Dictionary, depth: int) -> void:
	if depth > 8:
		return
	match typeof(value):
		TYPE_STRING_NAME:
			if String(value).contains(".") and not found.has(value):
				found.append(value)
		TYPE_ARRAY:
			for item in value:
				_collect(item, found, seen, depth + 1)
		TYPE_DICTIONARY:
			for item in value.values():
				_collect(item, found, seen, depth + 1)
		TYPE_OBJECT:
			var resource := value as Resource
			if resource == null or seen.has(resource.get_instance_id()) or resource is Script or resource is PackedScene:
				return
			seen[resource.get_instance_id()] = true
			for property in resource.get_property_list():
				if property["usage"] & PROPERTY_USAGE_STORAGE and property["name"] != "script":
					_collect(resource.get(property["name"]), found, seen, depth + 1)
