## Spec ui-framework 3.5: checks a UI policy before play. Errors: no layout or a layout whose root isn't a UILayout
## (ui_layout_root), a rule's scene missing (ui_scene_missing), a screen whose root doesn't extend UIScreen
## (ui_screen_not_uiscreen; the confirm scene must extend UIConfirm), a rule on a layer the layout lacks
## (ui_layer_unknown), a panel for a slot no scene of the policy offers (ui_slot_unknown).
class_name UIPolicyCheck
extends RefCounted


static func validate(policy: UIPolicy) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	var path := policy.resource_path if policy != null else "(policy)"
	if policy == null or policy.layout == null:
		issues.append(ValidationIssue.new(ValidationIssue.ERROR, "ui_layout_root", path, "the policy has no layout"))
		return issues
	var layout := policy.layout.instantiate()
	if not layout is UILayout:
		issues.append(ValidationIssue.new(ValidationIssue.ERROR, "ui_layout_root", policy.layout.resource_path,
			"the layout's root must be a UILayout"))
		layout.free()
		return issues
	var layers: Array[StringName] = []
	for stack in layout.stacks():
		layers.append(stack.layer)
	var slots: Dictionary = {}
	_collect_slots(layout, slots)
	layout.free()
	var rules: Array = policy.screens + policy.back_screens
	for index in rules.size():
		var rule: UIScreenRule = rules[index]
		var where := "%s::screens[%d]" % [path, index]
		if rule == null or rule.scene == null:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "ui_scene_missing", where, "a screen rule has no scene"))
			continue
		if not layers.has(rule.layer):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "ui_layer_unknown", where,
				"layer %s is not in the layout (%s)" % [rule.layer, ", ".join(layers)]))
		_check_screen(rule.scene, UIScreen, issues, slots)
	if policy.confirm_scene != null:
		_check_screen(policy.confirm_scene, UIConfirm, issues, slots)
	for index in policy.extensions.size():
		var extension: UIExtension = policy.extensions[index]
		if extension == null or extension.scene == null:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "ui_scene_missing", "%s::extensions[%d]" % [path, index],
				"an extension has no scene"))
			continue
		var node := extension.scene.instantiate()
		_collect_slots(node, slots)
		node.free()
	for index in policy.extensions.size():
		var extension: UIExtension = policy.extensions[index]
		if extension != null and not slots.has(extension.slot):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "ui_slot_unknown", "%s::extensions[%d]" % [path, index],
				"no UIExtensionPoint offers slot %s" % extension.slot))
	return issues


static func _check_screen(scene: PackedScene, base: Script, issues: Array[ValidationIssue], slots: Dictionary) -> void:
	var node := scene.instantiate()
	if not is_instance_of(node, base):
		issues.append(ValidationIssue.new(ValidationIssue.ERROR, "ui_screen_not_uiscreen", scene.resource_path,
			"the root must extend %s" % base.get_global_name()))
	_collect_slots(node, slots)
	node.free()


static func _collect_slots(node: Node, slots: Dictionary) -> void:
	if node is UIExtensionPoint:
		slots[node.slot] = true
	for child in node.get_children():
		_collect_slots(child, slots)
