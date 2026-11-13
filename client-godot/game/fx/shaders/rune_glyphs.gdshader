shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// Rune glyphs (spec cube-style 3.2, a look's idle effect): a steady ring of glyphs lying on the floor under a unit. Two thin rings hold a
// band of runes (each built from a few strokes picked by a hash, so every rune differs) that turns slowly; each rune glows up and down on
// its own beat, and a faint inner ring of dots turns the other way. It never fades in or out by itself (made to loop forever); only
// `fade` (a stop) takes it away. The Arcanist's idle runes; unlike rune_circle (Sanctuary's burst), it has no envelope.
// @uniform progress   0..1 over the layer (driven; unused: the look does not change over the layer)
// @uniform time       seconds since the layer started (driven): turns the band and beats the runes
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform color      rune colour
// @uniform intensity  brightness
// @uniform spin       turns per second of the rune band (the dots turn the other way)
// @uniform glyphs     number of runes round the band
// @uniform depth_fade world units in front of the scene over which the effect fades out where it passes into it (soft particles), instead of a hard line
// @uniform fx_scene_depth the scene depth buffer, read for the depth fade (filled by the engine)
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec4 color : source_color = vec4(0.65, 0.5, 1.0, 1.0);
uniform float intensity = 1.4;
uniform float spin = 0.03;
uniform float glyphs = 12.0;

#include "res://game/fx/shaders/fx_stencil_depth.gdshaderinc"

float hash11(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

float ring(float r, float centre, float width) {
	return 1.0 - smoothstep(0.0, width, abs(r - centre));
}

// A stroke from a to b in the rune's cell (0..1 square), `w` thick.
float stroke(vec2 q, vec2 a, vec2 b, float w) {
	vec2 pa = q - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return 1.0 - smoothstep(w * 0.5, w, length(pa - ba * h));
}

// Rune `id` at q (its cell, 0..1): a spine plus up to five strokes between points of a 3 x 3 grid, picked by the hash.
float rune(vec2 q, float id) {
	float w = 0.09;
	float shape = stroke(q, vec2(0.5, 0.1), vec2(0.5, 0.9), w) * step(0.35, hash11(id + 0.5));
	for (int i = 0; i < 5; i++) {
		float s = hash11(id * 7.0 + float(i) * 13.0);
		if (s < 0.3) {
			continue;
		}
		float a = floor(hash11(id * 3.0 + float(i)) * 9.0);
		float b = floor(hash11(id * 5.0 + float(i) * 2.0) * 9.0);
		vec2 pa = vec2(mod(a, 3.0), floor(a / 3.0)) * 0.4 + vec2(0.1);
		vec2 pb = vec2(mod(b, 3.0), floor(b / 3.0)) * 0.4 + vec2(0.1);
		if (distance(pa, pb) > 0.01) {
			shape = max(shape, stroke(q, pa, pb, w));
		}
	}
	return shape;
}

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p);
	float angle = atan(p.y, p.x) + 3.14159265;
	float band_turn = fract((angle / 6.2831853) - time * spin);
	float cell = floor(band_turn * glyphs);
	float along = fract(band_turn * glyphs);
	// The rune band between r 0.66 and 0.86; its cell is about square there.
	vec2 q = vec2((along - 0.5) * 1.35 + 0.5, (r - 0.66) / 0.2);
	float inside = step(0.0, q.x) * step(q.x, 1.0) * step(0.0, q.y) * step(q.y, 1.0);
	float beat = 0.55 + 0.45 * sin(time * (1.3 + hash11(cell) * 1.4) + cell * 2.1);
	float runes = rune(q, cell) * inside * beat;
	float rings = ring(r, 0.92, 0.018) + ring(r, 0.6, 0.012) * 0.8;
	float dot_turn = fract((angle / 6.2831853) + time * spin * 1.7);
	float dots = (1.0 - smoothstep(0.08, 0.2, abs(fract(dot_turn * glyphs * 2.0) - 0.5) * 2.0)) * ring(r, 0.5, 0.025) * 0.6;
	float shown = (runes + rings + dots) * (1.0 - smoothstep(0.97, 1.0, r));
	ALBEDO = color.rgb * intensity;
	ALPHA = clamp(shown, 0.0, 1.0) * fade;
	ALPHA *= fx_depth_fade(VERTEX, SCREEN_UV, INV_PROJECTION_MATRIX);
}
