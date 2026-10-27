## Spec keys-and-gear 2.3: a chest (Isaac's brown and golden chests). A drop, not an event: it waits in the party's
## chest inventory until opened on the map. Opening picks one reward by weight (twice with Run.Chest.Double) and runs
## its outcomes, drawing from the chest's own stream "chest/<serial>".
@tool
class_name ChestDefinition
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var icon: Texture2D
## Opening costs a key (a golden key or Run.Chest.NoKey: free).
@export var needs_key: bool = false
@export var rewards: Array[ChestReward] = []
