## Frozen test-only AttributeSet, in the same style the GodotGAS dashboard generates. Values are stored ×100.
## Defaults are irrelevant: units set every stat from UnitDefinition.stats_x100.
class_name FixtureAttributeSet
extends AttributeSet

var hp: AttributeData = AttributeData.new(0.0)
var max_hp: AttributeData = AttributeData.new(0.0)
var atk: AttributeData = AttributeData.new(0.0)
var def: AttributeData = AttributeData.new(0.0)
var spd: AttributeData = AttributeData.new(10000.0)
var crit_rate: AttributeData = AttributeData.new(0.0)
var crit_dmg: AttributeData = AttributeData.new(0.0)


func pre_attribute_change(attribute_name: String, proposed_value: float) -> float:
	match attribute_name:
		"hp":
			return clampf(proposed_value, 0.0, max_hp.current_value)
		"crit_rate":
			return clampf(proposed_value, 0.0, 10000.0)
		"def", "atk", "crit_dmg":
			return maxf(proposed_value, 0.0)
	return proposed_value
