## Frozen test-only AttributeSet for the content-pass fixtures (spec content-pass 3.2): FixtureBreakAttributeSet plus
## the debuff duration bonus (H8) and the resist multiplier. Older fixture units keep their sets, so their goldens never
## change.
class_name FixtureStatusAttributeSet
extends FixtureBreakAttributeSet

var debuff_turns: AttributeData = AttributeData.new(0.0)
var resist_dmg: AttributeData = AttributeData.new(5000.0)


func pre_attribute_change(attribute_name: String, proposed_value: float) -> float:
	match attribute_name:
		"debuff_turns", "resist_dmg":
			return maxf(proposed_value, 0.0)
	return super(attribute_name, proposed_value)
