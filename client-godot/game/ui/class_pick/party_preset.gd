## Spec class-pick 3.2: one recommended party (design data in a PartyPresetList).
class_name PartyPreset
extends Resource

## Stable id (later analytics join on it).
@export var id: StringName = &""
@export var display_name: String = ""
## Character ids in slot order, 1 to the party size.
@export var members: Array[StringName] = []
