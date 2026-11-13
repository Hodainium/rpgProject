shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// Beam, 3D (spec vfx-content-pass): a tall column of light on a camera-facing quad: a white-hot core, a coloured halo, edges that ripple
// upward, and a swell-and-fade over the layer. Death rays, sky beams, pillars of judgement.
// @uniform progress   0..1 over the layer (driven)
// @uniform time       seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform color      halo colour
// @uniform core_color colour of the white-hot middle
// @uniform intensity  brightness
// @uniform sharpness  how thin the core is (higher = thinner)
// @uniform ripple     how much the edges ripple (0 = smooth)
// @uniform depth_fade world units in front of the scene over which the effect fades out where it passes into it (soft particles), instead of a hard line
// @uniform fx_scene_depth the scene depth buffer, read for the depth fade (filled by the engine)
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec4 color : source_color = vec4(0.7, 0.4, 1.0, 1.0);
uniform vec4 core_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float intensity = 2.0;
uniform float sharpness = 14.0;
uniform float ripple = 0.35;

#include "res://game/fx/shaders/fx_stencil_depth.gdshaderinc"

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 local = fract(p);
	local = local * local * (3.0 - 2.0 * local);
	return mix(mix(hash21(cell), hash21(cell + vec2(1, 0)), local.x), mix(hash21(cell + vec2(0, 1)), hash21(cell + vec2(1, 1)), local.x), local.y);
}

void fragment() {
	float x = (UV.x - 0.5) * 2.0;
	float swell = smoothstep(0.0, 0.12, progress) * (1.0 - smoothstep(0.55, 1.0, progress));
	float width_scale = mix(0.25, 1.0, smoothstep(0.0, 0.2, progress));
	x /= width_scale;
	float wobble = (value_noise(vec2(UV.y * 9.0 - time * 7.0, time * 2.0)) - 0.5) * ripple;
	float d = abs(x + wobble);
	float core = exp(-d * d * sharpness);
	float halo = exp(-d * d * 3.2);
	float vertical = smoothstep(0.0, 0.06, UV.y) * (1.0 - smoothstep(0.94, 1.0, UV.y));
	vec3 rgb = mix(color.rgb * halo, core_color.rgb, core) * intensity;
	ALBEDO = rgb;
	ALPHA = clamp((halo * 0.7 + core) * swell * vertical, 0.0, 1.0) * fade;
	ALPHA *= fx_depth_fade(VERTEX, SCREEN_UV, INV_PROJECTION_MATRIX);
}
