## Spec ui-framework 2.3: a screen the UI policy pushes onto a layer while the UI state matches `active_when`, and
## removes when it stops matching (Lyra: an experience's "push widget to layer" action).
class_name UIScreenRule
extends Resource

## The screen (its root extends UIScreen).
@export var scene: PackedScene
## The layer stack it goes on (UI.Layer.Game, UI.Layer.GameMenu, UI.Layer.Menu, UI.Layer.Modal).
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var layer: StringName = &"UI.Layer.Menu"
## UI state tags (UI.State.*) it is shown for. Empty: always.
@export var active_when: GameplayTagQuery
## A layer emptied first when this screen is pushed (the run-end screen closes the run menu). Empty: none.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var clears_layer: StringName = &""
