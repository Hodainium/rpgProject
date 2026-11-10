shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// Slash, 3D (spec vfx-content-pass): a crescent cut that sweeps across a camera-facing quad, brightest at its head with a fading
// tail. Physical hits, blades, claws.
// @uniform progress   0..1 over the layer (driven)
// @uniform time       seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform color      slash colour
// @uniform intensity  brightness
// @uniform angle      degrees the cut is turned (0 sweeps left to right along a slight upward curve)
// @uniform thickness  how thick the crescent is (0..1)
// @uniform depth_bias world units the depth test sees the effect closer to the camera (keeps it from being cut by the unit it sits on)
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec4 color : source_color = vec4(1.0, 0.95, 0.8, 1.0);
uniform float intensity = 2.0;
uniform float angle = -25.0;
uniform float thickness = 0.5;

#include "res://game/fx/shaders/fx_depth_bias.gdshaderinc"

void fragment() {
	if (depth_bias != 0.0) {
		DEPTH = fx_biased_depth(VERTEX, PROJECTION_MATRIX);
	}
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float a = radians(angle);
	p = vec2(cos(a) * p.x + sin(a) * p.y, -sin(a) * p.x + cos(a) * p.y);
	// A crescent: inside a big circle, outside a smaller one pushed down, so the upper rim is a thin curved blade.
	float outer = length(p);
	float inner = length(p - vec2(0.0, -0.45 * thickness - 0.1));
	float blade = smoothstep(0.94, 0.88, outer) * smoothstep(0.78, 0.84 + 0.1 * thickness, inner);
	// The sweep: a bright head moving across with a tail behind it, then the whole cut fades.
	float head = mix(-1.2, 1.3, 1.0 - pow(1.0 - clamp(progress * 1.5, 0.0, 1.0), 2.0));
	float band = smoothstep(head - 1.0, head - 0.15, p.x) * (1.0 - smoothstep(head - 0.04, head + 0.04, p.x));
	float glow = 0.55 + 0.45 * smoothstep(head - 0.5, head, p.x);
	ALBEDO = color.rgb * intensity;
	ALPHA = clamp(blade * band * glow * (1.0 - smoothstep(0.7, 1.0, progress)), 0.0, 1.0) * fade;
}
