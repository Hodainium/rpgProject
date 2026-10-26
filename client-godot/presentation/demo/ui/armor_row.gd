## UIList entry of the field panel: one armor piece in the bag, a member picker and Equip. Item: {"run", "piece"}.
extends HBoxContainer

## Equip was pressed: "" or why it was refused.
signal equipped(problem: String)

@export var label_format: String = "Armor: %s (%s)"

var _run: RunController
var _piece_id: StringName


func _ready() -> void:
	%Equip.pressed.connect(_equip)


func set_item(item: Dictionary, _ctx: UIContext) -> void:
	_run = item["run"]
	_piece_id = item["piece"]
	var piece: EquipmentDefinition = _run.content.equipment.get(_piece_id)
	%Name.text = label_format % [piece.display_name if piece != null else String(_piece_id),
		String(piece.slot).get_slice(".", 2) if piece != null else "?"]
	%Name.tooltip_text = piece.description if piece != null else ""
	%Member.clear()
	for member in _run.state.party:
		var character: UnitDefinition = _run.content.units.get(member["character"])
		%Member.add_item(character.display_name if character != null else String(member["character"]), member["slot"])


func _equip() -> void:
	equipped.emit(_run.equip(%Member.get_item_id(%Member.selected), _piece_id))
