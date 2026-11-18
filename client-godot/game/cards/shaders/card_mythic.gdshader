shader_type canvas_item;
render_mode blend_add;

// Mythic glitter (spec card-ui, Look B; the user's pick of 2026-11-18): rainbow stars twinkling in and out across the card, an
// additive layer exactly the card's size. Sizes are in pixels.
// @uniform rect_size the card's size in pixels (set by the face)
// @uniform corner    corner rounding of the card, in pixels
// @uniform time      seconds (set by the face)
// @uniform strength  overall brightness
// @uniform speed     how fast the stars twinkle (1 = their normal pace)
// @uniform density   the share of grid cells that hold a star (0..1)
// @uniform cell      the star grid's cell size, in pixels
uniform vec2 rect_size = vec2(300.0, 420.0);
uniform float corner = 16.0;
uniform float time = 0.0;
uniform float strength = 0.6;
uniform float speed = 1.0;
uniform float density = 0.16;
uniform float cell = 14.0;

float box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec3 hue(float h) {
	vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
	vec3 p = abs(fract(h + k) * 6.0 - 3.0);
	return clamp(p - 1.0, 0.0, 1.0);
}

void fragment() {
	vec2 p = UV * rect_size;
	float mask = 1.0 - smoothstep(-1.0, 1.0, box(p - rect_size * 0.5, rect_size * 0.5, corner));
	vec2 id = floor(p / cell);
	vec2 f = fract(p / cell) - 0.5;
	float h = hash(id);
	vec3 colour = vec3(0.0);
	if (h <= density) {
		vec2 jitter = vec2(hash(id + 3.1), hash(id + 7.7)) - 0.5;
		vec2 d = (f - jitter * 0.5) * cell;
		float twinkle = pow(max(sin(time * 1.3 * speed + h * 97.0), 0.0), 12.0);
		float core = exp(-dot(d, d) * 0.35);
		float arms = exp(-abs(d.x) * 1.4) * exp(-d.y * d.y * 2.5) + exp(-abs(d.y) * 1.4) * exp(-d.x * d.x * 2.5);
		colour = (hue(h * 7.0 + time * 0.05) * 0.5 + vec3(0.5)) * (core + arms * 0.45) * twinkle * 1.6;
	}
	COLOR = vec4(colour * strength * mask, 1.0);
}
