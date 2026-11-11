shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// Rune circle (spec vfx-content-pass): a magic circle lying on the floor: concentric rings, tick marks round the edge, and an inner ring of
// segments that turns the other way. Fades in, holds and fades out over the layer. Sanctuary's holy ground, a summoning circle.
// @uniform progress   0..1 over the layer (driven)
// @uniform time       seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform color      circle colour
// @uniform intensity  brightness
// @uniform spin       turns per second of the outer ring (the inner one turns the other way)
// @uniform segments   number of tick marks and inner segments
// @uniform depth_bias world units the depth test sees the effect closer to the camera (keeps it from being cut by the unit it sits on)
// @uniform depth_fade world units past the bias over which the effect fades out where it passes into the scene, instead of a hard cut
// @uniform fx_scene_depth the scene depth buffer, read for the depth fade (filled by the engine)
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec4 color : source_color = vec4(1.0, 0.95, 0.6, 1.0);
uniform float intensity = 1.6;
uniform float spin = 0.12;
uniform float segments = 16.0;

#include "res://game/fx/shaders/fx_depth_bias.gdshaderinc"

float ring(float r, float centre, float width) {
	return 1.0 - smoothstep(0.0, width, abs(r - centre));
}

void fragment() {
	if (fx_depth_moved()) {
		DEPTH = fx_biased_depth(VERTEX, PROJECTION_MATRIX);
	}
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p);
	float angle = atan(p.y, p.x);
	float outer_turn = angle - time * spin * 6.2831853;
	float inner_turn = angle + time * spin * 6.2831853 * 1.6;
	float shape = ring(r, 0.93, 0.025) + ring(r, 0.84, 0.012);
	// Tick marks between the two outer rings.
	float tick = step(0.82, fract(outer_turn / 6.2831853 * segments)) * step(0.84, r) * step(r, 0.92);
	// Inner ring broken into segments.
	float broken = step(0.18, fract(inner_turn / 6.2831853 * (segments * 0.5))) * ring(r, 0.58, 0.035);
	// A cross of four thin lines through the middle.
	float cross_lines = (1.0 - smoothstep(0.0, 0.012, min(abs(p.x), abs(p.y)))) * step(r, 0.5);
	float centre = 1.0 - smoothstep(0.0, 0.14, r);
	float envelope = smoothstep(0.0, 0.15, progress) * (1.0 - smoothstep(0.75, 1.0, progress));
	float shown = (shape + tick + broken + cross_lines * 0.6 + centre * 0.5) * (1.0 - smoothstep(0.98, 1.0, r));
	ALBEDO = color.rgb * intensity;
	ALPHA = clamp(shown * envelope, 0.0, 1.0) * fade;
	ALPHA *= fx_depth_fade(VERTEX, SCREEN_UV, INV_PROJECTION_MATRIX);
}
