## Number format: typed values with up to 2 decimals are stored ×100 as whole numbers (spec "Number format").
extends TestCase


func test_typed_values_convert_exactly() -> void:
	eq(Fixed.from_typed(0.29), 29, "0.29")
	eq(Fixed.from_typed(80.5), 8050, "80.5")
	eq(Fixed.from_typed(150), 15000, "150")
	eq(Fixed.from_typed(62.537), 6253, "62.537 drops the 3rd decimal")
	eq(Fixed.from_typed(500), 50000, "500")
	eq(Fixed.from_typed(5.25), 525, "5.25")
	eq(Fixed.from_typed(-62.537), -6253, "negative values truncate toward zero")
	check(Fixed.has_extra_decimals(62.537), "62.537 has extra decimals")
	check(not Fixed.has_extra_decimals(5.25), "5.25 has no extra decimals")
	check(not Fixed.has_extra_decimals(0.29), "0.29 has no extra decimals")


func test_integer_math_truncates_toward_zero() -> void:
	eq(Fixed.pct(50000, 15000), 75000, "500 x 150%")
	eq(Fixed.pct(75000, 7693), 57697, "750 x 76.93%")
	eq(Fixed.pct(-75000, 7693), -57697, "negative pct truncates toward zero")
	eq(Fixed.pct(1, 5000), 0, "0.01 x 50%")
	eq(Fixed.mul(50000, 150), 75000, "500.00 x 1.50")
	eq(Fixed.mul(-333, 50), -166, "negative mul truncates toward zero")


func test_snap_handles_float_noise() -> void:
	eq(Fixed.snap(9999.9999999), 10000.0, "noise just below a whole number")
	eq(Fixed.snap(10000.0000001), 10000.0, "noise just above a whole number")
	eq(Fixed.snap(6666.6), 6666.0, "real fraction truncates")
	eq(Fixed.snap(-6666.6), -6666.0, "negative real fraction truncates toward zero")
	check(Fixed.is_whole(10000.0) and not Fixed.is_whole(0.5), "is_whole")


func test_execution_row_authoring_saves_x100() -> void:
	var row := ExecutionRow.new()
	row.multiplier = 150
	row.flat_damage = 80.5
	eq(row.multiplier_x100, 15000, "multiplier stored")
	eq(row.flat_damage_x100, 8050, "flat damage stored")
	eq(row.multiplier, 150.0, "multiplier shown as typed")
	eq(row.flat_damage, 80.5, "flat damage shown as typed")


func test_combat_modifier_magnitudes() -> void:
	var percent := CombatModifier.new()
	percent.operation = GameplayEffectModifier.Operation.PERCENT_ADD
	percent.value = 20
	eq(percent.value_x100, 2000, "20% stored")
	eq(percent.calculate_magnitude(), 0.2, "PERCENT_ADD becomes GodotGAS's fraction")
	var add := CombatModifier.new()
	add.operation = GameplayEffectModifier.Operation.ADD
	add.value = 50
	eq(add.calculate_magnitude(), 5000.0, "ADD matches attributes stored x100")
	var multiply := CombatModifier.new()
	multiply.operation = GameplayEffectModifier.Operation.MULTIPLY
	multiply.value = 1.5
	eq(multiply.calculate_magnitude(), 1.5, "MULTIPLY is a factor")


func test_unit_definition_stats_save_x100() -> void:
	var unit := UnitDefinition.new()
	unit.stats = {"ATK": 500.0, "CritRate": 5.25}
	eq(unit.stats_x100["ATK"], 50000, "ATK stored")
	eq(unit.stats_x100["CritRate"], 525, "CritRate stored")
	eq(unit.stats["CritRate"], 5.25, "CritRate shown as typed")
