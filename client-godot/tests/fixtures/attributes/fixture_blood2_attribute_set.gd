## Frozen test-only AttributeSet for the second-pack item hooks (spec second-pack step 3): FixtureBloodAttributeSet plus the
## Bleed stack, turn and lifesteal bonuses and the overheal shield. Only the binder uses it, so no older golden changes.
class_name FixtureBlood2AttributeSet
extends FixtureBloodAttributeSet

var bleed_stacks: AttributeData = AttributeData.new(0.0)
var bleed_turns: AttributeData = AttributeData.new(0.0)
var bleed_lifesteal: AttributeData = AttributeData.new(0.0)
var overheal_shield: AttributeData = AttributeData.new(0.0)
var shield: AttributeData = AttributeData.new(0.0)


func pre_attribute_change(attribute_name: String, proposed_value: float) -> float:
	match attribute_name:
		"bleed_stacks", "bleed_turns", "bleed_lifesteal", "overheal_shield", "shield":
			return maxf(proposed_value, 0.0)
	return super(attribute_name, proposed_value)
