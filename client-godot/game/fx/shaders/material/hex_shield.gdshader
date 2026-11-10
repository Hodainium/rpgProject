shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;

// Hex shield (spec vfx-content-pass): a force-field skin for a sphere mesh: a glowing rim, hexagonal plates outlined in light, and a sweep of
// brightness that runs round it. Bastion's dome. FxMeshLayer puts it on a sphere; animate `strength` with a curve track to fade it in and out.
// @uniform color       shield colour
// @uniform intensity   brightness
// @uniform hex_scale   how many plates there are (higher = smaller plates)
// @uniform strength    0..1, the shield's presence (fade it in and out with a track)
// @uniform sweep_speed how fast the bright band runs round the dome (turns a second)
uniform vec4 color : source_color = vec4(0.4, 0.7, 1.0, 1.0);
uniform float intensity = 1.6;
uniform float hex_scale = 5.0;
uniform float strength = 1.0;
uniform float sweep_speed = 0.6;

varying vec3 dome_position;

vec2 hex_offset(vec2 p) {
	const vec2 s = vec2(1.7320508, 1.0);
	vec4 centres = floor(vec4(p, p - vec2(1.0, 0.5)) / s.xyxy) + 0.5;
	vec4 h = vec4(p - centres.xy * s, p - (centres.zw + 0.5) * s);
	return dot(h.xy, h.xy) < dot(h.zw, h.zw) ? h.xy : h.zw;
}

void vertex() {
	dome_position = VERTEX;
}

void fragment() {
	vec3 n = normalize(dome_position);
	vec2 sphere_uv = vec2(atan(n.x, n.z) * 0.95, n.y * 1.6) * hex_scale;
	vec2 h = abs(hex_offset(sphere_uv));
	float edge = 0.5 - max(dot(h, vec2(0.5, 0.8660254)), h.x);
	float lines = 1.0 - smoothstep(0.0, 0.07, edge);
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.2);
	float sweep = 0.5 + 0.5 * sin((atan(n.x, n.z) / 6.2831853 - TIME * sweep_speed) * 6.2831853 * 1.0);
	float glow = rim * 0.9 + lines * (0.5 + 0.7 * sweep) + 0.06;
	ALBEDO = color.rgb * intensity;
	ALPHA = clamp(glow * strength * color.a, 0.0, 1.0);
}
