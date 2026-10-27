## Spec ff7-ui 2.2 (F10, Lyra's accolade definitions): one kind of toast. When a gameplay message arrives on
## `channel` (and passes the verb and tag filters), the host shows a toast built from the three formats.
##
## Format fields, written {name}: {instigator} and {target} (the message's display names, else its ids), {amount}
## (a VerbMessage's magnitude ÷ 100, whole: damage, prices), {count} (the raw magnitude: a floor or level number),
## {verb}, {text} (a NotificationMessage's line) and every key of the message's data ({abilityName}, {chapterName},
## {rarity}, {description}…). A field the message lacks is left empty.
class_name UIToastRule
extends Resource

@export_custom(PROPERTY_HINT_NONE, "gas::tag") var channel: StringName = &""
## PARTIAL also matches the channel's children (Message.Battle hears Message.Battle.Broken).
@export_enum("Exact", "Partial") var match_mode: int = GameplayMessageRouter.Match.EXACT
## Only these verbs (empty: any).
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var verbs: Array[StringName] = []
## The message must carry every one of these tags (e.g. Hit.Critical).
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var require_tags: Array[StringName] = []
## The message must carry none of these tags (e.g. Ability.Type.Ultimate, left to the interrupt rule).
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var ignore_tags: Array[StringName] = []
@export var kicker: String = ""
@export var title: String = ""
@export var subtitle: String = ""
## Real seconds on screen (the battle speed never shortens it).
@export var seconds: float = 2.2
## The toast entry's theme type variation (colour), empty for the entry's default.
@export var variation: StringName = &""
## A SoundBoard cue name to play when it shows, empty for none.
@export var sound: StringName = &""
## When the queue is full, lower priorities are dropped first.
@export var priority: int = 0
## An input action: the toast shows while it is held (from the latest message on the channel) instead of on arrival.
@export var hold_action: StringName = &""

const _FIELD := "\\{([A-Za-z_][A-Za-z0-9_]*)\\}"
## Every field a message on the bus can fill (the validator checks formats against it): the message's own fields, then
## the data keys senders use (BattleMessages, RunController).
const KNOWN_FIELDS: Array[String] = ["instigator", "target", "amount", "count", "verb", "text", "instigatorName",
	"targetName", "abilityName", "chapterName", "rarity", "description", "status", "outcome", "priceItem", "error",
	"sandbox"]

static var _field_regex: RegEx


## True when `message` should make a toast.
func matches(message: GameplayMessage) -> bool:
	var tags: Array = []
	if message is VerbMessage:
		if not verbs.is_empty() and not verbs.has(message.verb):
			return false
		tags = message.tags
	elif message is NotificationMessage:
		tags = message.tags
	elif not verbs.is_empty():
		return false
	for tag in require_tags:
		if not tags.has(tag):
			return false
	for tag in ignore_tags:
		if tags.has(tag):
			return false
	return true


## {"kicker", "title", "subtitle"} for `message`.
func format(message: GameplayMessage) -> Dictionary:
	var fields := UIToastRule.fields_of(message)
	return {"kicker": UIToastRule.fill(kicker, fields), "title": UIToastRule.fill(title, fields),
		"subtitle": UIToastRule.fill(subtitle, fields)}


## The values a format can name for `message`.
static func fields_of(message: GameplayMessage) -> Dictionary:
	var fields := {}
	if message is VerbMessage:
		var data: Dictionary = message.data
		for key in data:
			fields[String(key)] = str(data[key])
		fields["instigator"] = str(data.get("instigatorName", message.instigator))
		fields["target"] = str(data.get("targetName", message.target))
		@warning_ignore("integer_division")
		fields["amount"] = str(message.magnitude / 100)
		fields["count"] = str(message.magnitude)
		fields["verb"] = String(message.verb).trim_prefix("Verb.")
	elif message is NotificationMessage:
		fields["text"] = message.text
	return fields


## `pattern` with each {field} replaced; unknown fields become empty.
static func fill(pattern: String, fields: Dictionary) -> String:
	if pattern == "":
		return ""
	if _field_regex == null:
		_field_regex = RegEx.create_from_string(_FIELD)
	var out := ""
	var at := 0
	for found in _field_regex.search_all(pattern):
		out += pattern.substr(at, found.get_start() - at) + str(fields.get(found.get_string(1), ""))
		at = found.get_end()
	return out + pattern.substr(at)


## The {field} names `pattern` uses (for the validator).
static func field_names(pattern: String) -> PackedStringArray:
	if _field_regex == null:
		_field_regex = RegEx.create_from_string(_FIELD)
	var names := PackedStringArray()
	for found in _field_regex.search_all(pattern):
		names.append(found.get_string(1))
	return names
