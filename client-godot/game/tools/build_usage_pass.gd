## Usage pass (spec keys-and-gear 2.6): proposes the Ability.Usage.* asset tags each party ability and use item needs,
## read from what it can do: Battle when it targets enemies, is an ult (ults are cast only at battle ult windows) or
## its activation query forbids State.Infield; Field when its query requires State.Infield; both otherwise. Prints one
## line per ability that lacks its tags ("+Ability.Usage.Battle +Ability.Usage.Field"). Triggered passives need none.
##
## Dry run by default. --write adds the missing tags to each scene's root node `asset_tags` line as a text edit, as the
## role pass does (nothing else in the file changes). Party abilities only; --all: every ability scene under the root.
##   godot --headless --path client-godot --quit-after 3000 res://game/tools/build_usage_pass.tscn
##     [-- --content-root res://content/] [--all] [--write]
## Exit 0.
class_name UsagePass
extends Node


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var root := RolePass._arg(args, "--content-root", "res://content/")
	var content := ContentIndex.new(root)
	var scenes := RolePass.all_scenes(root) if args.has("--all") else RolePass.party_scenes(content)
	var proposals := 0
	var written := 0
	for path in scenes:
		var scene := load(path) as PackedScene
		var ability := scene.instantiate() as BattleAbility if scene != null else null
		if ability == null:
			continue
		if ability.is_triggered() or ability.has_usage_tag():
			ability.free()
			continue
		var tags := usage_of(ability)
		ability.free()
		proposals += 1
		print("%s: %s" % [path, " ".join(tags.map(func(tag) -> String: return "+" + String(tag)))])
		if args.has("--write"):
			var error := RolePass.add_tags(path, tags)
			if error != "":
				print("  not written: ", error)
			else:
				written += 1
	print("usage pass: %d scene(s), %d to tag%s" % [scenes.size(), proposals,
		" (%d written)" % written if args.has("--write") else ""])
	get_tree().quit(0)


## The usage tags `ability` should carry (Battle first).
static func usage_of(ability: BattleAbility) -> Array[StringName]:
	var query := ability.activation_query
	var forbids := query != null and (query.ignore_tags.has(Battle.IN_FIELD_TAG) or query.ignore_exact_tags.has(Battle.IN_FIELD_TAG))
	var requires := query != null and (query.require_all_tags.has(Battle.IN_FIELD_TAG)
		or query.require_any_tags.has(Battle.IN_FIELD_TAG) or query.require_exact_tags.has(Battle.IN_FIELD_TAG))
	if ability.targets_enemies() or ability.is_ultimate() or forbids:
		return [BattleAbility.USAGE_BATTLE_TAG]
	if requires:
		return [BattleAbility.USAGE_FIELD_TAG]
	return [BattleAbility.USAGE_BATTLE_TAG, BattleAbility.USAGE_FIELD_TAG]
