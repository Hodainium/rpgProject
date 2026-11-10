## The list of effects the game can play by id (spec vfx-framework 3.2), like GodotGAS's cue registry. One file for the
## game (presentation/demo/fx/fx_registry.tres); tests build their own in memory. A path in `includes` pulls in another
## registry, so a content pack can ship its own effects.
class_name FxRegistry
extends Resource

@export var definitions: Array[FxDefinition] = []
## Other registries (FxRegistry resources). Typed Array[Resource]: Godot 4.7.2 leaks a script at exit that exports an array of
## its own class (see client-godot/CLAUDE.md, the GodotGAS patches).
@export var includes: Array[Resource] = []
## Spec vfx-content-pass 2.2: the battle's "when this happens, play that" rule sets (FxRuleSet), attached by the game shell. A rule set
## is a list of FxListeners; typed Array[Resource] for the same reason as `includes`.
@export var rule_sets: Array[Resource] = []
## Spec vfx-content-pass: FxTagCue rules ("while a unit has State.Broken, play this cue"), attached to each battle's units by the game shell.
@export var tag_cues: Array[Resource] = []


## Every tag-cue rule, includes first.
func all_tag_cues() -> Array[FxTagCue]:
	var out: Array[FxTagCue] = []
	for other in includes:
		if other != null:
			out.append_array(other.all_tag_cues())
	for rule in tag_cues:
		if rule is FxTagCue:
			out.append(rule)
	return out


## Every rule set, includes first.
func all_rule_sets() -> Array[FxRuleSet]:
	var out: Array[FxRuleSet] = []
	for other in includes:
		if other != null:
			out.append_array(other.all_rule_sets())
	for rules in rule_sets:
		if rules is FxRuleSet:
			out.append(rules)
	return out


## Every definition, includes first, later ones overriding earlier ones with the same id.
func all() -> Dictionary:
	var out := {}
	for other in includes:
		if other != null:
			out.merge(other.all(), true)
	for definition in definitions:
		if definition != null and definition.id != &"":
			out[definition.id] = definition
	return out


func find(id: StringName) -> FxDefinition:
	return all().get(id)
