## Spec ui-framework 3.5: checks a UI policy before play. Errors: no layout or a layout whose root isn't a UILayout
## (ui_layout_root), a rule's scene missing (ui_scene_missing), a screen whose root doesn't extend UIScreen
## (ui_screen_not_uiscreen; the confirm scene must extend UIConfirm), a rule on a layer the layout lacks
## (ui_layer_unknown), a panel for a slot no scene of the policy offers (ui_slot_unknown). Spec ff7-ui 3.4: a toast
## host's rule on a channel the game never sends (toast_channel_unknown) or naming a field no message carries
## (toast_format_field_unknown); a gear screen column on a slot no run structure lists (gear_slot_unknown, with content).
class_name UIPolicyCheck
extends RefCounted


static func validate(policy: UIPolicy, content: ContentIndex = null) -> Array[ValidationIssue]:
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
		_check_parts(node, extension.scene.resource_path, content, issues)
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


## Toast hosts and gear sets in a panel (its root's exported resources).
static func _check_parts(node: Node, where: String, content: ContentIndex, issues: Array[ValidationIssue]) -> void:
	if node is UIToastHost and node.toast_set != null:
		issues.append_array(check_toasts(node.toast_set, where))
	if content == null:
		return
	var slots: Dictionary = {}
	for structure in content.runs.values():
		for slot in structure.equipment_slots:
			slots[slot] = true
	for property in node.get_property_list():
		var value: Variant = node.get(property["name"])
		if value is GearSet:
			for column in value.columns:
				if column != null and not column.is_use_slot() and not slots.has(column.slot):
					issues.append(ValidationIssue.new(ValidationIssue.ERROR, "gear_slot_unknown", value.resource_path,
						"column %s: no run structure lists %s" % [column.title, column.slot]))


## A toast set's rules: channels the game sends (or a parent of them for PARTIAL rules) and known format fields.
static func check_toasts(toast_set: UIToastSet, where: String) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	for index in toast_set.rules.size():
		var rule: UIToastRule = toast_set.rules[index]
		if rule == null:
			continue
		var at := "%s::rules[%d]" % [toast_set.resource_path if toast_set.resource_path != "" else where, index]
		var known := GameplayMessageRouter.CHANNELS.has(rule.channel) or (rule.match_mode == GameplayMessageRouter.Match.PARTIAL
			and GameplayMessageRouter.CHANNELS.any(func(channel) -> bool:
				return String(channel).begins_with(String(rule.channel) + ".")))
		if not known:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "toast_channel_unknown", at,
				"%s is not a channel the game sends" % rule.channel))
		for pattern in [rule.kicker, rule.title, rule.subtitle]:
			for field in UIToastRule.field_names(pattern):
				if not UIToastRule.KNOWN_FIELDS.has(field):
					issues.append(ValidationIssue.new(ValidationIssue.ERROR, "toast_format_field_unknown", at,
						"{%s} is not a field any message carries (%s)" % [field, ", ".join(UIToastRule.KNOWN_FIELDS)]))
	return issues
