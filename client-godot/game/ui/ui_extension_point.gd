## Spec ui-framework 3.1 (Lyra: a UI extension point): a slot panels plug into from the UI policy. Put this script on
## any container (VBoxContainer, HBoxContainer, MarginContainer…) and pick its slot tag; the container lays the panels
## out, sorted by their UIExtension.order.
class_name UIExtensionPoint
extends Container

@export_custom(PROPERTY_HINT_NONE, "gas::tag") var slot: StringName = &""
