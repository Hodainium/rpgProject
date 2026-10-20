## Builds the dev content (spec dev-tools 3.3) under res://game/dev/content/: the console's effects (kill, heal,
## revive) and the dev stat items (one up and one down per attribute, each an AbilitySet with one infinite modifier of
## one step). System-owned; loaded only while cheats are allowed, and never in an item pool (tag Dev).
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_dev_content.tscn
extends Node

const ROOT := "res://game/dev/content/"
## attribute → one step as typed (stored ×100): HP 100, MP 50, ATK/DEF/SPD 10, crit 5 %, ult charge 10.
const STEPS: Dictionary = {"max_hp": 100, "max_mp": 50, "atk": 10, "def": 10, "spd": 10, "crit_rate": 5,
	"crit_dmg": 5, "max_energy": 10}


func _ready() -> void:
	for directory in ["effects", "items"]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + directory))
	_save("effects/dev_kill", _instant([_override("hp", 0.0)]))
	_save("effects/dev_revive", _instant([_override("hp", 100.0)]))
	_save("effects/dev_heal", _instant([_from_attribute("hp", "max_hp"), _from_attribute("mp", "max_mp")]))
	for attribute_name in STEPS:
		for direction in [["up", 1], ["down", -1]]:
			var effect := GameplayEffect.new()
			effect.policy = GameplayEffect.DurationPolicy.INFINITE
			var modifier := CombatModifier.new()
			modifier.attribute_name = attribute_name
			modifier.operation = GameplayEffectModifier.Operation.ADD
			modifier.value_x100 = Fixed.from_typed(float(STEPS[attribute_name] * direction[1]))
			effect.modifiers.append(modifier)
			var name := "dev_%s_%s" % [direction[0], attribute_name]
			var saved: GameplayEffect = _save("effects/" + name, effect)
			var item := ItemDefinition.new()
			item.id = StringName("dev.%s.%s" % [direction[0], attribute_name])
			item.display_name = "DEV %s%d %s" % ["+" if direction[1] > 0 else "-", STEPS[attribute_name], attribute_name]
			item.tags.assign([&"Dev"])
			item.kind = ItemDefinition.Kind.PASSIVE
			item.applies_to = ItemDefinition.AppliesTo.HOLDER
			item.price = 0
			item.grants = AbilitySet.new()
			item.grants.effects.append(saved)
			_save("items/" + name, item)
	print("Dev content built under ", ROOT)
	get_tree().quit(0)


func _instant(modifiers: Array) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INSTANT
	effect.modifiers.assign(modifiers)
	return effect


func _override(attribute_name: String, value: float) -> GameplayEffectModifier:
	var modifier := GameplayEffectModifier.new()
	modifier.attribute_name = attribute_name
	modifier.operation = GameplayEffectModifier.Operation.OVERRIDE
	modifier.magnitude = value
	return modifier


## `attribute_name` set to the target's own `backing` (e.g. hp ← max_hp).
func _from_attribute(attribute_name: String, backing: String) -> GameplayEffectModifier:
	var modifier := GameplayEffectModifier.new()
	modifier.attribute_name = attribute_name
	modifier.operation = GameplayEffectModifier.Operation.OVERRIDE
	modifier.magnitude_calculation = GameplayEffectModifier.MagnitudeCalculationType.ATTRIBUTE_BASED
	modifier.attribute_source = GameplayEffectModifier.AttributeSource.TARGET
	modifier.backing_attribute_name = backing
	return modifier


func _save(name: String, resource: Resource) -> Resource:
	var path := ROOT + name + ".tres"
	var error := ResourceSaver.save(resource, path)
	if error != OK:
		push_error("build_dev_content: could not save %s (%s)" % [path, error_string(error)])
	return load(path)
