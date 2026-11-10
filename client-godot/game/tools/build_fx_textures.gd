## Generates the flipbook sprite sheets of the content-pass effects (spec vfx-content-pass 3.5) as PNGs in
## presentation/demo/fx/textures/: our own procedural art (noise and simple shapes written here), so no third-party
## licence applies. The sheets are near-white with their shape in the alpha, so a particle's `color` tints them: one flame
## sheet serves orange, green or blue fire. Never overwrites an existing file (like the other builders); `--force` rewrites.
##   godot --headless --path client-godot --quit-after 3000 res://game/tools/build_fx_textures.tscn [-- --force]
extends Node

const OUT: String = "res://presentation/demo/fx/textures/"
const CELL: int = 128

var _force: bool = false


func _ready() -> void:
	_force = OS.get_cmdline_user_args().has("--force")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_sheet("flame_sheet", 8, 4, _flame)
	_sheet("smoke_sheet", 4, 4, _smoke)
	_sheet("fireball_sheet", 8, 4, _fireball)
	_sheet("shard_sheet", 4, 2, _shard)
	_sheet("bubble_sheet", 4, 1, _bubble)
	_sheet_rgba("star_sheet", 1, 1, _star)
	_sheet_rgba("arrow_sheet", 1, 1, _arrow_solid)
	_sheet_rgba("coin_sheet", 1, 1, _coin)
	_sheet("feather_sheet", 1, 1, _feather)
	_sheet("note_sheet", 1, 1, _note)
	get_tree().quit()


## Renders columns x rows frames; `painter(u, v, t, frame) -> float 0..1` gives the intensity at a pixel: u -1..1 across,
## v 0..1 from the bottom, t 0..1 through the animation.
func _sheet(file: String, columns: int, rows: int, painter: Callable) -> void:
	var path := OUT + file + ".png"
	if FileAccess.file_exists(path) and not _force:
		print("kept  ", path)
		return
	var image := Image.create(columns * CELL, rows * CELL, false, Image.FORMAT_RGBA8)
	var frames := columns * rows
	for frame in frames:
		var origin := Vector2i((frame % columns) * CELL, (frame / columns) * CELL)
		var t := float(frame) / float(maxi(frames - 1, 1))
		for py in CELL:
			for px in CELL:
				var u := (float(px) + 0.5) / CELL * 2.0 - 1.0
				var v := 1.0 - (float(py) + 0.5) / CELL
				var value: float = clampf(painter.call(u, v, t, frame), 0.0, 1.0)
				# Hot core is white, the rim keeps the tint: brightness follows the value, alpha its square root.
				var shade := 0.55 + 0.45 * value
				image.set_pixel(origin.x + px, origin.y + py, Color(shade, shade, shade, sqrt(value)))
	var error := image.save_png(ProjectSettings.globalize_path(path))
	print("wrote " if error == OK else "FAILED ", path)


var _noise: FastNoiseLite


func _fbm(x: float, y: float, z: float) -> float:
	if _noise == null:
		_noise = FastNoiseLite.new()
		_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_noise.seed = 7
		_noise.frequency = 1.0
	return (_noise.get_noise_3d(x, y, z) * 0.6 + _noise.get_noise_3d(x * 2.1, y * 2.1, z * 1.3) * 0.3
		+ _noise.get_noise_3d(x * 4.3, y * 4.3, z) * 0.1) * 0.5 + 0.5


## A flame licking upwards: a tapering body whose edge is eaten by noise scrolling up, rising and fading over the sheet.
func _flame(u: float, v: float, t: float, _frame: int) -> float:
	# Density is highest low and in the middle; scrolling noise tears it into tongues, and a threshold cuts them out.
	var n := _fbm(u * 2.4, v * 2.8 - t * 3.2, t * 1.7)
	var n2 := _fbm(u * 5.0 + 9.0, v * 5.5 - t * 5.0, t * 2.3)
	var width := lerpf(0.7, 0.12, pow(v, 0.8))
	var core := (1.0 - clampf(absf(u) / maxf(width, 0.01), 0.0, 1.0)) * (1.0 - v * 0.95)
	var density := core + (n - 0.5) * 1.15 + (n2 - 0.5) * 0.45 - 0.05 - t * 0.12
	var tongue := smoothstep(0.12, 0.5, density)
	var base := smoothstep(0.0, 0.08, v)
	var life := 0.45 + 0.55 * pow(sin(PI * clampf(t * 0.9 + 0.05, 0.0, 1.0)), 0.6)
	# Hotter (brighter) toward the dense middle, so the tint ramps from a white core to a coloured rim.
	return tongue * base * life * clampf(0.5 + density, 0.0, 1.0)


## A soft billow of smoke that swells and thins out.
func _smoke(u: float, v: float, t: float, _frame: int) -> float:
	var radius := lerpf(0.35, 0.85, sqrt(t))
	var d := Vector2(u, v * 2.0 - 1.0).length() / radius
	var n := _fbm(u * 1.6 + 3.0, v * 1.6, t * 1.2)
	var body := 1.0 - smoothstep(0.35 + n * 0.25, 1.0, d)
	return body * (1.0 - t * 0.85) * (0.6 + 0.6 * n)


## A fireball: a bright core that blows outward with a ragged edge, then thins.
func _fireball(u: float, v: float, t: float, _frame: int) -> float:
	var d := Vector2(u, v * 2.0 - 1.0).length()
	var radius := lerpf(0.12, 0.95, pow(clampf(t * 1.25, 0.0, 1.0), 0.5))
	var n := _fbm(u * 2.2 + t, v * 2.2 - t * 1.5, t * 2.0)
	var edge := radius * (0.75 + 0.45 * n)
	var body := 1.0 - smoothstep(edge * 0.4, edge, d)
	var fade := 1.0 - smoothstep(0.55, 1.0, t)
	var core := (1.0 - smoothstep(0.0, edge * 0.7, d)) * (1.0 - t)
	return clampf(body * (0.55 + 0.5 * n) + core * 0.6, 0.0, 1.0) * fade


## One of eight crystal shards (the frame picks the shape): a long hexagon with lit and dark facets.
func _shard(u: float, v: float, _t: float, frame: int) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = 100 + frame
	var angle := rng.randf_range(-0.5, 0.5) + (PI * 0.5)
	var length := rng.randf_range(0.65, 0.9)
	var half_width := rng.randf_range(0.14, 0.26)
	var point := Vector2(u, v * 2.0 - 1.0)
	var axis := Vector2(cos(angle), sin(angle))
	var along := point.dot(axis)
	var across := point.dot(axis.orthogonal())
	var taper := 1.0 - smoothstep(length * 0.3, length, absf(along))
	var inside := absf(across) <= half_width * taper and absf(along) <= length
	if not inside:
		return 0.0
	# Facets: one side bright, the other dark, with a bright spine.
	var facet := 0.55 + 0.45 * signf(across) * 0.8
	var spine := 1.0 - smoothstep(0.0, half_width * 0.25, absf(across))
	return clampf(facet + spine * 0.4, 0.2, 1.0)


## Four bubbles of different size: a faint body, a bright rim and a highlight.
func _bubble(u: float, v: float, _t: float, frame: int) -> float:
	var radius := 0.35 + 0.1 * float(frame)
	var d := Vector2(u, v * 2.0 - 1.0).length()
	var rim := smoothstep(radius - 0.12, radius - 0.02, d) * (1.0 - smoothstep(radius - 0.02, radius, d))
	var body := (1.0 - smoothstep(radius - 0.02, radius, d)) * 0.18
	var highlight := (1.0 - smoothstep(0.0, 0.1, Vector2(u + radius * 0.4, v * 2.0 - 1.0 - radius * 0.45).length())) * 0.9
	return clampf(rim + body + highlight, 0.0, 1.0)


## Like _sheet, but the painter returns the pixel's whole colour (a flat sprite with its own colours, not a tintable glow).
func _sheet_rgba(file: String, columns: int, rows: int, painter: Callable) -> void:
	var path := OUT + file + ".png"
	if FileAccess.file_exists(path) and not _force:
		print("kept  ", path)
		return
	var image := Image.create(columns * CELL, rows * CELL, false, Image.FORMAT_RGBA8)
	for frame in columns * rows:
		var origin := Vector2i((frame % columns) * CELL, (frame / columns) * CELL)
		for py in CELL:
			for px in CELL:
				var u := (float(px) + 0.5) / CELL * 2.0 - 1.0
				var v := 1.0 - (float(py) + 0.5) / CELL
				image.set_pixel(origin.x + px, origin.y + py, painter.call(u, v, frame))
	var error := image.save_png(ProjectSettings.globalize_path(path))
	print("wrote " if error == OK else "FAILED ", path)


## A solid five-point star (Persona's dizzy stars): a bright yellow fill, a thin orange outline and a small white highlight, with
## a hard edge. The sprite carries its own colours, so it is drawn with normal blending and no tint.
func _star(u: float, v: float, _frame: int) -> Color:
	var p := Vector2(u, v * 2.0 - 1.0) * 1.12
	# Fold the point into one of the five sectors and measure its signed distance to that sector's edge: positive outside.
	var sector := TAU / 5.0
	var angle := fposmod(atan2(p.x, p.y) + sector * 0.5, sector) - sector * 0.5
	var radius := p.length()
	var tip := Vector2(0.0, 0.92)
	var notch := Vector2(sin(sector * 0.5), cos(sector * 0.5)) * 0.4
	var q := Vector2(sin(absf(angle)), cos(absf(angle))) * radius
	var edge := (notch - tip)
	var normal := Vector2(edge.y, -edge.x).normalized()
	var distance := -(q - tip).dot(normal)  # the normal points inward, so flip it: positive is outside
	var alpha := 1.0 - smoothstep(-0.012, 0.012, distance)
	if alpha <= 0.0:
		return Color(0, 0, 0, 0)
	var rim := smoothstep(-0.09, -0.04, distance)  # 1 on the outline band, 0 inside
	var fill := Color(1.0, 0.88, 0.2)
	var outline := Color(0.95, 0.5, 0.06)
	var color := fill.lerp(outline, rim)
	var shine := (1.0 - smoothstep(0.0, 0.3, (p - Vector2(-0.16, 0.2)).length())) * 0.55
	color = color.lerp(Color(1, 1, 0.85), shine)
	return Color(color.r, color.g, color.b, alpha)


## A solid block arrow pointing up (a triangular head on a thick, fairly short shaft), flat white so a particle's colour is the arrow's
## colour; stat buffs use it as is and debuffs turn it over.
func _arrow_solid(u: float, v: float, _frame: int) -> Color:
	var y := v * 2.0 - 1.0
	var head_base := 0.12
	var apex := 0.95
	var head_half := 0.85 * clampf((apex - y) / (apex - head_base), 0.0, 1.0)
	var in_head := y >= head_base and y <= apex
	var distance := 1.0
	if in_head:
		distance = (absf(u) - head_half) * 0.78
	elif y >= -0.7 and y < head_base:
		distance = absf(u) - 0.34
	else:
		return Color(0, 0, 0, 0)
	var alpha := 1.0 - smoothstep(-0.012, 0.012, distance)
	# A faint edge shade keeps a flat arrow readable against a bright unit.
	var shade := 1.0 - 0.14 * smoothstep(-0.12, 0.0, distance)
	return Color(shade, shade, shade, alpha)


## A gold coin seen face on: a bright rim, a darker inner ring and a small highlight.
func _coin(u: float, v: float, _frame: int) -> Color:
	var p := Vector2(u, v * 2.0 - 1.0)
	var r := p.length()
	var alpha := 1.0 - smoothstep(0.82, 0.86, r)
	if alpha <= 0.0:
		return Color(0, 0, 0, 0)
	var rim := smoothstep(0.62, 0.7, r)
	var ring := 1.0 - smoothstep(0.0, 0.04, absf(r - 0.5))
	var base := Color(1.0, 0.8, 0.2).lerp(Color(1.0, 0.92, 0.5), rim)
	base = base.lerp(Color(0.78, 0.55, 0.1), ring * 0.6)
	var shine := (1.0 - smoothstep(0.0, 0.25, (p - Vector2(-0.3, 0.3)).length())) * 0.55
	base = base.lerp(Color(1, 1, 0.9), shine)
	return Color(base.r, base.g, base.b, alpha)


## A feather: a long soft leaf shape with a quill down the middle, tintable.
func _feather(u: float, v: float, _t: float, _frame: int) -> float:
	var y := v * 2.0 - 1.0
	var half_width := 0.34 * sin(PI * clampf((y + 1.0) * 0.5, 0.0, 1.0)) * (1.0 - 0.25 * (y + 1.0) * 0.5)
	var curve := 0.12 * y * y
	var d := absf(u - curve)
	var body := 1.0 - smoothstep(half_width * 0.7, half_width, d)
	var quill := 1.0 - smoothstep(0.0, 0.03, d)
	var barbs := 0.75 + 0.25 * sin((y + d * 3.0) * 38.0)
	return clampf(body * barbs + quill * 0.4, 0.0, 1.0)


## A music note: a filled head, a stem and a flag.
func _note(u: float, v: float, _t: float, _frame: int) -> float:
	var p := Vector2(u, v * 2.0 - 1.0)
	var head: float = 1.0 - smoothstep(0.26, 0.3, Vector2((p.x + 0.35) * 1.25, p.y + 0.55).length())
	var stem: float = (1.0 - smoothstep(0.05, 0.08, absf(p.x))) * _step(-0.55, p.y) * _step(p.y, 0.8)
	var flag: float = (1.0 - smoothstep(0.0, 0.07, absf(p.y - (0.75 - p.x * 0.9)))) * _step(0.0, p.x) * _step(p.x, 0.5)
	return clampf(head + stem + flag, 0.0, 1.0)


static func _step(edge: float, x: float) -> float:
	return 1.0 if x >= edge else 0.0
