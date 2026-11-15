## Spec cube-style 3.8: checks a StyleRegistry against the content: looks keyed by unknown units, moods keyed by unknown chapters,
## empty entries, and (a warning) units that get only the default look. Used by validate_content.tscn and the console's `style check`.
class_name StyleValidator
extends RefCounted


## Every registry file under `directory` (a round's variants), sorted.
static func registries_under(directory: String) -> PackedStringArray:
	var found := PackedStringArray()
	if not DirAccess.dir_exists_absolute(directory) and ResourceLoader.list_directory(directory).is_empty():
		return found
	# ContentIndex's walk (it handles an exported build's "x.tres.remap" names).
	for path in ContentIndex._resource_paths(directory.trim_suffix("/")):
		if load(path) is StyleRegistry:
			found.append(path)
	return found


## The problems of one look: an effect that never loops (spec cube-style 3.2), and its attachments: an empty slot or a missing
## shape, an unknown socket, a part that cannot be built.
static func attachment_problems(look: UnitLook, where: String) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if look == null:
		return issues
	if look.effect != null and not look.effect.is_looping():
		issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_effect_not_looping", where + ".effect",
			"%s has no looping layer: it would play once and end" % look.effect.id))
	for i in look.attachments.size():
		var attachment := look.attachments[i]
		var at := "%s.attachments[%d]" % [where, i]
		if attachment == null or attachment.shape == null:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_attachment_shape_missing", at, "an attachment with no shape"))
			continue
		if not attachment.spin_axis.is_zero_approx() and attachment.motion != UnitAttachment.Motion.SPIN:
			issues.append(ValidationIssue.new(ValidationIssue.WARNING, "style_spin_axis_unused", at,
				"spin_axis is set but the motion is not SPIN: nothing turns"))
		if not UnitAttachment.SOCKETS.has(attachment.socket):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_socket_unknown", at,
				"no socket '%s' (%s)" % [attachment.socket, ", ".join(UnitAttachment.SOCKETS)]))
		for p in attachment.shape.parts.size():
			var part := attachment.shape.parts[p]
			var problem := "an empty part slot" if part == null else part.problem()
			if problem != "":
				issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_part_invalid",
					"%s (%s).parts[%d]" % [at, attachment.shape.resource_path, p], problem))
	return issues


## Spec cube-style 6a Set K: the problems of a registry's pickup looks: a look or chest with no shape, a slot key that is no
## Equipment.Slot.* tag, a rarity key that is no Item.Rarity.* tag, a chest look for a chest the content lacks, an effect that never
## loops, a part that cannot be built; and (a warning) a rarity the content uses that has no colour once colours are set.
static func prop_problems(props: PropStyle, content: ContentIndex, where: String) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if props == null:
		return issues
	var looks: Dictionary = {"key": props.key, "armor_default": props.armor_default}
	for slot in props.armor_by_slot:
		looks["armor_by_slot[%s]" % slot] = props.armor_by_slot[slot]
		if not String(slot).begins_with("Equipment.Slot."):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_prop_slot_unknown", "%s.armor_by_slot[%s]" % [where, slot],
				"not an Equipment.Slot.* tag"))
	for field in looks:
		var look: PropLook = looks[field]
		if look == null:
			if field.begins_with("armor_by_slot"):
				issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_prop_shape_missing", "%s.%s" % [where, field], "an empty look"))
			continue
		var at := "%s.%s" % [where, field]
		if look.shape == null:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_prop_shape_missing", at, "a prop look with no shape"))
		issues.append_array(_shape_problems(look.shape, at + ".shape"))
		if look.effect != null and not look.effect.is_looping():
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_effect_not_looping", at + ".effect",
				"%s has no looping layer: it would play once and end" % look.effect.id))
	for rarity in props.rarity_colors:
		if not String(rarity).begins_with("Item.Rarity."):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_prop_rarity_unknown", "%s.rarity_colors[%s]" % [where, rarity],
				"not an Item.Rarity.* tag"))
	if content != null and not props.rarity_colors.is_empty():
		var used: Dictionary = {}
		for id in content.equipment:
			for tag in (content.equipment[id] as EquipmentDefinition).tags:
				if String(tag).begins_with("Item.Rarity.") and not props.rarity_colors.has(StringName(tag)):
					used[tag] = true
		for tag in used:
			issues.append(ValidationIssue.new(ValidationIssue.WARNING, "style_rarity_color_missing", where + ".rarity_colors",
				"rarity %s is used by armor but has no colour" % tag))
	var chests: Dictionary = {"chest_default": props.chest_default}
	for id in props.chests:
		chests["chests[%s]" % id] = props.chests[id]
		if content != null and not content.chests.has(id):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_prop_chest_unknown", "%s.chests[%s]" % [where, id],
				"no chest '%s' in the content" % id))
	for field in chests:
		var chest: ChestLook = chests[field]
		var at := "%s.%s" % [where, field]
		if chest == null:
			if field != "chest_default":
				issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_prop_shape_missing", at, "an empty chest look"))
			continue
		if chest.body == null or chest.lid == null:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_prop_shape_missing", at, "a chest look needs a body and a lid"))
		for part_field in ["body", "lid", "filled_inside", "empty_inside"]:
			issues.append_array(_shape_problems(chest.get(part_field), "%s.%s" % [at, part_field]))
		if chest.filled_effect != null and not chest.filled_effect.is_looping():
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_effect_not_looping", at + ".filled_effect",
				"%s has no looping layer: it would play once and end" % chest.filled_effect.id))
	return issues


static func _shape_problems(shape: AttachmentShape, at: String) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if shape == null:
		return issues
	for p in shape.parts.size():
		var part := shape.parts[p]
		var problem := "an empty part slot" if part == null else part.problem()
		if problem != "":
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_part_invalid", "%s (%s).parts[%d]" % [at, shape.resource_path, p],
				problem))
	return issues


static func validate(registry: StyleRegistry, content: ContentIndex, path: String = "", warn_missing_looks: bool = false) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if registry == null:
		return issues
	var where := path if path != "" else (registry.resource_path if registry.resource_path != "" else "style registry")
	# Only this registry's own entries: a base is validated on its own, so its problems are never reported again per variant.
	var last: StyleRegistry = registry.chain().back()
	if last.base != null:
		issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_base_cycle", where, "the registry's `base` chain loops"))
		return issues
	for id in registry.looks:
		if registry.looks[id] == null:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_look_empty", where + "::looks[%s]" % id, "an empty look"))
		elif content != null and not content.units.has(id):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_look_unknown_unit", where + "::looks[%s]" % id,
				"no unit '%s' in the content" % id))
	for id in registry.moods:
		if registry.moods[id] == null:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_mood_empty", where + "::moods[%s]" % id, "an empty mood"))
		elif content != null and not content.chapters.has(id):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_mood_unknown_chapter", where + "::moods[%s]" % id,
				"no chapter '%s' in the content" % id))
	# Spec cube-style 3.6: the wall blocks' bevel, in every mood the registry owns (the chapters' and the default).
	var owned_moods: Dictionary = {"default_mood": registry.default_mood}
	for id in registry.moods:
		owned_moods["moods[%s]" % id] = registry.moods[id]
	for key in owned_moods:
		var mood: StageMood = owned_moods[key]
		if mood != null and not (is_finite(mood.wall_bevel) and mood.wall_bevel >= 0.0 and mood.wall_bevel <= StageMood.MAX_WALL_BEVEL):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_wall_bevel_invalid", where + "::" + key,
				"wall_bevel %s is outside 0..%s" % [mood.wall_bevel, StageMood.MAX_WALL_BEVEL]))
	for i in registry.tag_rules.size():
		var rule := registry.tag_rules[i]
		if rule == null or rule.query == null or rule.look == null:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_rule_incomplete", where + "::tag_rules[%d]" % i,
				"a rule needs a query and a look"))
	# Spec cube-style 3.3: each look's attachments (the default look, every exact look, every rule's look).
	var owned: Dictionary = {"default_look": registry.default_look}
	for id in registry.looks:
		owned["looks[%s]" % id] = registry.looks[id]
	for i in registry.tag_rules.size():
		if registry.tag_rules[i] != null:
			owned["tag_rules[%d].look" % i] = registry.tag_rules[i].look
	for field in owned:
		issues.append_array(attachment_problems(owned[field], "%s::%s" % [where, field]))
	issues.append_array(prop_problems(registry.props, content, where + "::props"))
	if registry.base != null:
		return issues  # the unit warning belongs to the registry that holds the looks, not to each variant over it
	# Once a registry gives units looks of their own, a character or enemy left on the default look may be forgotten. Only on request
	# (the console's `style check`): during a roll-out most units have no look yet, and validate_content would drown in warnings.
	if warn_missing_looks and content != null and not registry.look_ids().is_empty():
		for id in content.units:
			var unit: UnitDefinition = content.units[id]
			if (content.characters.has(id) or unit is EnemyDefinition) and registry.look_source(unit) == "default":
				issues.append(ValidationIssue.new(ValidationIssue.WARNING, "style_unit_without_look", where,
					"unit '%s' gets only the default look" % id))
	return issues


## Playtest-fixes B23: a skin status's shell (FxFresnelLayer) sits `grow` off every face of the unit; an attachment face at exactly that
## distance from the body is coplanar with it and the two z-fight (the Collector's brim under Ward). Warns for every such face, in every
## look this registry owns. `grows` is FxValidator.skin_grows. Checked: a part's outward face (the one turned away from the body; a
## face turned toward it is never seen) on the Top, Front, Back, Left and Right sockets, for boxes and a cylinder's cap, with the part
## and the attachment turned by whole quarter turns (anything else is not flat against the shell). Not checked (known limits): Center
## and Base, prisms, lathes, tubes and extruded outlines, and the side sockets when the registry turns units by other than whole
## quarter turns (a 45° facing puts their faces at an angle to the shell). Grows set at run time (a payload, a target's tags, a curve
## track on `grow`) are not in `grows` (FxValidator.skin_grows lists only fixed values).
const SKIN_TIE_TOLERANCE: float = 0.0002  # equal depths only: 0.001 apart is cleanly separated at the battle camera
const SOCKET_AXES: Dictionary = {&"Top": Vector3.UP, &"Front": Vector3.BACK, &"Back": Vector3.FORWARD, &"Left": Vector3.RIGHT,
	&"Right": Vector3.LEFT}


static func skin_tie_problems(registry: StyleRegistry, grows: Dictionary, path: String = "") -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if registry == null or grows.is_empty():
		return issues
	var square := is_equal_approx(fmod(registry.facing(), 90.0), 0.0)  # side faces stay flat against the shell only then
	var where := path if path != "" else (registry.resource_path if registry.resource_path != "" else "style registry")
	var owned: Dictionary = {"default_look": registry.default_look}
	for id in registry.looks:
		owned["looks[%s]" % id] = registry.looks[id]
	for i in registry.tag_rules.size():
		if registry.tag_rules[i] != null:
			owned["tag_rules[%d].look" % i] = registry.tag_rules[i].look
	for field in owned:
		var look: UnitLook = owned[field]
		if look == null:
			continue
		for i in look.attachments.size():
			var attachment: UnitAttachment = look.attachments[i]
			if attachment == null or attachment.shape == null or not SOCKET_AXES.has(attachment.socket):
				continue
			if not square and attachment.socket != &"Top":
				continue
			for tie in attachment_skin_ties(attachment, grows):
				issues.append(ValidationIssue.new(ValidationIssue.WARNING, "style_attachment_skin_tie",
					"%s::%s.attachments[%d]" % [where, field, i],
					"%s: part %d ends %s off the body's %s face, where the shell of %s lies (grow %s): they flicker (playtest-fixes B23)"
					% [attachment.shape.resource_path.get_file() if attachment.shape.resource_path != "" else attachment.shape.display_name,
						tie["part"], tie["distance"], attachment.socket, ", ".join(tie["sources"]), tie["grow"]]))
	return issues


## The faces of `attachment` that sit at a skin's grow off the body: [{"part", "distance", "grow", "sources"}].
static func attachment_skin_ties(attachment: UnitAttachment, grows: Dictionary) -> Array[Dictionary]:
	var ties: Array[Dictionary] = []
	var axis: Vector3 = SOCKET_AXES[attachment.socket]
	var pivot := Transform3D(Basis.from_euler(attachment.rotation_degrees * PI / 180.0).scaled(attachment.scale), attachment.offset)
	for index in attachment.shape.parts.size():
		var part := attachment.shape.parts[index]
		if part == null or not part.kind in [AttachmentPart.Kind.BOX, AttachmentPart.Kind.CYLINDER]:
			continue
		var mesh := AttachmentMesh.mesh_for(part)
		if mesh == null:
			continue
		for placed in part.transforms():
			var xform := pivot * placed
			if not _quarter_turns(xform.basis):
				continue
			if part.kind == AttachmentPart.Kind.CYLINDER and absf(xform.basis.y.normalized().dot(axis)) < 0.999:
				continue  # its caps do not face the shell: its round side touches it along a line, never flat
			var box: AABB = xform * mesh.get_aabb()
			# How far the outward face is from the body along the socket's axis (Back and Right point down -Z / -X, where the far face
			# is the box's lowest corner, a negative coordinate made positive by the axis).
			var reach: float = box.end.dot(axis) if axis.dot(Vector3.ONE) > 0.0 else box.position.dot(axis)
			for grow in grows:
				if absf(reach - float(grow)) <= SKIN_TIE_TOLERANCE:
					ties.append({"part": index, "distance": snappedf(reach, 0.0001), "grow": grow, "sources": grows[grow]})
	return ties


## True when every axis of `basis` lies along a world axis (whole quarter turns, any scale), so its flat faces stay axis-aligned.
static func _quarter_turns(basis: Basis) -> bool:
	for column in [basis.x, basis.y, basis.z]:
		var v: Vector3 = column.normalized()
		if absf(absf(v.x) + absf(v.y) + absf(v.z) - 1.0) > 0.001:
			return false
	return true
