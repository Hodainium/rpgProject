## A GameplayCue that plays its AudioStreamPlayer child. Register the scene by tag in godot_gas/cue_registry.tres and
## list the tag in an effect's application_cue_tags: GodotGAS plays it on the unit the effect lands on, and pools it.
## Presentation only: cues never touch combat state and are left out of the battle state hash.
extends GameplayCueNotify


func play_cue() -> void:
	for child in get_children():
		if child is AudioStreamPlayer:
			child.play()
