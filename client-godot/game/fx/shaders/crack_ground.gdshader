shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// Ground cracks (spec vfx-content-pass): jagged glowing cracks running outward from a point on a quad lying on the floor, quickly at first,
// then cooling and fading. Quake. Each crack's length and wobble come from a hash of its number, so every crack is different.
// @uniform progress   0..1 over the layer (driven)
// @uniform time       seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform color      crack colour
// @uniform intensity  brightness
// @uniform crack_count how many cracks run out from the middle
// @uniform width      thickness of a crack
// @uniform depth_fade world units in front of the scene over which the effect fades out where it passes into it (soft particles), instead of a hard line
// @uniform fx_scene_depth the scene depth buffer, read for the depth fade (filled by the engine)
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec4 color : source_color = vec4(1.0, 0.55, 0.2, 1.0);
uniform float intensity = 2.0;
uniform float crack_count = 9.0;
uniform float width = 0.018;

#include "res://game/fx/shaders/fx_stencil_depth.gdshaderinc"

float hash11(float n) {
	return fract(sin(n * 91.3458) * 47453.5453);
}

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p);
	float angle = atan(p.y, p.x);
	float sector = 6.2831853 / crack_count;
	float best = 0.0;
	// Check this pixel's own sector and its two neighbours, so a wobbling crack that crosses a sector edge is not cut.
	for (int offset = -1; offset <= 1; offset++) {
		float index = floor(angle / sector) + float(offset);
		float id = mod(index + crack_count, crack_count);
		float centre_angle = (index + 0.3 + 0.4 * hash11(id)) * sector;
		float reach = 0.55 + 0.4 * hash11(id + 7.0);
		float wobble = 0.07 * sin(r * (9.0 + 8.0 * hash11(id + 3.0)) + id * 2.0);
		float off_angle = angle - centre_angle - wobble;
		float line_distance = abs(sin(off_angle)) * r;
		float grown = clamp(progress * 3.0, 0.0, 1.0);
		float run = smoothstep(reach * grown, reach * grown - 0.12, r);
		float crack = (1.0 - smoothstep(0.0, width * (1.0 + 1.5 * (1.0 - r)), line_distance)) * run * step(cos(off_angle), 2.0) * step(0.0, cos(off_angle));
		best = max(best, crack);
	}
	float heat = 1.0 - smoothstep(0.3, 1.0, progress);
	float centre = (1.0 - smoothstep(0.0, 0.18, r)) * heat;
	ALBEDO = color.rgb * intensity;
	ALPHA = clamp((best * (0.35 + 0.65 * heat) + centre * 0.6), 0.0, 1.0) * (1.0 - smoothstep(0.92, 1.0, r)) * fade;
	ALPHA *= fx_depth_fade(VERTEX, SCREEN_UV, INV_PROJECTION_MATRIX);
}
