shader_type canvas_item;

// Card art window (spec card-ui, Look B): the art of a card in its rectangular window, on a TextureRect whose texture is the art
// (a portrait or a game-icons glyph) and whose size is the window. A dark outline, a radial backdrop and, for a glyph, a tint with
// a dark halo. Sizes are in pixels of the window.
// @uniform rect_size     the window's size in pixels (set by the face)
// @uniform outline_width the dark outline round the window, in pixels
// @uniform outline_color the outline's colour
// @uniform glyph         1 = the texture is a glyph (centred, tinted); 0 = a portrait (fills the window)
// @uniform glyph_scale   the glyph's size, as a fraction of the window's smaller side
// @uniform glyph_tint    the glyph's colour
// @uniform glow_color    the halo round the glyph
// @uniform glow_radius   the halo's reach, in pixels
// @uniform bg_center     the backdrop at its centre
// @uniform bg_mid        the backdrop at 45% out
// @uniform bg_edge       the backdrop at the window's edge
// @uniform inner_shadow  darkening toward the window's edge (0 = none)
uniform vec2 rect_size = vec2(252.0, 160.0);
uniform float outline_width = 2.7;
uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 0.6);
uniform float glyph = 1.0;
uniform float glyph_scale = 0.6;
uniform vec4 glyph_tint : source_color = vec4(0.953, 0.918, 0.831, 1.0);
uniform vec4 glow_color : source_color = vec4(0.0, 0.0, 0.0, 0.55);
uniform float glow_radius = 6.0;
uniform vec4 bg_center : source_color = vec4(0.6, 0.55, 0.45, 1.0);
uniform vec4 bg_mid : source_color = vec4(0.3, 0.27, 0.25, 1.0);
uniform vec4 bg_edge : source_color = vec4(0.047, 0.047, 0.071, 1.0);
uniform float inner_shadow = 0.3;

// The glyph's alpha at `g`, 0 outside it (a macro: TEXTURE is only visible inside fragment(), and the engine refuses it as a
// function argument).
#define SAMPLE_ALPHA(g) (((g).x >= 0.0 && (g).x <= 1.0 && (g).y >= 0.0 && (g).y <= 1.0) ? texture(TEXTURE, (g)).a : 0.0)

void fragment() {
	vec2 p = UV * rect_size;
	// Distance to the window's edge, in pixels (negative inside).
	vec2 q = abs(p - rect_size * 0.5) - rect_size * 0.5;
	float edge = max(q.x, q.y);
	float inner = edge + outline_width;
	// The backdrop: a radial glow.
	float r = length((UV - vec2(0.5, 0.45)) * vec2(1.0, rect_size.y / rect_size.x)) / 0.62;
	vec3 colour = r < 0.45 ? mix(bg_center.rgb, bg_mid.rgb, r / 0.45) : mix(bg_mid.rgb, bg_edge.rgb, clamp((r - 0.45) / 0.55, 0.0, 1.0));
	if (glyph > 0.5) {
		float side = min(rect_size.x, rect_size.y) * glyph_scale;
		vec2 g = (p - rect_size * 0.5) / side + 0.5;
		float a = SAMPLE_ALPHA(g);
		float halo = 0.0;
		for (int i = 0; i < 12; i++) {
			float angle = float(i) * 0.5236;
			for (int k = 1; k <= 2; k++) {
				halo += SAMPLE_ALPHA(g + vec2(cos(angle), sin(angle)) * glow_radius * float(k) * 0.5 / side);
			}
		}
		halo = clamp(halo / 24.0 * 1.6, 0.0, 1.0);
		float shadow = SAMPLE_ALPHA(g + vec2(0.0, 2.0 / side));
		colour = mix(colour, glow_color.rgb, halo * glow_color.a * 0.85);
		colour = mix(colour, vec3(0.0), shadow * 0.6 * (1.0 - a));
		colour = mix(colour, glyph_tint.rgb, a);
	} else {
		// Cover: the portrait fills the window, centred, keeping its aspect.
		vec2 tex_size = vec2(textureSize(TEXTURE, 0));
		float s = max(rect_size.x / tex_size.x, rect_size.y / tex_size.y);
		colour = texture(TEXTURE, (p - rect_size * 0.5) / (tex_size * s) + 0.5).rgb;
	}
	colour *= mix(1.0 - inner_shadow * 0.6, 1.0, smoothstep(0.0, 22.0, -inner));
	COLOR = mix(vec4(colour, 1.0), outline_color, smoothstep(-0.75, 0.75, inner));
}
