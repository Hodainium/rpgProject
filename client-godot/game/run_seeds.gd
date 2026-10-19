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


## Parses a run seed typed as a decimal string ("" or invalid → -1).
static func parse(seed_text: String) -> int:
	var text := seed_text.strip_edges()
	if text == "" or not text.is_valid_int() or text.begins_with("-") or text.begins_with("+"):
		return -1
	if text.length() > 19 or (text.length() == 19 and text > "9223372036854775807"):
		return -1
	return text.to_int()


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


## A percentage roll: chance_x100 is the typed % × 100 (5.25% = 525).
static func roll(stream: RandomNumberGenerator, chance_x100: int) -> bool:
	return stream.randi_range(0, 9999) < chance_x100
