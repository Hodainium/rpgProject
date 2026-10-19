## State hash v1 (spec section 3.3).
extends TestCase


func test_sample_text_hashes_to_committed_value() -> void:
	var text := FileAccess.get_file_as_string(GOLDEN + "hash-v1-sample.txt")
	var expected := FileAccess.get_file_as_string(GOLDEN + "hash-v1-sample.sha256").strip_edges()
	eq(StateHasher.sha256_hex(text), expected, "SHA-256 of the canonical sample (cross-checked with Python hashlib)")


func test_canonical_lines_shape() -> void:
	var battle := new_battle(snapshot("duel", [[1, "striker"]], "7"))
	var lines: PackedStringArray = StateHasher.canonical_lines(battle)["lines"]
	eq(lines[0], "hash-v1", "version line")
	eq(lines[1], "turn=0", "turn line")
	eq(lines[2], "rng=%d" % battle.rng.state, "rng line")
	eq(lines[3], "outcome=Ongoing", "outcome line")
	eq(lines[4], "unit=E1|alive=1|av=11111", "enemies sort before party; SPD 90 -> 111.11 AV")
	check(lines.has("attr=P1|atk|50000|50000"), "attributes stored x100")


func test_same_seed_same_hash_different_seed_different_hash() -> void:
	var a := new_battle(snapshot("duel", [[1, "striker"]], "5"))
	var b := new_battle(snapshot("duel", [[1, "striker"]], "5"))
	var c := new_battle(snapshot("duel", [[1, "striker"]], "6"))
	eq(a.state_hash(), b.state_hash(), "same inputs")
	check(a.state_hash() != c.state_hash(), "the RNG state is part of the hash")


func test_hash_ignores_application_time() -> void:
	var battle := new_battle(snapshot("duel", [[1, "striker"]]))
	var striker := battle.unit_by_id(&"P1")
	var active := striker.asc.apply_gameplay_effect(load(FIXTURES + "effects/guard.tres"))
	var before := battle.state_hash()
	active.spec.application_time += 1234.5
	eq(battle.state_hash(), before, "wall-clock application_time is excluded")


func test_tag_insertion_order_does_not_matter() -> void:
	var a := new_battle(snapshot("duel", [[1, "striker"]]))
	var b := new_battle(snapshot("duel", [[1, "striker"]]))
	a.unit_by_id(&"P1").asc.add_tag(&"Fixture.B")
	a.unit_by_id(&"P1").asc.add_tag(&"Fixture.A")
	b.unit_by_id(&"P1").asc.add_tag(&"Fixture.A")
	b.unit_by_id(&"P1").asc.add_tag(&"Fixture.B")
	eq(a.state_hash(), b.state_hash(), "tags are sorted")


func test_non_integer_attribute() -> void:
	var battle := new_battle(snapshot("duel", [[1, "striker"]]))
	battle.unit_by_id(&"P1").asc.get_attribute("atk").current_value = 50000.5
	var result := StateHasher.compute(battle)
	check(String(result["error"]).begins_with("NonIntegerAttribute"), "fractional attribute is a runner error: " + result["error"])
	eq(result["hash"], "", "no hash for an unhashable state")


func test_anonymous_active_effect() -> void:
	var battle := new_battle(snapshot("duel", [[1, "striker"]]))
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.TURN_BASED
	battle.unit_by_id(&"P1").asc.apply_gameplay_effect(effect)
	check(String(StateHasher.compute(battle)["error"]).begins_with("AnonymousActiveEffect"), "unsaved active effect is a runner error")
