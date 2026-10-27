## Spec ff7-ui 2.12 (F15, shared component): the frame every menu screen over the run is built on (Equipment, Armor,
## Use Item, Use Ability, Status, the big map). Back is always at the top left, the description window always at the
## top, the screen's own content below it and the characters (when it has them) at the bottom. Screens are scenes that
## inherit menu_frame.tscn and extend this script; they fill %Content and %Bottom and call describe().
## While one is open the UI state has UI.State.Run.Menu, so the HUD panels it would cover hide.
class_name DemoMenuFrame
extends UIScreen


## Shows `info` in the description window (see description_window.gd).
func describe(info: Dictionary) -> void:
	%Description.show_info(info)
