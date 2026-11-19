// The foil over a flat pack (CardPackView.foil): drawn on top of the pack's body with UV 0..1 over the pack. Each mode is a
// way real foil catches light; `light` is where the light hits (the owner moves it with the pointer), or it drifts on its own.
// @uniform mode       1 holographic (rainbow), 2 brushed metal, 3 glitter, 4 chrome
// @uniform light      where the light hits, 0..1 over the pack
// @uniform auto_light 1 = the light drifts on its own, 0 = only `light`
// @uniform strength   how strong the foil is
// @uniform pack_size  the pack's size in pixels (for round highlights and fine detail)
// @uniform tint       colour mixed into the metal (brushed metal)
shader_type canvas_item;
render_mode blend_mix;

uniform int mode = 1;
uniform vec2 light = vec2(0.3, 0.25);
uniform float auto_light = 1.0;
uniform float strength = 1.0;
uniform vec2 pack_size = vec2(150.0, 228.0);
uniform vec4 tint : source_color = vec4(1.0, 0.92, 0.75, 1.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec3 rainbow(float t) {
	return 0.5 + 0.5 * cos(6.28318 * (t + vec3(0.0, 0.33, 0.67)));
}

void fragment() {
	vec2 uv = UV;
	vec2 drift = vec2(0.5 + 0.45 * sin(TIME * 0.6), 0.5 + 0.35 * sin(TIME * 0.43 + 1.3));
	vec2 l = mix(light, drift, auto_light);
	vec2 d = uv - l;
	vec2 da = vec2(d.x, d.y * pack_size.y / max(pack_size.x, 1.0));
	float r = length(da);
	vec3 col = vec3(1.0);
	float a = 0.0;
	if (mode == 1) {
		float hue = uv.x * 0.9 + uv.y * 0.5 - (l.x + l.y) * 0.8 + r * 0.6;
		float band = 0.35 + 0.65 * exp(-r * r * 6.0);
		float spec = exp(-r * r * 40.0) * 0.6;
		col = mix(rainbow(hue), vec3(1.0), spec);
		a = 0.42 * band + spec;
	} else if (mode == 2) {
		float n = hash(vec2(floor(uv.y * pack_size.y * 0.5), 3.0));
		float fine = 0.6 + 0.4 * n;
		float spec = exp(-pow(d.x * 4.0, 2.0)) * (0.5 + 0.5 * exp(-pow(d.y * 1.5, 2.0)));
		col = mix(vec3(0.9), tint.rgb, 0.35) * fine;
		a = 0.12 + 0.6 * spec * fine;
	} else if (mode == 3) {
		vec2 cell = floor(uv * pack_size / 3.0);
		float rnd = hash(cell);
		float twinkle = pow(max(0.0, sin(TIME * 2.5 + rnd * 60.0)), 16.0) * step(0.7, rnd);
		float boost = 0.3 + 1.2 * exp(-r * r * 5.0);
		float sheen = 0.1 * exp(-r * r * 4.0);
		col = mix(vec3(1.0), rainbow(rnd), 0.5);
		a = twinkle * boost + sheen;
	} else {
		float s = sin((uv.x * 1.2 + uv.y * 0.8 - l.x * 1.5) * 9.0);
		float stripes = smoothstep(0.6, 1.0, s);
		float spec = exp(-pow((uv.x + uv.y * 0.6) - (l.x + l.y * 0.6), 2.0) * 30.0);
		float bright = 0.2 * stripes + 0.75 * spec;
		float dark = 0.22 * smoothstep(0.5, 1.0, -s);
		col = bright > dark ? vec3(1.0) : vec3(0.0);
		a = max(bright, dark);
	}
	COLOR = vec4(col, clamp(a * strength, 0.0, 1.0));
}
