## One look of a damage or heal number (Lyra's ULyraDamagePopStyle): when the hit's tags match, these effect parameters apply.
## FxNumberPopCue walks its styles in order and, like Lyra, the FIRST matching style that sets a parameter decides it, so a crit
## style listed before an element style gives the crit's outline and label while the element still gives the colour.
## Presentation only.
class_name FxNumberStyle
extends Resource

## Which hits this style is for: a GodotGAS tag query over the number's tags (the message's Hit.*, Damage.Type.* or Status.*
## tags), evaluated with the query's own rules (a tag matches its children). None = every number.
@export var match: GameplayTagQuery
## Only numbers of this verb (Verb.Damage, Verb.Heal). Empty = any.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var verb: StringName
## Effect parameters this style sets (color, font_size, label, label_color, outline_color, outline_size...).
@export var params: Dictionary = {}
## Put before the number ("+" for a heal). Empty = this style sets no prefix.
@export var prefix: String = ""


func matches(tags: Array, message_verb: StringName) -> bool:
	if verb != &"" and verb != message_verb:
		return false
	return match == null or query_matches(match, tags)


## GameplayTagQuery.matches reads an ability system; this applies the same rules to a plain tag list (a message's tags).
static func query_matches(query: GameplayTagQuery, tags: Array) -> bool:
	for tag in query.ignore_tags:
		if _has(tags, tag):
			return false
	for tag in query.ignore_exact_tags:
		if tags.has(tag):
			return false
	for tag in query.require_all_tags:
		if not _has(tags, tag):
			return false
	for tag in query.require_exact_tags:
		if not tags.has(tag):
			return false
	if not query.require_any_tags.is_empty():
		return query.require_any_tags.any(func(tag) -> bool: return _has(tags, tag))
	return true


## Whether `tags` holds `wanted` or one of its children (GodotGAS's hierarchical has_tag).
static func _has(tags: Array, wanted: StringName) -> bool:
	for tag in tags:
		if tag == wanted or String(tag).begins_with(String(wanted) + "."):
			return true
	return false
