## Spec class-pick 2.4 and D7 (shared component, ff7-ui 2.12): one recommended party on the class pick: its name, a stat on the
## right ("All owned" / "1 not owned" for the developer's list; a win or play rate from later sources) and its members'
## portraits, the ones the account does not own greyed. No description line. Clicking it loads the party (the screen listens to
## `pressed`). set_item({"preset": PartyPreset, "stat": String, "members": [{"id", "name", "portrait", "locked"}]}).
extends Button

@export var all_owned_text: String = "All owned"
@export var not_owned_text: String = "%d not owned"
@export var face_size: Vector2 = Vector2(44, 44)
@export var locked_tint: Color = Color(0.35, 0.35, 0.4, 1.0)

var preset: PartyPreset


func set_item(item: Variant, _context: UIContext) -> void:
	var row: Dictionary = item if item is Dictionary else {}
	preset = row.get("preset")
	%Name.text = preset.display_name if preset != null else ""
	var members: Array = row.get("members", [])
	var locked := members.filter(func(member: Dictionary) -> bool: return bool(member.get("locked", false))).size()
	var stat := str(row.get("stat", ""))
	%Stat.text = stat if stat != "" else (all_owned_text if locked == 0 else not_owned_text % locked)
	%Stat.theme_type_variation = &"Warning" if stat == "" and locked > 0 else &"Muted"
	for child in %Faces.get_children():
		child.queue_free()
	for member: Dictionary in members:
		var face := TextureRect.new()
		face.custom_minimum_size = face_size
		face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		face.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		face.mouse_filter = Control.MOUSE_FILTER_IGNORE
		face.texture = member.get("portrait")
		face.tooltip_text = str(member.get("name", ""))
		if bool(member.get("locked", false)):
			face.modulate = locked_tint
		%Faces.add_child(face)
