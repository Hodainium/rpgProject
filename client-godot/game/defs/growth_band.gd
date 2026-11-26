## Spec level-cap 2.2: one stretch of a class's growth (CharacterDefinition.growth_bands). For each level above 1 a battle
## applies the effect of the last band whose `from_level` is at or below that level, so growth can taper without a curve.
## The effect must stack into one active effect (INFINITE, REFRESH_DURATION, no stack limit): its stack count is the
## number of levels inside the band, so a level-50 unit carries one active effect per band, not 49.
@tool
class_name GrowthBand
extends Resource

@export_range(2, 99) var from_level: int = 2
@export var effect: GameplayEffect
