## Turn order: HSR-style action value, integers only (spec "Turn order").
extends TestCase


class FakeUnit:
	extends BattleUnit
	var spd: int

	func _init(id: String, unit_side: int, unit_slot: int, unit_spd: int) -> void:
		unit_id = StringName(id)
		set("side", unit_side)  # GDScript treats Side and BattleUnit.Side as different types in a subclass
		slot = unit_slot
		spd = unit_spd

	func stat(attribute_name: String) -> int:
		return spd if attribute_name == BattleUnit.SPD else 0


var _fakes: Array[FakeUnit] = []


func after_each() -> void:
	for fake in _fakes:
		fake.free()
	_fakes.clear()
	super()


func _fake(id: String, unit_side: int, unit_slot: int, unit_spd: int) -> FakeUnit:
	var fake := FakeUnit.new(id, unit_side, unit_slot, unit_spd)
	_fakes.append(fake)
	return fake


func test_full_action_value() -> void:
	eq(TurnManager.full_av(_fake("A", BattleUnit.Side.PARTY, 1, 10000)), 10000, "SPD 100 -> 100.00 AV")
	eq(TurnManager.full_av(_fake("B", BattleUnit.Side.PARTY, 1, 13450)), 7434, "SPD 134.5 -> 74.34 AV")


## Expected order computed independently (Python, same integer rules) for SPD 100 (party) vs SPD 160 (enemy).
func test_sequence_spd_100_vs_160() -> void:
	var a := _fake("A", BattleUnit.Side.PARTY, 1, 10000)
	var b := _fake("B", BattleUnit.Side.ENEMY, 1, 16000)
	var turns := TurnManager.new()
	turns.add(a)
	turns.add(b)
	var order := PackedStringArray()
	for i in 20:
		var actor := turns.next_actor()
		turns.elapse(actor)
		turns.reset(actor)
		order.append(String(actor.unit_id))
	eq("".join(order), "BABBABABBABABBABBABA", "20-turn order")


func test_ties_party_first_then_slot() -> void:
	var enemy := _fake("E1", BattleUnit.Side.ENEMY, 1, 10000)
	var party2 := _fake("P2", BattleUnit.Side.PARTY, 2, 10000)
	var party1 := _fake("P1", BattleUnit.Side.PARTY, 1, 10000)
	var turns := TurnManager.new()
	for unit in [enemy, party2, party1]:
		turns.add(unit)
	eq(String(turns.next_actor().unit_id), "P1", "party before enemy, lower slot first")


func test_spd_change_rescales_remaining_av() -> void:
	var a := _fake("A", BattleUnit.Side.PARTY, 1, 10000)
	var turns := TurnManager.new()
	turns.add(a)
	turns.av[a] = 5000
	turns.on_spd_changed(a, 10000.0, 12000.0)
	eq(turns.av[a], 4166, "5000 * 100 / 120")


func test_removed_unit_never_acts() -> void:
	var a := _fake("A", BattleUnit.Side.PARTY, 1, 10000)
	var b := _fake("B", BattleUnit.Side.ENEMY, 1, 50000)
	var turns := TurnManager.new()
	turns.add(a)
	turns.add(b)
	turns.remove(b)
	for i in 5:
		var actor := turns.next_actor()
		eq(String(actor.unit_id), "A", "only A remains")
		turns.elapse(actor)
		turns.reset(actor)


func test_spd_buff_in_battle_rescales_turn_order() -> void:
	var battle := new_battle(squad_snapshot())
	var poisoner := battle.unit_by_id(&"P4")
	var before: int = battle.turn_manager.av[poisoner]
	poisoner.asc.apply_gameplay_effect(load(FIXTURES + "effects/haste.tres"))
	eq(poisoner.stat(BattleUnit.SPD), 11460, "SPD 95.5 + 20% = 114.6")
	eq(battle.turn_manager.av[poisoner], before * 9550 / 11460, "remaining AV rescaled")
