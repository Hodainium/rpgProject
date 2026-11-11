shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// Glow, 3D (spec vfx-framework): a soft additive blob on a camera-facing quad (FxShaderQuadLayer with space WORLD_3D).
// Hit flashes, heal glows, auras.
// @uniform progress   0..1 over the layer (driven)
// @uniform time       seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform color      glow colour
// @uniform intensity  brightness
// @uniform falloff    how tight the blob is (higher = smaller core)
// @uniform fade_out   fraction of the layer spent fading out
// @uniform pulse_speed pulses per second (0 = steady)
// @uniform pulse_amount how much the brightness swings
// @uniform depth_bias world units the depth test sees the effect closer to the camera (keeps it from being cut by the unit it sits on)
// @uniform depth_fade world units past the bias over which the effect fades out where it passes into the scene, instead of a hard cut
// @uniform fx_scene_depth the scene depth buffer, read for the depth fade (filled by the engine)
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec4 color : source_color = vec4(1.0, 0.8, 0.4, 1.0);
uniform float intensity = 1.5;
uniform float falloff = 3.5;
uniform float fade_out = 0.6;
uniform float pulse_speed = 0.0;
uniform float pulse_amount = 0.2;

#include "res://game/fx/shaders/fx_depth_bias.gdshaderinc"

void fragment() {
	if (fx_depth_moved()) {
		DEPTH = fx_biased_depth(VERTEX, PROJECTION_MATRIX);
	}
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p);
	float blob = exp(-r * r * falloff) * (1.0 - smoothstep(0.9, 1.0, r));
	float envelope = fade_out > 0.0 ? 1.0 - smoothstep(1.0 - fade_out, 1.0, progress) : 1.0;
	float pulse = 1.0 + pulse_amount * sin(time * pulse_speed * 6.28318);
	ALBEDO = color.rgb * intensity;
	ALPHA = clamp(blob * envelope * pulse, 0.0, 1.0) * fade;
	ALPHA *= fx_depth_fade(VERTEX, SCREEN_UV, INV_PROJECTION_MATRIX);
}
