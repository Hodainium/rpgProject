## UIList entry of the title menu: one class with a pick toggle, its role, its kit line and a Details button (a
## UIPushButton set up in the scene; this only passes the class along).
extends VBoxContainer

signal picked_changed

## Abilities whose tag starts with one of these are shared by every class and left out of the kit line.
@export var shared_prefixes: PackedStringArray = ["Ability.Passive.Ultcharge", "Ability.Passive.Break"]

var character_id: String = ""


func _ready() -> void:
	%Pick.toggled.connect(func(_on): picked_changed.emit())


func set_item(character: CharacterDefinition, _ctx: UIContext) -> void:
	character_id = String(character.id)
	var title := character.display_name if character.display_name != "" else character_id
	%Pick.text = "%s  ·  %s" % [title, character.role] if character.role != "" else title
	%Kit.text = "  ·  ".join(kit_lines(character, shared_prefixes))
	%Details.payload = {"character": character.id}
	tooltip_text = character.description


func is_picked() -> bool:
	return %Pick.button_pressed


func set_picked(on: bool) -> void:
	%Pick.set_pressed_no_signal(on)


func set_pickable(on: bool) -> void:
	%Pick.disabled = not on


## ["Skills: Anthem, Discord", "Ult: Finale", "Passive: Encore"] from the ability scenes' root names and tags.
static func kit_lines(character: CharacterDefinition, shared: PackedStringArray) -> PackedStringArray:
	var groups := {"Skills": PackedStringArray(), "Ult": PackedStringArray(), "Passive": PackedStringArray()}
	for scene in character.abilities:
		if scene == null:
			continue
		var tag := String(SkillTags.tag_of(scene))
		if Array(shared).any(func(prefix: String) -> bool: return tag.begins_with(prefix)):
			continue
		var group := "Ult" if tag.begins_with("Ability.Ult.") else "Passive" if tag.begins_with("Ability.Passive.") else "Skills"
		groups[group].append(String(scene.get_state().get_node_name(0)).capitalize())
	# Spec skill-points: the class's level skills in their group, with the level that unlocks them.
	for row in character.level_skills:
		if row == null or row.ability == null:
			continue
		var tag := String(SkillTags.tag_of(row.ability))
		var group := "Ult" if tag.begins_with("Ability.Ult.") else "Passive" if tag.begins_with("Ability.Passive.") else "Skills"
		groups[group].append("%s (Lv %d)" % [String(row.ability.get_state().get_node_name(0)).capitalize(), row.level])
	var lines := PackedStringArray()
	for group in groups:
		if not groups[group].is_empty():
			lines.append("%s: %s" % [group, ", ".join(groups[group])])
	return lines
