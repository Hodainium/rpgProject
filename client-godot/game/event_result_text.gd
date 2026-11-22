## Event results (user, 2026-11-22): the formats of the lines an event's ending page and its fallback dialog list under
## the story ("The party lost 25% HP", "Cleric got Rations", "+2 keys"). Screen texts are exports, not literals in code
## (client-godot/CLAUDE.md section 6): GameMain's `event_result_text` names one; none = these defaults.
@tool
class_name EventResultText
extends Resource

## "%s" the member (or party_name), "%d" the percent.
@export var hp_lost: String = "%s lost %d%% HP"
@export var hp_recovered: String = "%s recovered %d%% HP"
## Used instead of a member's name when every living member changed alike.
@export var party_name: String = "The party"
@export var slain: String = "%s was slain"
@export var revived: String = "%s is back on their feet"
## "%s" the member, "%d" the level.
@export var level_reached: String = "%s reached level %d"
## "%s" the member, "%s" the item.
@export var got_item: String = "%s got %s"
@export var lost_item: String = "%s lost %s"
## "%s" the item and, after it, " x%d" when more than one copy (copies_format).
@export var to_armor: String = "%s (to the armor inventory)"
@export var on_floor: String = "%s lies on the floor"
@export var copies_format: String = " x%d"
@export var chest_appeared: String = "A chest appeared"
## "%+d" the change.
@export var coins: String = "%+d coins"
@export var key: String = "%+d key"
@export var keys: String = "%+d keys"
@export var golden_key: String = "A golden key"
@export var floor_revealed: String = "The floor is revealed"
@export var event_rooms_revealed: String = "The event rooms are revealed"
## Event text (EventText): what {member:n} reads for an empty party place, and a class choice's label ("%s" the badge,
## "%s" the label).
@export var empty_place: String = "an empty place"
@export var badge_format: String = "[%s] %s"


static func defaults() -> EventResultText:
	return EventResultText.new()
