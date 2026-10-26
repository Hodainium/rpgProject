## An extended class for the attribute module: Unit 
##
## @meta_addon: GodotGAS
## @meta_author: YulRun (https://YulRun.Dev) & 'Your Name Here'
## @meta_license: MIT (Default)

@tool
class_name UnitAttributeSet extends AttributeSet

var hp: AttributeData = AttributeData.new(100000.0)
var max_hp: AttributeData = AttributeData.new(100000.0)
var mp: AttributeData = AttributeData.new(10000.0)
var max_mp: AttributeData = AttributeData.new(10000.0)
var atk: AttributeData = AttributeData.new(50000.0)
var def: AttributeData = AttributeData.new(30000.0)
var spd: AttributeData = AttributeData.new(10000.0)
var crit_rate: AttributeData = AttributeData.new(500.0)
var crit_dmg: AttributeData = AttributeData.new(5000.0)
var energy: AttributeData = AttributeData.new(0.0)
var max_energy: AttributeData = AttributeData.new(10000.0)
var toughness: AttributeData = AttributeData.new(30000.0)
var max_toughness: AttributeData = AttributeData.new(30000.0)
var weakness_dmg: AttributeData = AttributeData.new(15000.0)
var toughness_dmg: AttributeData = AttributeData.new(0.0)
var broken_dmg: AttributeData = AttributeData.new(0.0)
var dmg_mult: AttributeData = AttributeData.new(10000.0)
var dmg_taken: AttributeData = AttributeData.new(10000.0)
var def_pen: AttributeData = AttributeData.new(0.0)
var heal_mult: AttributeData = AttributeData.new(10000.0)
var heal_taken: AttributeData = AttributeData.new(10000.0)
var energy_regen: AttributeData = AttributeData.new(10000.0)
var debuff_turns: AttributeData = AttributeData.new(0.0)
var resist_dmg: AttributeData = AttributeData.new(5000.0)


## The safety pipeline: Clamps stats before they are officially changed.
func pre_attribute_change(attribute_name: String, proposed_value: float) -> float:
	match attribute_name:
		"hp":
			return clamp(proposed_value, 0.0, max_hp.current_value)
		"mp":
			return clamp(proposed_value, 0.0, max_mp.current_value)
		"energy":
			return clamp(proposed_value, 0.0, max_energy.current_value)
		"toughness":
			return clamp(proposed_value, 0.0, max_toughness.current_value)

	return proposed_value


## The reaction pipeline: Handles moving goalposts (e.g. MaxHealth dropping below Health).
func post_attribute_change(asc: Node, attribute_name: String, old_value: float, new_value: float) -> void:
	match attribute_name:
		"max_hp":
			if hp.current_value > new_value:
				asc._apply_attribute_change("hp", new_value - hp.current_value)
		"max_mp":
			if mp.current_value > new_value:
				asc._apply_attribute_change("mp", new_value - mp.current_value)
		"max_energy":
			if energy.current_value > new_value:
				asc._apply_attribute_change("energy", new_value - energy.current_value)
		"max_toughness":
			if toughness.current_value > new_value:
				asc._apply_attribute_change("toughness", new_value - toughness.current_value)
