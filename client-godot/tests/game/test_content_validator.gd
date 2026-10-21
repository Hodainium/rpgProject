## Content validator (spec dev-tools 3.7): fixtures are clean, the broken root reports exactly one finding per file,
## and (content test) the user's res://content/ has no errors.
extends TestCase

const BROKEN: String = "res://tests/broken_fixtures/"
## Every error the broken root must report: [code, file under BROKEN ("" = the root itself)].
const EXPECTED_ERRORS: Array = [
	["content_index", ""], ["missing_id", ""], ["bad_item", "items/bad_item.tres"],
	["reserved_tag", "items/reserved_tag.tres"], ["bad_skill", "characters/bad_skill.tres"],
	["dangling_ref", "encounters/dangling_ref.tres"], ["bad_loadout_ref", "encounters/bad_loadout_ref.tres"],
	["doors_unsatisfiable", "rooms/doors_unsatisfiable.tres"], ["placement_outside", "rooms/placement_outside.tres"],
	["placement_overlap", "rooms/placement_overlap.tres"], ["bad_event", "events/bad_event.tres"],
	["bad_layout", "layouts/bad_layout.tres"], ["empty_query", "chapters/empty_query.tres"],
	["zero_weights", "chapters/zero_weights.tres"], ["generation_fails", "runs/run.tres"],
	["bad_equipment", "equipment/bad_equipment.tres"], ["placement_both", "rooms/placement_both.tres"],
]
const EXPECTED_WARNINGS: Array = [
	["incomplete", "encounters/incomplete.tres"], ["empty_item_pool", "rooms/empty_item_pool.tres"],
	["placement_kind", "rooms/placement_kind.tres"], ["spawn_mismatch", "rooms/spawn_mismatch.tres"],
	["no_description", "items/fallback.tres"], ["trigger_unregistered", "items/trigger_unregistered.tres"],
]


func test_content_validator_fixtures_clean() -> void:
	var issues := ContentValidator.validate(fixtures(), {"generate_seeds": 20})
	var errors := issues.filter(func(issue: ValidationIssue) -> bool: return issue.is_error())
	eq(errors.map(func(issue): return str(issue)), [], "the fixtures have no content errors")


func test_content_validator_broken_root() -> void:
	var issues := ContentValidator.validate(ContentIndex.new(BROKEN), {"generate_seeds": 5})
	var found_errors := {}
	var found_warnings := {}
	for issue in issues:
		var key := "%s|%s" % [issue.code, _file_of(issue.path)]
		if issue.is_error():
			found_errors[key] = true
		else:
			found_warnings[key] = true
	var expected := {}
	for pair in EXPECTED_ERRORS:
		expected["%s|%s" % pair] = true
		check(found_errors.has("%s|%s" % pair), "error %s reported for '%s'" % pair)
	for key in found_errors:
		check(expected.has(key), "no unexpected error: " + key)
	for pair in EXPECTED_WARNINGS:
		check(found_warnings.has("%s|%s" % pair), "warning %s reported for '%s'" % pair)
	check(found_warnings.keys().any(func(key: String) -> bool: return key.begins_with("unknown_tag|")),
		"unregistered tags (Broken.*) are reported as unknown_tag")


func test_content_validator_room_check() -> void:
	var room: RoomDefinition = fixtures().rooms.values()[0].duplicate(true)
	eq(ContentValidator.error_count(ContentValidator.check_room(room, fixtures())), 0, "a fixture room is clean")
	var outside := RoomPlacement.new()
	outside.cell = Vector2i(13, 0)
	room.placements.append(outside)
	var codes := ContentValidator.check_room(room, null).map(func(issue): return issue.code)
	check(codes.has("placement_outside"), "the room check sees a placement outside the grid, without a content index")


## Spec item-pass 3.5: a slot no run structure lists (the fixture run lists its slots), checked without a broken file.
func test_content_validator_equipment_slot() -> void:
	var validator := ContentValidator.new(fixtures())
	var piece := EquipmentDefinition.new()
	piece.id = &"test.equipment.tail"
	piece.description = "A slot nobody offers."
	piece.slot = &"Equipment.Slot.Tail"
	validator._check_equipment(piece)
	eq(validator.issues.map(func(issue): return issue.code), ["bad_equipment_slot"], "an unlisted slot is an error")
	validator.issues.clear()
	var listed: Array = fixtures().runs.values().filter(func(run): return not run.equipment_slots.is_empty())
	piece.slot = listed[0].equipment_slots[0]
	validator._check_equipment(piece)
	eq(validator.issues.size(), 0, "a listed slot is fine")


## Content test (like content goldens): a failure means the content under res://content/ is broken, not the system.
func test_content_valid() -> void:
	if ContentIndex.new("res://content/").runs.is_empty():
		print("    skipped: res://content/ has no run structure")
		return
	var issues := ContentValidator.validate(ContentIndex.new("res://content/"), {"generate_seeds": 20})
	for issue in issues:
		if not issue.is_error():
			print("    [content] ", issue)
	var errors := issues.filter(func(issue: ValidationIssue) -> bool: return issue.is_error())
	eq(errors.map(func(issue): return str(issue)), [], "[content] res://content/ has no content errors")


static func _file_of(path: String) -> String:
	var file := path.get_slice("::", 0)
	return "" if file == BROKEN.trim_suffix("/") else file.trim_prefix(BROKEN)
