## The list of effects the game can play by id (spec vfx-framework 3.2), like GodotGAS's cue registry. One file for the
## game (presentation/demo/fx/fx_registry.tres); tests build their own in memory. A path in `includes` pulls in another
## registry, so a content pack can ship its own effects.
class_name FxRegistry
extends Resource

@export var definitions: Array[FxDefinition] = []
## Other registries (FxRegistry resources). Typed Array[Resource]: Godot 4.7.2 leaks a script at exit that exports an array of
## its own class (see client-godot/CLAUDE.md, the GodotGAS patches).
@export var includes: Array[Resource] = []


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
