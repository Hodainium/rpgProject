## Demo unit (placeholder): a coloured cube. Root of unit_view.tscn: Body (MeshInstance3D), AnimationPlayer, Label (Label3D).
##
## play() runs the ability's own animation on this node: its `execute` keys call execute() here, which releases the
## battle's gate; the animation ending releases the rest. Animations that move `Body` (jump, spin, flash) show as
## authored; ones that don't get a default hop.
extends Node3D

const LIBRARY: StringName = &"abilities"

var _gate: ClientGate
var _color: Color = Color.WHITE
var _dead: bool = false

@onready var _body: MeshInstance3D = $Body
@onready var _player: AnimationPlayer = $AnimationPlayer
@onready var _label: Label3D = $Label


func _ready() -> void:
	_player.animation_finished.connect(_on_finished)
	_player.add_animation_library(LIBRARY, AnimationLibrary.new())


func setup(title: String, color: Color) -> void:
	_color = color
	_label.text = title
	_paint()


func set_stats(text: String) -> void:
	_label.text = text


func set_dead(dead: bool) -> void:
	_dead = dead
	_body.rotation = Vector3(0, 0, PI / 2) if dead else Vector3.ZERO
	_paint()


## Short hit flash when an execution lands on this unit.
func flash() -> void:
	var tween := create_tween()
	tween.tween_property(_body, "scale", Vector3.ONE * 1.25, 0.06)
	tween.tween_property(_body, "scale", Vector3.ONE, 0.12)


func play(ability: BattleAbility, gate: ClientGate) -> void:
	_gate = gate
	var animation := ability.animation
	if animation == null:
		gate.release_finished()
		return
	var library := _player.get_animation_library(LIBRARY)
	var animation_name := StringName(String(ability.ability_tag).replace(".", "_"))
	if not library.has_animation(animation_name):
		library.add_animation(animation_name, animation)
	if not _moves_body(animation):
		var tween := create_tween()
		tween.tween_property(_body, "position:y", 0.8, 0.15)
		tween.tween_property(_body, "position:y", 0.0, 0.15)
	_player.play(String(LIBRARY) + "/" + animation_name)


## Called by the animation's `execute` keys.
func execute(row_id: StringName) -> void:
	if _gate != null:
		_gate.release_execution(row_id)


func _on_finished(_name: StringName) -> void:
	_body.position = Vector3.ZERO
	_body.visible = true
	_body.rotation = Vector3(0, 0, PI / 2) if _dead else Vector3.ZERO
	if _gate != null:
		var gate := _gate
		_gate = null
		gate.release_finished()


func _moves_body(animation: Animation) -> bool:
	for track in animation.get_track_count():
		if String(animation.track_get_path(track)).begins_with("Body"):
			return true
	return false


func _paint() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.35, 0.35, 0.35) if _dead else _color
	_body.material_override = material
