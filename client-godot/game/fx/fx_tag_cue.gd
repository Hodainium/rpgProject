## "While a unit has this gameplay tag, run these cues" as data (spec vfx-content-pass, the battle moments): when the tag is added to a unit's
## ability system the `added_cue` executes once, `present_cue` starts a persistent cue that lasts as long as the tag does, and when the tag is
## removed the persistent cue ends and `removed_cue` executes once. GodotGAS's own `tag_added` / `tag_removed` signals drive it (FxTagCues);
## the unit's State.Broken, State.Downed and State.Dead are loose tags with no effect behind them, so no effect cue could show them.
## Presentation only.
class_name FxTagCue
extends Resource

@export_custom(PROPERTY_HINT_NONE, "gas::tag") var tag: StringName
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var added_cue: StringName
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var present_cue: StringName
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var removed_cue: StringName
