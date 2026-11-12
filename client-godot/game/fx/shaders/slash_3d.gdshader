shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// Slash, 3D (spec vfx-content-pass): a crescent cut that sweeps across a camera-facing quad, brightest at its head with a fading
// tail. Physical hits, blades, claws. The cut's arc runs through the quad's centre, so it lands on the point the quad sits on (the
// unit's Hit socket); playtest-fixes B13: it used to sit on the rim of a circle, about a third of the quad off centre.
// @uniform progress   0..1 over the layer (driven)
// @uniform time       seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform color      slash colour
// @uniform intensity  brightness
// @uniform angle      degrees the cut is turned (0 sweeps left to right along an arc bulging upward through the centre)
// @uniform thickness  how thick the crescent is at its middle (0..1); it tapers to points at both tips
// @uniform depth_fade world units in front of the scene over which the effect fades out where it passes into it (soft particles), instead of a hard line
// @uniform fx_scene_depth the scene depth buffer, read for the depth fade (filled by the engine)
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec4 color : source_color = vec4(1.0, 0.95, 0.8, 1.0);
uniform float intensity = 2.0;
uniform float angle = -25.0;
uniform float thickness = 0.5;

#include "res://game/fx/shaders/fx_depth_bias.gdshaderinc"

void fragment() {
	// Quad space -1..1 with y up, turned by `angle` about the centre.
	vec2 p = vec2(UV.x - 0.5, 0.5 - UV.y) * 2.0;
	float a = radians(angle);
	p = vec2(cos(a) * p.x - sin(a) * p.y, sin(a) * p.x + cos(a) * p.y);
	// The blade: a band around an arc of radius 1.6 whose top passes through the centre, widest in the middle and tapering to
	// points at x = +-0.92, so the whole cut stays inside the quad. A thin hot core runs along the arc.
	const float RADIUS = 1.6;
	float from_arc = length(p - vec2(0.0, -RADIUS)) - RADIUS;
	float along = clamp(abs(p.x) / 0.92, 0.0, 1.0);
	float half_width = (0.04 + 0.32 * thickness) * (1.0 - along * along);
	float blade = 1.0 - smoothstep(half_width * 0.5, half_width + 0.005, abs(from_arc));
	float core = 1.0 - smoothstep(0.0, half_width * 0.35 + 0.005, abs(from_arc));
	// The sweep: the head crosses from left to right and the cut stays drawn behind it, brightest at the head; then the whole
	// cut fades out (so the finished cut is centred on the quad, not only its last stretch).
	float head = mix(-1.05, 1.1, 1.0 - pow(1.0 - clamp(progress * 1.6, 0.0, 1.0), 2.0));
	float drawn = 1.0 - smoothstep(head - 0.05, head + 0.05, p.x);
	float glow = 0.45 + 0.55 * smoothstep(head - 0.9, head, p.x);
	ALBEDO = color.rgb * intensity * (1.0 + 0.6 * core);
	ALPHA = clamp(blade * drawn * glow * (1.0 - smoothstep(0.55, 1.0, progress)), 0.0, 1.0) * fade;
	ALPHA *= fx_depth_fade(VERTEX, SCREEN_UV, INV_PROJECTION_MATRIX);
}
