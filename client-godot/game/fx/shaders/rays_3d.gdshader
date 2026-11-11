shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// Rays, 3D (spec vfx-framework): god rays on a camera-facing quad. Ults, bosses, a legendary card in the 3D stage.
// @uniform progress   0..1 over the layer (driven)
// @uniform time       seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform color      ray colour
// @uniform intensity  brightness
// @uniform ray_count  number of rays
// @uniform spin       turns per second
// @uniform sharpness  how thin the rays are
// @uniform falloff    how fast the rays die away from the middle
// @uniform fade_out   fraction of the layer spent fading out
// @uniform depth_bias world units the depth test sees the effect closer to the camera (keeps it from being cut by the unit it sits on)
// @uniform depth_fade world units past the bias over which the effect fades out where it passes into the scene, instead of a hard cut
// @uniform fx_scene_depth the scene depth buffer, read for the depth fade (filled by the engine)
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec4 color : source_color = vec4(1.0, 0.85, 0.4, 1.0);
uniform float intensity = 2.0;
uniform float ray_count = 14.0;
uniform float spin = 0.08;
uniform float sharpness = 3.0;
uniform float falloff = 1.8;
uniform float fade_out = 0.4;

#include "res://game/fx/shaders/fx_depth_bias.gdshaderinc"

void fragment() {
	if (fx_depth_moved()) {
		DEPTH = fx_biased_depth(VERTEX, PROJECTION_MATRIX);
	}
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p);
	float angle = atan(p.y, p.x) + time * spin * 6.28318;
	float rays = pow(abs(sin(angle * ray_count * 0.5)), sharpness);
	float radial = exp(-r * falloff) * (1.0 - smoothstep(0.85, 1.0, r));
	float envelope = smoothstep(0.0, 0.08, progress) * (fade_out > 0.0 ? 1.0 - smoothstep(1.0 - fade_out, 1.0, progress) : 1.0);
	ALBEDO = color.rgb * intensity;
	ALPHA = clamp(rays * radial * envelope, 0.0, 1.0) * fade;
	ALPHA *= fx_depth_fade(VERTEX, SCREEN_UV, INV_PROJECTION_MATRIX);
}
