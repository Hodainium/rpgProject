## Seeds and RNG streams for a run (spec game-skeleton 3.3).
##
## Every stream is derived from the run seed and a label (e.g. "floor/0/layout"), so the order in which rooms are
## explored never changes another room or a later floor. Only Godot's own String.hash() and RandomNumberGenerator are
## used, which are the same on every platform; a golden vector pins the derivation.
class_name RunSeeds
extends RefCounted


## A non-negative int63 seed for `label` under `parent`.
static func derive(parent: int, label: String) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = parent ^ label.hash()
	return ((rng.randi() & 0x7FFFFFFF) << 32) | rng.randi()


## A fresh RNG for one stream.
static func rng(run_seed: int, label: String) -> RandomNumberGenerator:
	var stream := RandomNumberGenerator.new()
	stream.seed = derive(run_seed, label)
	return stream


## Parses a run seed typed as a decimal string or a seed code ("" or invalid → -1). A string of digits only is always
## a decimal, so every decimal seed keeps its meaning.
static func parse(seed_text: String) -> int:
	var text := seed_text.strip_edges()
	if text != "" and not text.is_valid_int():
		return from_code(text)
	if text == "" or not text.is_valid_int() or text.begins_with("-") or text.begins_with("+"):
		return -1
	if text.length() > 19 or (text.length() == 19 and text > "9223372036854775807"):
		return -1
	return text.to_int()


# --- Seed codes (spec dev-tools 3.1) ---------------------------------------------------------------------------------

## Crockford base32: no I, L, O, U. A code is 7 data characters (a 35-bit seed) plus a Luhn mod 32 check character.
const CODE_ALPHABET: String = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const CODE_DATA_LENGTH: int = 7
const CODE_LIMIT: int = 1 << 35


## "XXXX XXXX" for 0 <= seed < 2^35, else "".
static func to_code(seed_value: int) -> String:
	if seed_value < 0 or seed_value >= CODE_LIMIT:
		return ""
	var digits: Array[int] = []
	var rest := seed_value
	for position in CODE_DATA_LENGTH:
		digits.push_front(rest & 31)
		rest >>= 5
	digits.append(_luhn_check(digits))
	var text := ""
	for digit in digits:
		text += CODE_ALPHABET[digit]
	return text.substr(0, 4) + " " + text.substr(4)


## The seed for a code (case, spaces and "-" ignored; O reads as 0, I and L as 1), or -1.
static func from_code(code_text: String) -> int:
	var text := code_text.to_upper().replace(" ", "").replace("-", "").replace("O", "0").replace("I", "1").replace("L", "1")
	if text.length() != CODE_DATA_LENGTH + 1:
		return -1
	var digits: Array[int] = []
	for character in text:
		var digit := CODE_ALPHABET.find(character)
		if digit < 0:
			return -1
		digits.append(digit)
	if _luhn_check(digits.slice(0, CODE_DATA_LENGTH)) != digits[CODE_DATA_LENGTH]:
		return -1
	var seed_value := 0
	for position in CODE_DATA_LENGTH:
		seed_value = (seed_value << 5) | digits[position]
	return seed_value


## A code for a seed from Godot's global RNG (the menu's Random button; not a seeded draw).
static func random_code() -> String:
	return to_code(((randi() & 0x7) << 32) | randi())


## The code when the seed has one, else the decimal.
static func display(seed_value: int) -> String:
	var code := to_code(seed_value)
	return code if code != "" else str(seed_value)


## Luhn mod 32 check digit for the data digits.
@warning_ignore("integer_division")
static func _luhn_check(digits: Array[int]) -> int:
	var total := 0
	var factor := 2
	for position in range(digits.size() - 1, -1, -1):
		var addend := factor * digits[position]
		factor = 1 if factor == 2 else 2
		total += addend / 32 + addend % 32
	return (32 - total % 32) % 32


## Picks one entry by weight (weight_x100 fields), or null when the list is empty or every weight is 0.
## `entries` must already be in a stable order (sorted by id).
static func pick_weighted(stream: RandomNumberGenerator, entries: Array) -> Variant:
	var total := 0
	for entry in entries:
		total += maxi(int(entry.get("weight_x100")), 0)
	if total <= 0:
		return null
	var roll := stream.randi_range(0, total - 1)
	for entry in entries:
		roll -= maxi(int(entry.get("weight_x100")), 0)
		if roll < 0:
			return entry
	return null


## pick_weighted with weights given apart from the entries (same draw: one randi_range over the total).
static func pick_weighted_by(stream: RandomNumberGenerator, entries: Array, weights: Array[int]) -> Variant:
	var total := 0
	for weight in weights:
		total += maxi(weight, 0)
	if total <= 0:
		return null
	var roll := stream.randi_range(0, total - 1)
	for index in entries.size():
		roll -= maxi(weights[index], 0)
		if roll < 0:
			return entries[index]
	return null


## A percentage roll: chance_x100 is the typed % × 100 (5.25% = 525).
static func roll(stream: RandomNumberGenerator, chance_x100: int) -> bool:
	return stream.randi_range(0, 9999) < chance_x100
