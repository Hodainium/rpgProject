## Headless "Generate" (game/tools/generate_attributes.gd): byte for byte what the GodotGAS dashboard wrote for the same
## drafts. The fixture pair is a real draft and the file the dashboard generated from it (GodotGAS v1.1.2).
extends TestCase

const ROOT: String = "res://tests/fixtures/attribute_generator/"
const GENERATOR := preload("res://game/tools/generate_attributes.gd")


func test_attribute_generator_matches_dashboard() -> void:
	var drafts := ConfigFile.new()
	eq(drafts.load(ROOT + "unit_draft.cfg"), OK, "the fixture draft loads")
	var expected := FileAccess.get_file_as_string(ROOT + "unit_attribute_set.expected.txt")
	check(expected != "", "the dashboard's output is there")
	eq(GENERATOR.generate(drafts, "Unit"), expected, "same text as the dashboard's Generate")


func test_attribute_generator_new_attribute() -> void:
	var drafts := ConfigFile.new()
	drafts.set_value("Probe", "_initialized", true)
	drafts.set_value("Probe", "shield", {"value": 0.0, "icon": "Attribute"})
	drafts.set_value("Probe", "max_shield", {"value": 5000.0, "icon": "Attribute"})
	var text := GENERATOR.generate(drafts, "Probe")
	check(text.contains("class_name ProbeAttributeSet extends AttributeSet"), "class named after the set")
	check(text.contains("var max_shield: AttributeData = AttributeData.new(5000.0)"), "default from the draft")
	check(text.contains("return clamp(proposed_value, 0.0, max_shield.current_value)"), "x clamped to max_x")
