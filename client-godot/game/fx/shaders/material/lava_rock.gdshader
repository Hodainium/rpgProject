shader_type spatial;
render_mode cull_back;

// Lava rock (spec vfx-content-pass): a lumpy, dark rock with glowing cracks and a hot rim, for a meteor or any burning stone. Put it on a
// sphere mesh: the vertices are pushed in and out by noise so the sphere becomes a boulder, and the glow follows a second noise.
// @uniform color       colour of the glow (the heat)
// @uniform glow        brightness of the cracks and the rim
// @uniform lumps       how big the lumps on the rock are (higher = finer)
// @uniform bump        how far the lumps push the surface in and out (world units)
// @uniform crack_scale size of the cracking pattern (higher = finer cracks)
// @uniform crack_cover how much of the rock is cracked and glowing (0..1)
uniform vec4 color : source_color = vec4(1.0, 0.45, 0.12, 1.0);
uniform float glow = 2.0;
uniform float lumps = 2.4;
uniform float bump = 0.16;
uniform float crack_scale = 3.5;
uniform float crack_cover = 0.3;

varying vec3 rock_position;

float hash31(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}

float value_noise3(vec3 p) {
	vec3 cell = floor(p);
	vec3 local = fract(p);
	local = local * local * (3.0 - 2.0 * local);
	float a = mix(mix(hash31(cell), hash31(cell + vec3(1, 0, 0)), local.x), mix(hash31(cell + vec3(0, 1, 0)), hash31(cell + vec3(1, 1, 0)), local.x), local.y);
	float b = mix(mix(hash31(cell + vec3(0, 0, 1)), hash31(cell + vec3(1, 0, 1)), local.x), mix(hash31(cell + vec3(0, 1, 1)), hash31(cell + vec3(1, 1, 1)), local.x), local.y);
	return mix(a, b, local.z);
}

void vertex() {
	float lump = value_noise3(VERTEX * lumps * 2.0) * 0.65 + value_noise3(VERTEX * lumps * 4.7) * 0.35;
	VERTEX += NORMAL * (lump - 0.5) * 2.0 * bump;
	rock_position = VERTEX;
}

void fragment() {
	float pattern = value_noise3(rock_position * crack_scale * 2.0) * 0.6 + value_noise3(rock_position * crack_scale * 5.0) * 0.4;
	// Cracks are the thin bright seams where the pattern crosses a threshold.
	float threshold = 1.0 - crack_cover;
	float seam = 1.0 - smoothstep(0.0, 0.08, abs(pattern - threshold));
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.5);
	ALBEDO = vec3(0.11, 0.09, 0.085);
	ROUGHNESS = 0.92;
	EMISSION = color.rgb * glow * (seam * 1.3 + rim * 0.7 + 0.12);
}
