## Spec ff7-ui 2.11 / F17: the map's room icons and names, in one place for the minimap, the Tab view, the big map and
## its legend. Keys are MapCells kinds ("boss", "event", special room tag ends such as "Treasure", "Shop", "Altar")
## plus "lock" (keys-and-gear). A kind without an entry shows no icon.
class_name DemoMapIcons
extends RefCounted

const ICONS := {
	"Treasure": preload("res://presentation/demo/ui/icons/map/gift.svg"),
	"Shop": preload("res://presentation/demo/ui/icons/map/dollar.svg"),
	"Altar": preload("res://presentation/demo/ui/icons/map/dollar.svg"),
	"boss": preload("res://presentation/demo/ui/icons/map/skull.svg"),
	"event": preload("res://presentation/demo/ui/icons/map/exclamation.svg"),
	"lock": preload("res://presentation/demo/ui/icons/map/lock.svg"),
}
const NAMES := {"Treasure": "ITEM", "Shop": "SHOP", "Altar": "ALTAR", "boss": "BOSS", "event": "EVENT", "lock": "LOCKED"}
const LONG_NAMES := {"Treasure": "Item room", "Shop": "Shop", "Altar": "Altar", "boss": "Boss room",
	"event": "Event room", "lock": "Locked (needs a key)", "": "Room"}
## The legend lists these, in this order.
const LEGEND: Array[String] = ["Treasure", "Shop", "Altar", "boss", "event", "lock"]


static func icon(kind: String) -> Texture2D:
	return ICONS.get(kind, null)


## A map cell entry item for `cell` (MapCells.of) at `size` px.
static func item(cell: Dictionary, size: float, show_name: bool, action: Callable = Callable(),
		hover: Callable = Callable()) -> Dictionary:
	if not cell["shown"]:
		return {"tile": "empty", "size": size}
	var kind: String = cell["kind"]
	return {"tile": "here" if cell["here"] else ("visited" if cell["visited"] else "unexplored"),
		"icon": null if cell["here"] else icon(kind), "name": NAMES.get(kind, ""), "show_name": show_name,
		"size": size, "action": action, "hover": hover, "disabled": not action.is_valid()}
