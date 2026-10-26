## Spec ui-framework 2.3 (Lyra: the UI policy plus an experience's widget actions): everything the game shows, as
## data. A new screen or panel is a scene plus one entry here; GameMain and the other screens never change.
class_name UIPolicy
extends Resource

## The primary layout: a UILayout with one UILayerStack per layer tag.
@export var layout: PackedScene
## Applied to the layout (fonts, colors, type variations such as Caption or RarityEpic).
@export var theme: Theme
## Screens pushed and removed by UI state.
@export var screens: Array[UIScreenRule] = []
## Panels added to and removed from extension slots by UI state.
@export var extensions: Array[UIExtension] = []
## Back (Esc) with nothing to close: the first of these whose state matches is pushed (the run menu on the map).
@export var back_screens: Array[UIScreenRule] = []
## The Modal dialog ctx.ui.confirm() shows (its root extends UIConfirm).
@export var confirm_scene: PackedScene
