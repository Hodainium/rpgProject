## Frozen test-only AttributeSet for the second-pack fixtures (spec second-pack B3-B7): FixtureSpAttributeSet plus the meter
## (B4), the Bleed chance (B6), the lifesteal share (B7) and the low-HP line (B5, 0 = the kernel's 50%). Older fixture units keep
## their sets, so their goldens never change.
class_name FixtureBloodAttributeSet
extends FixtureSpAttributeSet

var meter: AttributeData = AttributeData.new(0.0)
var bleed_chance: AttributeData = AttributeData.new(0.0)
var lifesteal: AttributeData = AttributeData.new(0.0)
var health_low_at: AttributeData = AttributeData.new(0.0)


func pre_attribute_change(attribute_name: String, proposed_value: float) -> float:
	match attribute_name:
		"meter", "bleed_chance", "lifesteal", "health_low_at":
			return maxf(proposed_value, 0.0)
	return super(attribute_name, proposed_value)
