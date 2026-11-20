## Spec class-pick 3.2: checks the recommended parties against the content. Errors: a member the content lacks
## (party_preset_unknown_character), more members than the party holds (party_preset_too_big), a class twice in one preset or
## two presets with one id (party_preset_duplicate), a member that cannot be picked (party_preset_not_selectable).
class_name ClassPickCheck
extends RefCounted

const PRESETS_PATH: String = "res://presentation/demo/ui/class_pick/party_presets.tres"
const SCREEN_PATH: String = "res://presentation/demo/ui/class_pick/class_pick.tscn"


## The presets and the party size the class pick screen itself uses (its exported `presets` and `max_party`, read from the
## scene without instancing it), checked against `content`.
static func validate_screen(content: ContentIndex, scene_path: String = SCREEN_PATH) -> Array[ValidationIssue]:
	if not ResourceLoader.exists(scene_path):
		return []
	var state := (load(scene_path) as PackedScene).get_state()
	var list: PartyPresetList = null
	var max_party := 4
	for index in state.get_node_property_count(0):
		match state.get_node_property_name(0, index):
			&"presets":
				list = state.get_node_property_value(0, index) as PartyPresetList
			&"max_party":
				max_party = int(state.get_node_property_value(0, index))
	return validate(list, content, max_party)


static func validate(list: PartyPresetList, content: ContentIndex, max_party: int = 4) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if list == null:
		return issues
	var path := list.resource_path if list.resource_path != "" else "(presets)"
	var ids := {}
	for index in list.presets.size():
		var preset: PartyPreset = list.presets[index]
		if preset == null:
			continue
		var where := "%s::presets[%d] %s" % [path, index, preset.id]
		if ids.has(preset.id):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "party_preset_duplicate", where,
				"two presets have the id %s" % preset.id))
		ids[preset.id] = true
		if preset.members.size() > max_party:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "party_preset_too_big", where,
				"%d members, the party holds %d" % [preset.members.size(), max_party]))
		var seen := {}
		for member in preset.members:
			if seen.has(member):
				issues.append(ValidationIssue.new(ValidationIssue.ERROR, "party_preset_duplicate", where,
					"%s is in the preset twice" % member))
			seen[member] = true
			var character: CharacterDefinition = content.characters.get(member) if content != null else null
			if character == null:
				issues.append(ValidationIssue.new(ValidationIssue.ERROR, "party_preset_unknown_character", where,
					"no character %s in the content" % member))
			elif not character.selectable:
				issues.append(ValidationIssue.new(ValidationIssue.ERROR, "party_preset_not_selectable", where,
					"%s cannot be picked (selectable is off)" % member))
	return issues
