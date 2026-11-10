shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;

// Fresnel rim glow and shell (spec vfx-content-pass 3.6): an overlay on the unit's own mesh (FxFresnelLayer sets it as the mesh's
// material overlay): a glow brightest where the surface turns away from the camera, optionally filling the whole body, pushed a
// little outward, and eaten by scrolling noise so it reads as flames, frost or ooze on the unit itself. Status looks and hit
// flashes with no billboard, so nothing can intersect the model.
// @uniform color       rim colour
// @uniform intensity   brightness
// @uniform power       how thin the rim is (higher = a narrower edge)
// @uniform strength    0..1 over the layer (driven by the layer: the fade in and out)
// @uniform fill        how much of the body glows besides the rim (0 = rim only)
// @uniform grow        world units the shell is pushed out along the surface normal
// @uniform erosion     0..1, how much of the glow the noise eats (0 = solid)
// @uniform noise_scale size of the noise pattern
// @uniform scroll      how fast the noise scrolls upward, in noise units a second (0 = still)
uniform vec4 color : source_color = vec4(1.0, 0.5, 0.2, 1.0);
uniform float intensity = 1.5;
uniform float power = 2.5;
uniform float strength = 1.0;
uniform float fill = 0.0;
uniform float grow = 0.0;
uniform float erosion = 0.0;
uniform float noise_scale = 4.0;
uniform float scroll = 0.0;

varying vec3 shell_position;
varying vec3 shell_normal;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 local = fract(p);
	local = local * local * (3.0 - 2.0 * local);
	float a = hash21(cell);
	float b = hash21(cell + vec2(1.0, 0.0));
	float c = hash21(cell + vec2(0.0, 1.0));
	float d = hash21(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, local.x), mix(c, d, local.x), local.y);
}

void vertex() {
	VERTEX += NORMAL * grow;
	shell_position = VERTEX;
	shell_normal = NORMAL;
}

void fragment() {
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), power);
	float glow = rim + fill;
	if (erosion > 0.0) {
		// Noise in the mesh's own space, projected from the three axes and blended by the surface normal (no stripes on any face),
		// scrolling up the body: flames lick upward and the pattern stays on the unit as it moves.
		vec3 weight = pow(abs(normalize(shell_normal)), vec3(4.0));
		weight /= (weight.x + weight.y + weight.z);
		float lift = TIME * scroll;
		float n_x = value_noise(vec2(shell_position.z, shell_position.y - lift) * noise_scale);
		float n_y = value_noise(vec2(shell_position.x, shell_position.z + lift * 0.4) * noise_scale);
		float n_z = value_noise(vec2(shell_position.x, shell_position.y - lift) * noise_scale);
		float n = n_x * weight.x + n_y * weight.y + n_z * weight.z;
		glow *= smoothstep(erosion, erosion + 0.25, n);
	}
	ALBEDO = color.rgb * intensity;
	ALPHA = clamp(glow * strength * color.a, 0.0, 1.0);
}
