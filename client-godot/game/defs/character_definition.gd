## A playable character (spec game-skeleton, section 3.1). A UnitDefinition, so battles use it directly.
@tool
class_name CharacterDefinition
extends UnitDefinition

@export var portrait: Texture2D
## Shown in the character picker. (Unlocks through gacha come with the hub.)
@export var selectable: bool = true
## (A Birthright-like item is an ItemDefinition whose `character` is this character: it only appears in pools while
## this character is in the party. There is no field here, because two files pointing at each other can't be loaded.)
## Skills this character may learn during a run (and that its loadouts may give). A battle only accepts learned
## skills found here or in the base abilities.
@export var learnable_skills: Array[PackedScene] = []
## Spec playable-demo 3.11 (D28): growth, applied once per level above 1 at battle start and in field mode (it must
## stack: FREE stacking). Empty: levels change nothing in battle.
@export var level_effect: GameplayEffect


## The scene for a learnable or base skill with this ability tag, or null.
func skill_scene(tag: StringName) -> PackedScene:
	for scene in abilities + learnable_skills:
		if scene != null and SkillTags.tag_of(scene) == tag:
			return scene
	return null
