## Spec card-ui 2.3: one pack type in the Open packs column: the pack with its count badge ("x 7"), its name, the pity countdowns
## and an Odds button. Clicking the pack (or Enter on it) asks the screen to open one (`open_requested`); Odds shows the odds.
extends VBoxContainer

signal open_requested(pack_id: String, from: Control)
signal odds_requested(entry: Dictionary)

@export var pity_part_text: String = "%s in %d"
@export var pity_tail_text: String = " packs"
@export var odds_text: String = "Odds"
@export var name_size: int = 22

var entry: Dictionary = {}


func _ready() -> void:
	%PackButton.pressed.connect(func(): open_requested.emit(str(entry.get("packId", "")), %Pack))
	%Odds.pressed.connect(func(): odds_requested.emit(entry))
	%Odds.text = odds_text


func set_item(item: Variant, _context: UIContext) -> void:
	entry = item
	var style := CardStyle.current()
	var look := style.pack(str(entry["packId"]))
	%Pack.look = look
	%Pack.name_font = style.name_font
	%Pack.label = look.label if look.label != "" else str(entry["name"])
	%Pack.count = int(entry["count"])
	%Pack.solid = style.pack_choreography().pack_3d   # the 3D foil pack, like the one on the stage (user, 2026-11-18)
	%Name.text = str(entry["name"])
	if style.name_font != null:
		%Name.add_theme_font_override(&"font", style.name_font)
	%Name.add_theme_font_size_override(&"font_size", name_size)
	%Pity.text = OpenPacksModel.pity_line(entry, pity_part_text, pity_tail_text)
	%Pity.visible = %Pity.text != ""
	%Odds.visible = not entry.get("odds", []).is_empty()


## Busy (an open on its way or a reveal on the stage): the pack cannot be pressed.
func set_locked(locked: bool) -> void:
	%PackButton.disabled = locked


func pack_view() -> Control:
	return %Pack
