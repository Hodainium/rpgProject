## Spec ui-framework 2.3: a panel the UI policy plugs into every extension point with its slot tag, while the UI state
## matches `active_when` (Lyra: the UI extension subsystem's "add widget to extension point").
class_name UIExtension
extends Resource

## The slot (UI.Slot.*): any UIExtensionPoint with this tag, in the layout or in a pushed screen.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var slot: StringName = &""
## The panel (its root may extend UIScreen to get bind / on_activated; any Control works).
@export var scene: PackedScene
## Position among the slot's panels, lowest first.
@export var order: int = 0
## UI state tags (UI.State.*) it is shown for. Empty: always.
@export var active_when: GameplayTagQuery
