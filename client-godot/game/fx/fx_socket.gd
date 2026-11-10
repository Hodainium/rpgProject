## A named attachment point on a unit's view (spec vfx-content-pass 3.6). Put one under a view for each role the effects use;
## a view without them gets all four derived from its mesh's bounding box (FxAttach), so markers are optional until a model needs a
## point that is not at the box (a real character's chest, above its head, between its feet).
##   Center  the whole body: auras, whole-body effects
##   Hit     where an impact lands: hits, bursts
##   Top     just above the unit: damage numbers, status icons
##   Base    where it meets the ground: shockwaves, ground fire, summon circles
## Presentation only.
class_name FxSocket
extends Marker3D

const CENTER: StringName = &"Center"
const HIT: StringName = &"Hit"
const TOP: StringName = &"Top"
const BASE: StringName = &"Base"
const ROLES: Array[StringName] = [CENTER, HIT, TOP, BASE]

## Which role this marker is (one of ROLES).
@export var role: StringName = CENTER
