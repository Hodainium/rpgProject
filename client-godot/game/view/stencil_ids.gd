## The stencil value table (spec vfx-stencil 3.1). One byte per pixel and no masks (K6), so features take ranges, never bit flags.
## Values belong to battle positions, not units: P2 is always 2, enemy slot 3 always 7, so the set of shader copies is fixed (3.4).
## No feature writes a raw number; a change to this table is a spec change. Presentation only.
class_name StencilIds
extends RefCounted

const NONE := 0
## Units, all together (what a reader of "any unit" tests).
const UNIT_FIRST := 1
const UNIT_LAST := 31
## Party positions P1-P4.
const PARTY_FIRST := 1
const PARTY_LAST := 4
## Enemy positions by slot: E1 is 5, E20 is 24.
const ENEMY_FIRST := 5
const ENEMY_LAST := 24
## Units added in the middle of a battle (none in the content today), in the order they arrive.
const ADDED_FIRST := 25
const ADDED_LAST := 31
## Reserved: non-unit objects a later feature must tell apart (silhouettes behind walls).
const MARKED_PROP_FIRST := 32
const MARKED_PROP_LAST := 63
## Reserved: target highlights, if one ever needs its own value.
const TARGET_FIRST := 64
const TARGET_LAST := 127
## Free for slices not planned yet.
const FREE_FIRST := 128
const FREE_LAST := 247
## Reserved: objects that later outlines must skip (Lyra's 123 case: damage numbers, UI in the world).
const OPT_OUT_FIRST := 248
const OPT_OUT_LAST := 254
## The gallery probe only.
const DEV := 255

## Every named range {name: [first, last]}, for the tests and `fx stencil dump`.
const RANGES := {
	"none": [NONE, NONE],
	"party": [PARTY_FIRST, PARTY_LAST],
	"enemy": [ENEMY_FIRST, ENEMY_LAST],
	"added": [ADDED_FIRST, ADDED_LAST],
	"marked_prop": [MARKED_PROP_FIRST, MARKED_PROP_LAST],
	"target": [TARGET_FIRST, TARGET_LAST],
	"free": [FREE_FIRST, FREE_LAST],
	"opt_out": [OPT_OUT_FIRST, OPT_OUT_LAST],
	"dev": [DEV, DEV],
}


## The value of a battle unit's position from its id ("P1" → 1, "E3" → 7), or NONE for an id outside the table (an enemy slot
## above 20, an id of another form). The caller warns once.
static func for_unit_id(unit_id: StringName) -> int:
	var text := String(unit_id)
	if text.length() < 2 or not text.substr(1).is_valid_int():
		return NONE
	var slot := text.substr(1).to_int()
	if text.begins_with("P") and slot >= 1 and slot <= PARTY_LAST - PARTY_FIRST + 1:
		return PARTY_FIRST + slot - 1
	if text.begins_with("E") and slot >= 1 and slot <= ENEMY_LAST - ENEMY_FIRST + 1:
		return ENEMY_FIRST + slot - 1
	return NONE


## The value of the n-th unit added mid-battle (1-based), or NONE past the range.
static func for_added(number: int) -> int:
	return ADDED_FIRST + number - 1 if number >= 1 and number <= ADDED_LAST - ADDED_FIRST + 1 else NONE


static func is_unit(value: int) -> bool:
	return value >= UNIT_FIRST and value <= UNIT_LAST
