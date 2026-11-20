## Spec class-pick 3.2: where a list of recommended parties comes from. This slice ships one source, the developer's list; the
## analytics slice adds sources ranked by win rate and play rate (the class pick shows tabs only when it has more than one).
class_name PartyPresetSource
extends RefCounted


## The list's heading.
func title() -> String:
	return ""


## [{preset: PartyPreset, stat: String}] in display order; `stat` is "" for the developer list ("48% wins" later).
func presets() -> Array:
	return []


## The developer's list, read from a PartyPresetList.
class DeveloperPresets extends PartyPresetSource:
	var list: PartyPresetList
	var heading: String

	func _init(preset_list: PartyPresetList, list_title: String = "Recommended parties") -> void:
		list = preset_list
		heading = list_title

	func title() -> String:
		return heading

	func presets() -> Array:
		var rows: Array = []
		if list != null:
			for preset in list.presets:
				if preset != null:
					rows.append({"preset": preset, "stat": ""})
		return rows
