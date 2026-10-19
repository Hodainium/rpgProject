## Reads the ability tag of a BattleAbility scene, cached per scene (instantiating once, then freeing).
class_name SkillTags
extends RefCounted

static var _cache: Dictionary = {}  # PackedScene -> StringName


static func tag_of(scene: PackedScene) -> StringName:
	if scene == null:
		return &""
	if not _cache.has(scene):
		var ability := scene.instantiate() as BattleAbility
		_cache[scene] = ability.ability_tag if ability != null else &""
		if ability != null:
			ability.free()
	return _cache[scene]
