## Frozen test-only AttributeSet for the skill-points fixtures (spec skill-points 3.3): FixtureStatusAttributeSet plus
## the SP per basic attack, the SP gain and cost multipliers and the read-only level (D22). Older fixture units keep
## their sets, so their goldens never change.
class_name FixtureSpAttributeSet
extends FixtureStatusAttributeSet

var sp_basic: AttributeData = AttributeData.new(0.0)
var sp_gain: AttributeData = AttributeData.new(10000.0)
var sp_cost: AttributeData = AttributeData.new(10000.0)
var level: AttributeData = AttributeData.new(100.0)


func pre_attribute_change(attribute_name: String, proposed_value: float) -> float:
	match attribute_name:
		"sp_basic", "sp_gain", "sp_cost":
			return maxf(proposed_value, 0.0)
		"level":
			return level.base_value  # read-only: BattleUnit writes it before any effect runs
	return super(attribute_name, proposed_value)
