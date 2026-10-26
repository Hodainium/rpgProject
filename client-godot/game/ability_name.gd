## The name a player sees for an ability: GodotGAS's `ability_name` when the ability sets one (the inspector field on
## the ability scene), else its scene file's name ("absolute_zero.tscn" → "Absolute Zero"), else the last segment of
## its tag. Presentation only: no rule reads it.
class_name AbilityName
extends RefCounted


static func of(ability: GameplayAbility) -> String:
	if ability == null:
		return "?"
	if ability.ability_name != "":
		return ability.ability_name
	if ability.scene_file_path != "":
		return ability.scene_file_path.get_file().get_basename().capitalize()
	var tag := String(ability.ability_tag)
	return tag.get_slice(".", tag.get_slice_count(".") - 1)


## The name of `unit`'s ability with `tag`, or the tag's last segment when the unit doesn't have it.
static func of_tag(unit: BattleUnit, tag: StringName) -> String:
	var ability := unit.ability_by_tag(tag) if unit != null else null
	if ability != null:
		return of(ability)
	return String(tag).get_slice(".", String(tag).get_slice_count(".") - 1)
