## Spec class-pick 2.4 (shared component, ff7-ui 2.12): one party slot on the class pick, a portrait slot (D6). A member shows its
## card portrait and name; clicking it removes the member (the screen listens to `pressed`). An empty slot says so and does
## nothing. set_item({"id", "name", "portrait"}) (id &"" = empty).
extends Button

@export var empty_text: String = "Empty"
@export var remove_hint: String = "Remove %s from the party"

var character_id: StringName = &""


func set_item(item: Variant, _context: UIContext) -> void:
	var slot: Dictionary = item if item is Dictionary else {}
	character_id = StringName(slot.get("id", &""))
	var filled := character_id != &""
	%Portrait.texture = slot.get("portrait") if filled else null
	%Portrait.visible = %Portrait.texture != null
	%Name.text = str(slot.get("name", "")) if filled else empty_text
	%Name.theme_type_variation = &"" if filled else &"Muted"
	disabled = not filled
	focus_mode = Control.FOCUS_ALL if filled else Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if filled else Control.CURSOR_ARROW
	tooltip_text = remove_hint % %Name.text if filled else ""
