## Short seed codes (spec dev-tools 3.1): golden vectors, round trips, normalisation, typo refusal, decimals unchanged.
extends TestCase

const GOLDEN_PATH: String = GOLDEN + "game/seed_codes.json"
const VECTORS: Array[int] = [0, 1, 7, 42, 123456789, 34359738367]  # 34359738367 = 2^35 - 1


func test_seed_codes_golden() -> void:
	var cases := {}
	for seed_value in VECTORS:
		cases[str(seed_value)] = RunSeeds.to_code(seed_value)
	var text := WireJson.stringify({"codes": cases})
	if update_goldens:
		var file := FileAccess.open(GOLDEN_PATH, FileAccess.WRITE)
		file.store_string(text)
		file.close()
	eq(text, FileAccess.get_file_as_string(GOLDEN_PATH), "seed codes match their golden")


func test_seed_codes_round_trip() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for index in 1000:
		var seed_value := ((rng.randi() & 0x7) << 32) | rng.randi()
		var code := RunSeeds.to_code(seed_value)
		eq(code.length(), 9, "code for %d is XXXX XXXX" % seed_value)
		eq(RunSeeds.from_code(code), seed_value, "code %s reads back" % code)
		eq(RunSeeds.parse(code), seed_value, "parse() accepts code %s" % code)
	eq(RunSeeds.to_code(-1), "", "no code for a negative seed")
	eq(RunSeeds.to_code(RunSeeds.CODE_LIMIT), "", "no code past 2^35 - 1")


func test_seed_codes_normalisation() -> void:
	var code := RunSeeds.to_code(123456789)
	var seed_value := RunSeeds.from_code(code)
	eq(RunSeeds.from_code(code.to_lower()), seed_value, "lower case")
	eq(RunSeeds.from_code(code.replace(" ", "")), seed_value, "no space")
	eq(RunSeeds.from_code(code.replace(" ", "-")), seed_value, "dash")
	eq(RunSeeds.from_code("  " + code + " "), RunSeeds.parse("  " + code + " "), "parse() trims")
	var zero := RunSeeds.to_code(0)  # "0000 0000"
	eq(RunSeeds.from_code(zero.replace("0", "O")), 0, "O reads as 0")
	var one := RunSeeds.to_code(1)
	eq(RunSeeds.from_code(one.replace("1", "I")), 1, "I reads as 1")
	eq(RunSeeds.from_code(one.replace("1", "L")), 1, "L reads as 1")


func test_seed_codes_refuse_typos() -> void:
	for seed_value in [5, 123456789, 34359738367]:
		var code := RunSeeds.to_code(seed_value).replace(" ", "")
		for position in code.length():
			for character in RunSeeds.CODE_ALPHABET:
				if character == code[position]:
					continue
				var typo := code.substr(0, position) + character + code.substr(position + 1)
				check(RunSeeds.from_code(typo) == -1, "typo %s of %s is refused" % [typo, code])
	eq(RunSeeds.from_code("ABC"), -1, "too short")
	eq(RunSeeds.from_code("ABCD EFGH J"), -1, "too long")
	eq(RunSeeds.from_code("ABCD EFG!"), -1, "outside the alphabet")
	eq(RunSeeds.from_code("UUUU UUUU"), -1, "U is not in the alphabet")


func test_seed_decimals_unchanged() -> void:
	eq(RunSeeds.parse("1"), 1, "decimal 1")
	eq(RunSeeds.parse("12345678"), 12345678, "8 digits stay a decimal, never a code")
	eq(RunSeeds.parse("9223372036854775807"), 9223372036854775807, "int64 max")
	eq(RunSeeds.parse("9223372036854775808"), -1, "past int64")
	eq(RunSeeds.parse("-5"), -1, "negative")
	eq(RunSeeds.parse(""), -1, "empty")
	eq(RunSeeds.display(7), RunSeeds.to_code(7), "display uses the code")
	eq(RunSeeds.display(RunSeeds.CODE_LIMIT), str(RunSeeds.CODE_LIMIT), "display falls back to the decimal")
	check(RunSeeds.from_code(RunSeeds.random_code()) >= 0, "random_code() is a valid code")
