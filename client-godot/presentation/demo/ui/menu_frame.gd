## Spec ff7-ui 2.12 (F15, shared component): the frame every menu screen over the run is built on (Equipment, Armor,
## Use Item, Use Ability, Status, the big map). Back is always at the top left, the description window always at the
## top, the screen's own content below it and the characters (when it has them) at the bottom. Screens are scenes that
## inherit menu_frame.tscn and extend this script; they fill %Content and %Bottom and call describe().
## While one is open the UI state has UI.State.Run.Menu, so the HUD panels it would cover hide.
class_name DemoMenuFrame
extends UIScreen

## Space between the description window and the content below it (spec ui-fixes B1).
@export var content_gap: float = 16.0

@onready var _content_top: float = %Content.offset_top


func _ready() -> void:
	%Description.resized.connect(_keep_content_below)
	%Description.item_rect_changed.connect(_keep_content_below)


## Spec ui-fixes B1: a description taller than its slot pushes the content down instead of being covered.
func _keep_content_below() -> void:
	var bottom: float = %Description.get_global_rect().end.y - get_global_rect().position.y
	%Content.offset_top = maxf(_content_top, bottom + content_gap)


## Shows `info` in the description window (see description_window.gd).
func describe(info: Dictionary) -> void:
	%Description.show_info(info)
