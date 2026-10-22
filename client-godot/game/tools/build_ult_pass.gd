## One-time builder for the ult-interrupts demo ults (spec ult-interrupts 3.3): Execute (Warrior), Resurrection
## (Cleric) and Quake (Golem), with the effect and animations they need, written into res://content/demo/ through
## ResourceSaver like build_demo.
##
## Same rules as build_demo and build_item_pass, whose helpers it reuses: it never overwrites (an existing file is
## skipped and used) and it writes nowhere but content/demo/. Granting the ults to the Warrior, Cleric and Golem and
## tagging Cleave and Sanctuary are edits to existing files, made by hand with your approval, not here.
## Values are starting values for your tuning, typed as a designer would.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_ult_pass.tscn
extends "res://game/tools/build_item_pass.gd"

const ULTIMATE := [&"Ability.Type.Ultimate"]


func _ready() -> void:
	if not ResourceLoader.exists(GENERATED_SET) or load(PERCENT_OF_MAX) == null:
		_quit("Needs %s and %s (run --import once first)." % [GENERATED_SET, PERCENT_OF_MAX])
		return
	for name in ["damage", "ult_cost"]:
		_r["effects/" + name] = load(CONTENT + "effects/%s.tres" % name)
	_ults()
	print("build_ult_pass: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _made:
		print("  made    ", path)
	for path in _skipped:
		print("  skipped ", path)
	for path in _failed:
		print("  FAILED  ", path)
	get_tree().quit(1 if not _failed.is_empty() else 0)


func _ults() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	var ult := {"cost": "ult_cost", "asset_tags": ULTIMATE}
	_save("effects/resurrection_revive", _percent_of_max(40))  # back with 40% of max HP

	var execute := _row("execute", "damage", D.SCALED, 300, T.ALL, physical)
	execute.toughness_x100 = Fixed.from_typed(120)
	var execute_animation := _jump(1.0)
	_add_spin(execute_animation, 1.0)
	_ability("execute", "Ability.Ult.Execute", B.SINGLE_ENEMY, [execute], execute_animation, [[0.6, "execute"]],
		ult.merged({"sound": ["Attack2", 0.5, 0.0]}))
	_ability("resurrection", "Ability.Ult.Resurrection", B.SINGLE_DEAD_ALLY,
		[_row("raise", "resurrection_revive", D.USE_EFFECT, 0, T.ALL)], _spin(1.0), [[0.6, "raise"]],
		ult.merged({"sound": ["Raise2", 0.2, 0.0]}))
	_ability("quake", "Ability.Ult.Quake", B.ALL_ENEMIES, [_row("quake", "damage", D.SCALED, 150, T.ALL, physical)],
		_jump(1.2), [[0.8, "quake"]], ult.merged({"sound": ["Earth6", 0.7, 0.0]}))
