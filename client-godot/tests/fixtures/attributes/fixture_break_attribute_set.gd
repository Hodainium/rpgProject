## Frozen test-only AttributeSet for the item-pass fixtures (spec item-pass 3.3): FixtureRunAttributeSet plus
## toughness, weakness damage taken and the two attacker bonuses. Older fixture units keep their sets, so their goldens
## never change.
class_name FixtureBreakAttributeSet
extends FixtureRunAttributeSet

var toughness: AttributeData = AttributeData.new(0.0)
var max_toughness: AttributeData = AttributeData.new(0.0)
var weakness_dmg: AttributeData = AttributeData.new(15000.0)
var toughness_dmg: AttributeData = AttributeData.new(0.0)
var broken_dmg: AttributeData = AttributeData.new(0.0)


func pre_attribute_change(attribute_name: String, proposed_value: float) -> float:
	match attribute_name:
		"toughness":
			return clampf(proposed_value, 0.0, max_toughness.current_value)
		"max_toughness", "weakness_dmg", "toughness_dmg", "broken_dmg":
			return maxf(proposed_value, 0.0)
	return super(attribute_name, proposed_value)
