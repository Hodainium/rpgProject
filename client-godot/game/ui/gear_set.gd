## Spec ff7-ui 2.8: one gear screen's configuration (the Equipment and Armor screens are the same screen with two of
## these): its title and its columns.
class_name GearSet
extends Resource

@export var title: String = ""
@export var columns: Array[GearColumn] = []
