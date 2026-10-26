## Spec ui-framework 3.1 (CommonUI: an activatable widget stack): one layer of the layout. Its screens are its children,
## the last one on top and the only one shown. Fill the screen with it (anchors full rect).
class_name UILayerStack
extends Control

@export_custom(PROPERTY_HINT_NONE, "gas::tag") var layer: StringName = &""
## Back may pop this layer's screens (false for the Game layer: the HUD is never closed by Back).
@export var back_pops: bool = true
## While it holds a screen, input to the layers below is blocked and `dim` is drawn behind it.
@export var blocks_below: bool = false
@export var dim: Color = Color(0, 0, 0, 0)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	child_order_changed.connect(_update_block)


## The top screen, or null.
func top() -> UIScreen:
	var found := screens()
	return found[-1] if not found.is_empty() else null


## The screens bottom to top (not the ones being freed).
func screens() -> Array[UIScreen]:
	var found: Array[UIScreen] = []
	for child in get_children():
		if child is UIScreen and not child.is_queued_for_deletion():
			found.append(child)
	return found


func _update_block() -> void:
	if not is_inside_tree():
		return
	var holding := blocks_below and top() != null
	mouse_filter = Control.MOUSE_FILTER_STOP if holding else Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func _draw() -> void:
	if blocks_below and dim.a > 0.0 and top() != null:
		draw_rect(Rect2(Vector2.ZERO, size), dim)
