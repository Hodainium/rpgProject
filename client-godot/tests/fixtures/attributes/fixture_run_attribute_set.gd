## Frozen test-only AttributeSet for the run fixtures (spec game-skeleton): FixtureAttributeSet plus mp, max_mp and
## energy (ult charge). The slice 1 fixture units keep FixtureAttributeSet, so their goldens never change.
class_name FixtureRunAttributeSet
extends FixtureAttributeSet

var mp: AttributeData = AttributeData.new(0.0)
var max_mp: AttributeData = AttributeData.new(0.0)
var energy: AttributeData = AttributeData.new(0.0)


func pre_attribute_change(attribute_name: String, proposed_value: float) -> float:
	match attribute_name:
		"mp":
			return clampf(proposed_value, 0.0, max_mp.current_value)
		"energy":
			return clampf(proposed_value, 0.0, 10000.0)
	return super(attribute_name, proposed_value)
