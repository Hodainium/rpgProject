## A class's details, opened from its card in the title menu (a screen pushed on the Menu layer; Back returns to the
## menu as it was): role, description, base stats, the kit one group per line.
extends UIScreen

## The base stats shown, in order, with their labels (attribute keys as in the class's stats).
@export var shown_stats: Dictionary = {"hp": "HP", "mp": "SP", "atk": "ATK", "def": "DEF", "spd": "SPD"}
## Abilities whose tag starts with one of these are shared by every class and left out of the kit.
@export var shared_prefixes: PackedStringArray = ["Ability.Passive.Ultcharge", "Ability.Passive.Break",
	"Ability.Passive.Spgain"]


func on_pushed(payload: Dictionary) -> void:
	var character: CharacterDefinition = ctx.main.content.characters.get(payload.get("character", &"")) \
		if ctx.main.content != null else null
	if character == null:
		%Name.text = "Unknown class"
		return
	%Name.text = character.display_name
	%Role.text = character.role
	%Description.text = character.description
	var stats := PackedStringArray()
	for key in shown_stats:
		if character.stats_x100.has(key):
			stats.append("%s %d" % [shown_stats[key], character.stats_x100[key] / 100])
	%Stats.text = "   ".join(stats)
	%Kit.text = "\n".join(preload("res://presentation/demo/ui/class_card.gd").kit_lines(character, shared_prefixes))
