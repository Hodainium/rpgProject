## Spec ff7-ui 2.2: one run toast (an Isaac-style banner): kicker, title, subtitle. Slides in, fades out; real time,
## so the battle speed never changes it. Empty parts are hidden; empty " · " pieces of a line are dropped.
## The title may mark text with [rarity=Rare]…[/rarity]: it takes the theme's Rarity<X> colour ("Ranger got
## [rarity=Rare]Hunter's Gloves[/rarity]!"); an empty or unknown rarity keeps the normal colour.
extends PanelContainer

const RARITY_TAG := "\\[rarity=([A-Za-z]*)\\](.*?)\\[/rarity\\]"

static var _rarity_regex: RegEx

@export var slide_seconds: float = 0.3
@export var slide_distance: float = 40.0
@export var fade_seconds: float = 0.3


func set_item(toast: Dictionary, _context: UIContext) -> void:
	_fill(%Kicker, toast.get("kicker", ""))
	%Title.text = _colour_rarity(str(toast.get("title", "")))
	%Title.visible = %Title.text != ""
	_fill(%Subtitle, toast.get("subtitle", ""))
	if StringName(toast.get("variation", &"")) != &"":
		%Kicker.theme_type_variation = StringName(toast["variation"])
	modulate.a = 0.0
	var tween := create_tween().set_ignore_time_scale(true).set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, slide_seconds)
	tween.tween_property(%Lines, "position:y", 0.0, slide_seconds).from(-slide_distance).set_ease(Tween.EASE_OUT)


func leave() -> void:
	var tween := create_tween().set_ignore_time_scale(true)
	tween.tween_property(self, "modulate:a", 0.0, fade_seconds)
	tween.tween_callback(queue_free)


## [rarity=X]text[/rarity] → [color=<Rarity X colour>]text[/color] (BBCode in the title is escaped first).
func _colour_rarity(text: String) -> String:
	if _rarity_regex == null:
		_rarity_regex = RegEx.create_from_string(RARITY_TAG)
	var out := ""
	var at := 0
	for found in _rarity_regex.search_all(text):
		out += _escape(text.substr(at, found.get_start() - at))
		var variation := StringName("Rarity" + found.get_string(1))
		var inner := _escape(found.get_string(2))
		if found.get_string(1) != "" and has_theme_color("font_color", variation):
			out += "[color=#%s]%s[/color]" % [get_theme_color("font_color", variation).to_html(false), inner]
		else:
			out += inner
		at = found.get_end()
	return out + _escape(text.substr(at))


static func _escape(text: String) -> String:
	return text.replace("[", "[lb]")


func _fill(label: Label, text: String) -> void:
	var parts := Array(text.split(" · ")).map(func(part) -> String: return part.strip_edges())
	label.text = " · ".join(PackedStringArray(parts.filter(func(part) -> bool: return part != "")))
	label.visible = label.text != ""
