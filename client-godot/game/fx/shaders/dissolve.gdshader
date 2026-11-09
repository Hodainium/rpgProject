shader_type canvas_item;

// Dissolve (spec vfx-framework): burns a texture away with a glowing edge, bottom first. Put it on a quad that shows the
// card art (set `albedo_texture`); `progress` 0 = whole, 1 = gone.
// @uniform albedo_texture the picture that dissolves
// @uniform progress       0..1 over the layer (driven)
// @uniform time           seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform edge_color     colour of the burning edge
// @uniform edge_width     thickness of the burning edge
// @uniform noise_scale    size of the burn pattern (higher = finer)
// @uniform direction_bias 0 = random burn, 1 = a clean sweep from the bottom
// @uniform intensity      brightness of the edge
uniform sampler2D albedo_texture : source_color, filter_linear;
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec4 edge_color : source_color = vec4(1.0, 0.5, 0.1, 1.0);
uniform float edge_width = 0.08;
uniform float noise_scale = 8.0;
uniform float direction_bias = 0.35;
uniform float intensity = 2.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 4; i++) {
		value += amplitude * noise(p);
		p *= 2.0;
		amplitude *= 0.5;
	}
	return value;
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	float n = fbm(UV * noise_scale) * (1.0 - direction_bias) + (1.0 - UV.y) * direction_bias;
	float cut = n - (progress * (1.0 + edge_width * 2.0) - edge_width);
	float alive = smoothstep(0.0, 0.01, cut);
	float edge = (1.0 - smoothstep(0.0, edge_width, cut)) * step(0.0, cut);
	COLOR = vec4(mix(tex.rgb, edge_color.rgb * intensity, edge), tex.a * alive * fade);
}
