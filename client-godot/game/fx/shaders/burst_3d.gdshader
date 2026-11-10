shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// Burst, 3D (spec vfx-framework): a shockwave ring expanding on a camera-facing quad. Breaks, big hits.
// @uniform progress     0..1 over the layer (driven)
// @uniform time         seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform color        ring colour
// @uniform intensity    brightness
// @uniform ring_width   thickness of the ring (fraction of the quad radius)
// @uniform start_radius where the ring begins (0..1 of the quad radius)
// @uniform end_radius   where the ring ends
// @uniform depth_bias world units the depth test sees the effect closer to the camera (keeps it from being cut by the unit it sits on)
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec4 color : source_color = vec4(1.0, 0.9, 0.6, 1.0);
uniform float intensity = 2.0;
uniform float ring_width = 0.1;
uniform float start_radius = 0.1;
uniform float end_radius = 0.95;

#include "res://game/fx/shaders/fx_depth_bias.gdshaderinc"

void fragment() {
	if (depth_bias != 0.0) {
		DEPTH = fx_biased_depth(VERTEX, PROJECTION_MATRIX);
	}
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p);
	float eased = 1.0 - pow(1.0 - progress, 3.0);
	float radius = mix(start_radius, end_radius, eased);
	float ring = exp(-pow((r - radius) / ring_width, 2.0)) * (1.0 - progress);
	ALBEDO = color.rgb * intensity;
	ALPHA = clamp(ring * (1.0 - smoothstep(0.92, 1.0, r)), 0.0, 1.0) * fade;
}
