## Spec cube-style 3.1: the game's style as data: each unit's look (by definition id, by tag rule, or the default), each chapter's
## stage mood and the room camera's framings. Lives in presentation/ (presentation/demo/style/style_registry.tres), which is not a
## RulesetVersion root, so tuning it never changes the ruleset. A variant under test (spec cube-style 2) is usually a registry whose
## `base` is the main one and that sets only what it changes; the nearer registry wins (a partial look merges over the base's).
class_name StyleRegistry
extends Resource

## Where this registry's unset fields come from (a round's variant over the main registry); null = none.
@export var base: StyleRegistry
@export var default_look: UnitLook
## Unit definition id -> its look.
@export var looks: Dictionary[StringName, UnitLook] = {}
## First match fills what an exact look leaves unset.
@export var tag_rules: Array[UnitLookRule] = []
## For a chapter with no mood, the sandbox and rooms outside a chapter.
@export var default_mood: StageMood
## Chapter id -> its mood.
@export var moods: Dictionary[StringName, StageMood] = {}
## Null = the base's, else today's camera (CameraFraming.today()); each framing on its own.
@export var explore_camera: CameraFraming
@export var battle_camera: CameraFraming
## Spec cube-style 3.4: how far a unit's attachments turn toward its opponents, in degrees (90 = fully sideways, 45 = a three-quarter
## view toward the camera); negative = unset (the base's, else 90).
@export_range(-1.0, 90.0) var facing_degrees: float = -1.0


## Spec cube-style 3.10: where the party and the enemies stand in a battle; null = the base's, else the rooms' own spawn cells.
@export var party_formation: BattleFormation
@export var enemy_formation: BattleFormation


## The formation of one side through the base chain, or null (the rooms' spawn cells).
func formation(party: bool) -> BattleFormation:
	for registry in chain():
		var found: BattleFormation = registry.party_formation if party else registry.enemy_formation
		if found != null:
			return found
	return null


## The facing turn through the base chain (90 when no registry sets one).
func facing() -> float:
	for registry in chain():
		if registry.facing_degrees >= 0.0:
			return registry.facing_degrees
	return 90.0


## This registry and its bases, nearest first; stops at a loop (the validator reports it as style_base_cycle).
func chain() -> Array[StyleRegistry]:
	var found: Array[StyleRegistry] = []
	var registry := self
	while registry != null and not found.has(registry):
		found.append(registry)
		registry = registry.base
	return found


## The resolved look of `definition` (never null): its exact look, over the first matching tag rule, over the default look.
func look_for(definition: UnitDefinition) -> UnitLook:
	var look := UnitLook.new()
	var exact := _merged(func(r: StyleRegistry) -> UnitLook: return r.looks.get(definition.id) if definition != null else null)
	if exact != null:
		look = exact
	var rule := _rule_at(definition.tags if definition != null else [])
	if not rule.is_empty():
		look = look.merged_over((rule[0] as StyleRegistry).tag_rules[rule[1]].look)
	return look.merged_over(_merged(func(r: StyleRegistry) -> UnitLook: return r.default_look))


## Where `definition`'s look comes from, for the console: "exact", "rule <n>" (0-based, in the registry that holds it) or "default".
func look_source(definition: UnitDefinition) -> String:
	if definition == null:
		return "default"
	if _merged(func(r: StyleRegistry) -> UnitLook: return r.looks.get(definition.id)) != null:
		return "exact"
	var rule := _rule_at(definition.tags)
	return "rule %d" % rule[1] if not rule.is_empty() else "default"


## The mood of `chapter_id`, nearest registry first: its mood for the chapter, else its default mood; null = today's look.
## So a variant's default mood ("one look for every chapter") wins over its base's chapter moods.
func mood_for(chapter_id: StringName) -> StageMood:
	for registry in chain():
		if registry.moods.get(chapter_id) != null:
			return registry.moods[chapter_id]
		if registry.default_mood != null:
			return registry.default_mood
	return null


func explore_framing() -> CameraFraming:
	for registry in chain():
		if registry.explore_camera != null:
			return registry.explore_camera
	return CameraFraming.today()


## Unset along the chain = today's camera (spec cube-style 3.9), not the exploration framing.
func battle_framing() -> CameraFraming:
	for registry in chain():
		if registry.battle_camera != null:
			return registry.battle_camera
	return CameraFraming.today()


## Every chapter id with a mood, through the base chain.
func mood_chapters() -> Array[StringName]:
	var ids: Array[StringName] = []
	for registry in chain():
		for id in registry.moods:
			if not ids.has(id):
				ids.append(id)
	return ids


## Every unit id with an exact look, through the base chain.
func look_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for registry in chain():
		for id in registry.looks:
			if not ids.has(id):
				ids.append(id)
	return ids


## The look `pick` returns from each registry, merged nearest first (each fills only what nearer ones left unset), or null.
func _merged(pick: Callable) -> UnitLook:
	var merged: UnitLook = null
	for registry in chain():
		var look: UnitLook = pick.call(registry)
		if look != null:
			merged = look.merged_over(null) if merged == null else merged.merged_over(look)
	return merged


## [registry, index] of the first tag rule matching `tags`, nearest registry first; [] = none.
func _rule_at(tags: Array) -> Array:
	for registry in chain():
		for i in registry.tag_rules.size():
			var rule := registry.tag_rules[i]
			if rule != null and rule.matches(tags):
				return [registry, i]
	return []
