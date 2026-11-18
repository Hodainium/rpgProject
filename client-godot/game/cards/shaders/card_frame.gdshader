shader_type canvas_item;

// Mythic card frame (spec card-ui, Look B; the user's pick of 2026-11-18): opal, a milky pastel iridescence shifting slowly
// across a rounded frame, on a quad exactly the frame's size. The other rarities' frames are flat metal gradients (UIWindowStyle).
// @uniform rect_size the quad's size in pixels (set by the face)
// @uniform corner    corner rounding of the frame, in pixels
// @uniform time      seconds, for the shift (set by the face)
// @uniform pearl     the opal's milky base colour
// @uniform colour    how much rainbow shows through the pearl (0..1)
// @uniform drift     how fast the colours travel across the frame
// @uniform shimmer   the soft light bands' strength (0 = none)
uniform vec2 rect_size = vec2(276.0, 396.0);
uniform float corner = 8.0;
uniform float time = 0.0;
uniform vec4 pearl : source_color = vec4(0.93, 0.92, 0.96, 1.0);
uniform float colour = 0.32;
uniform float drift = 0.12;
uniform float shimmer = 0.08;

float box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 p = UV * rect_size;
	vec2 centre = rect_size * 0.5;
	float edge = box(p - centre, centre, corner);
	float s = dot(UV - 0.5, normalize(vec2(0.866, 0.5))) * 0.9 + time * drift;
	vec3 rainbow = clamp(abs(fract(s * 0.8 + vec3(0.0, 0.667, 0.333)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
	vec3 opal = mix(pearl.rgb, rainbow, colour) * (1.0 - shimmer + shimmer * sin(UV.y * 9.0 + time * 0.5));
	opal *= mix(0.4, 1.0, smoothstep(0.0, 1.6, -edge));  // a thin dark edge
	COLOR = vec4(opal, 1.0 - smoothstep(-0.75, 0.75, edge));
}
