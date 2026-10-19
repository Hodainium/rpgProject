## The demo units' AttributeSet: the generated UnitAttributeSet (godot_gas/attributes/unit_attribute_set.gd, from the
## "Unit" draft) plus the clamps from specs/design/combat-design.md that the generator can't write. The generator
## already clamps hp, mp, energy and toughness to [0, their max_]. Values are x100 (100% = 10000).
class_name DemoUnitAttributes
extends UnitAttributeSet


func pre_attribute_change(attribute_name: String, proposed_value: float) -> float:
	match attribute_name:
		"max_hp", "spd":
			return maxf(proposed_value, 100.0)
		"crit_rate":
			return clampf(proposed_value, 0.0, 10000.0)
		"atk", "def", "crit_dmg", "max_mp":
			return maxf(proposed_value, 0.0)
	return super(attribute_name, proposed_value)
