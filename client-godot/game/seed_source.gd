## Where a run's seeded streams come from (spec server-authority 3.5).
##
## Local mode: every stream derives from the run seed with today's labels ("floor/<n>/<label>", and the run-wide
## "chapter/<id>/bosses" and "chest/<serial>"), so local runs, seeds and goldens are byte-identical to before.
## Server mode: each floor's streams derive from the floor seed the server issued at the stairs ("<label>" under
## floor_seeds[n]); the run-wide streams derive from floor 0's seed under "run/<label>". A modded client therefore
## knows every boss order and chest content from run start: the accepted cheat (spec section 0).
class_name SeedSource
extends RefCounted

var run_seed: int
## Server mode only: floor index → the issued floor seed. Shared with RunState, so seeds added later are seen here.
var floor_seeds: Dictionary


func _init(seed_value: int, issued: Dictionary = {}) -> void:
	run_seed = seed_value
	floor_seeds = issued


static func local(seed_value: int) -> SeedSource:
	return SeedSource.new(seed_value)


## True when the streams come from server-issued floor seeds.
func server_mode() -> bool:
	return not floor_seeds.is_empty()


func has_floor(floor_index: int) -> bool:
	return not server_mode() or floor_seeds.has(floor_index)


## A fresh RNG for one stream of floor `floor_index`; `label` is the part after "floor/<n>/".
func floor_rng(floor_index: int, label: String) -> RandomNumberGenerator:
	if server_mode():
		return RunSeeds.rng(_floor_seed(floor_index), label)
	return RunSeeds.rng(run_seed, "floor/%d/%s" % [floor_index, label])


## A derived seed (battles, field actions) for floor `floor_index`.
func floor_derive(floor_index: int, label: String) -> int:
	if server_mode():
		return RunSeeds.derive(_floor_seed(floor_index), label)
	return RunSeeds.derive(run_seed, "floor/%d/%s" % [floor_index, label])


## A fresh RNG for a run-wide stream (boss rotation, chest contents).
func run_rng(label: String) -> RandomNumberGenerator:
	if server_mode():
		return RunSeeds.rng(_floor_seed(0), "run/" + label)
	return RunSeeds.rng(run_seed, label)


func _floor_seed(floor_index: int) -> int:
	if not floor_seeds.has(floor_index):
		push_error("SeedSource: floor %d has no issued seed" % floor_index)
		return 0
	return int(floor_seeds[floor_index])
