## Fixed-point ×100 helpers (spec combat-replay-core, "Number format").
##
## Every number a designer types is stored ×100 as a whole number. Combat math uses only integer + - * /,
## with integer division truncating toward zero. No pow/sqrt/exp/trig: their last digit can differ between
## Windows and Linux, which would reject honest players.
class_name Fixed
extends RefCounted

## 100% in stored form (100 × 100).
const ONE_HUNDRED_PERCENT: int = 10000
## Tolerance for float noise when snapping an aggregated attribute to a whole number.
const SNAP_EPSILON: float = 1e-6


## Converts a typed designer value (up to 2 decimals) to its stored whole number, once, at edit time.
## Exact for anything typed with up to 3 decimals: 0.29 → 29 (never 28), 62.537 → 6253 (3rd decimal dropped).
@warning_ignore("integer_division")
static func from_typed(typed: float) -> int:
	return roundi(typed * 1000.0) / 10


## True when the typed value has more than 2 decimals (the extra digits are dropped by from_typed).
static func has_extra_decimals(typed: float) -> bool:
	return absf(typed * 100.0 - roundf(typed * 100.0)) > SNAP_EPSILON


## Stored whole number → the value a designer sees (for inspectors and presentation only, never for combat math).
static func to_display(stored: int) -> float:
	return stored / 100.0


## Product of two ×100 values: 500.00 × 1.50 → mul(50000, 150) = 75000.
@warning_ignore("integer_division")
static func mul(a: int, b: int) -> int:
	return a * b / 100


## A ×100 value times a stored percentage: pct(50000, 15000) = 75000 (500 × 150%).
@warning_ignore("integer_division")
static func pct(value: int, percent: int) -> int:
	return value * percent / ONE_HUNDRED_PERCENT


## Snaps a float produced by GodotGAS aggregation to a whole number: within SNAP_EPSILON of a whole number →
## that number; otherwise truncate toward zero. Same result on every machine.
static func snap(value: float) -> float:
	var nearest := roundf(value)
	if absf(value - nearest) < SNAP_EPSILON:
		return nearest
	return float(int(value))


## True when a float holds an exact whole number that int64 and JSON can carry (|v| ≤ 2^53).
static func is_whole(value: float) -> bool:
	return value == floorf(value) and absf(value) <= 9007199254740992.0
