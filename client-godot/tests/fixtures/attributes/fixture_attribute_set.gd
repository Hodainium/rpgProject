## Frozen test-only AttributeSet, in the same style the GodotGAS dashboard generates. Values are stored ×100.
## Defaults are irrelevant: units set every stat from UnitDefinition.stats_x100.
class_name FixtureAttributeSet
extends AttributeSet

var HP: AttributeData = AttributeData.new(0.0)
var MaxHP: AttributeData = AttributeData.new(0.0)
var ATK: AttributeData = AttributeData.new(0.0)
var DEF: AttributeData = AttributeData.new(0.0)
var SPD: AttributeData = AttributeData.new(10000.0)
var CritRate: AttributeData = AttributeData.new(0.0)
var CritDmg: AttributeData = AttributeData.new(0.0)


func pre_attribute_change(attribute_name: String, proposed_value: float) -> float:
	match attribute_name:
		"HP":
			return clampf(proposed_value, 0.0, MaxHP.current_value)
		"CritRate":
			return clampf(proposed_value, 0.0, 10000.0)
		"DEF", "ATK", "CritDmg":
			return maxf(proposed_value, 0.0)
	return proposed_value
