// Depth bias (spec vfx-content-pass 3.6, Unreal's Pixel Depth Offset): the effect's depth, for the depth test only, is
// moved toward the camera by `depth_bias` world units, so a quad centred on a unit is not cut in half by the unit's own
// mesh, while a wall or a unit that really is in front still hides it. The picture on screen does not move.
// Depth fade (Unreal's DepthFade, playtest-fixes B14): where the effect passes into the scene (a big camera-facing disc
// leaning into the floor) it is not cut off at a hard line; it fades out over the last stretch before the cut. The fade
// happens inside the bias and never moves the cut, so nothing shows through anything it did not show through without it.
// Its width is `depth_fade`, at most half the bias, so the unit an effect sits on (well inside the bias) keeps it at full strength.
// Use in fragment():
//     if (fx_depth_moved()) { DEPTH = fx_biased_depth(VERTEX, PROJECTION_MATRIX); }
//     ... ALPHA = ...;
//     ALPHA *= fx_depth_fade(VERTEX, SCREEN_UV, INV_PROJECTION_MATRIX);
// (VERTEX is the fragment's view-space position there.) Documented in each including shader's header as
// `// @uniform depth_bias`, `// @uniform depth_fade` and `// @uniform fx_scene_depth`.
// Stencil (spec vfx-stencil 3.4): only in the in-memory copies FxStencilShaders makes, which put #define lines in front of the
// code. FX_STENCIL_REF is the unit's stencil value, FX_STENCIL_COMPARE the pass's test, FX_STENCIL_OWN marks the pass that draws
// over its own unit's pixels with no depth test. In a copy the bias is off and the fade is the classic soft fade. Without the
// defines (bias mode, the files on disk) these blocks are skipped and the shader is exactly as before.
#ifdef FX_STENCIL_REF
stencil_mode read, FX_STENCIL_COMPARE, FX_STENCIL_REF;
#endif
#ifdef FX_STENCIL_OWN
render_mode depth_test_disabled;
#endif

uniform float depth_bias = 0.0;
uniform float depth_fade = 0.3;
uniform sampler2D fx_scene_depth : hint_depth_texture, repeat_disable, filter_nearest;

bool fx_depth_moved() {
#ifdef FX_STENCIL_REF
	return false;
#else
	return depth_bias != 0.0;
#endif
}

float fx_biased_depth(vec3 view_position, mat4 projection) {
	vec4 clip = projection * vec4(view_position + vec3(0.0, 0.0, depth_bias), 1.0);
	return clip.z / clip.w;
}

// How far the scene lies behind this fragment, in world units along the view (negative: the scene is in front of it).
float fx_scene_gap(vec3 view_position, vec2 screen_uv, mat4 inv_projection) {
	float scene_depth = texture(fx_scene_depth, screen_uv).x;
	vec4 scene_view = inv_projection * vec4(screen_uv * 2.0 - 1.0, scene_depth, 1.0);
	scene_view.xyz /= scene_view.w;
	return (-scene_view.z) - (-view_position.z);
}

// 0 at the cut (the scene `depth_bias` in front of the fragment), rising to 1 over the fade's width toward the fragment.
// In a stencil copy (spec vfx-stencil 3.6): full strength over its own unit (OWN), else the classic soft fade over `depth_fade`.
float fx_depth_fade(vec3 view_position, vec2 screen_uv, mat4 inv_projection) {
#if defined(FX_STENCIL_OWN)
	return 1.0;
#elif defined(FX_STENCIL_REF)
	if (depth_fade <= 0.0) {
		return 1.0;
	}
	return clamp(fx_scene_gap(view_position, screen_uv, inv_projection) / depth_fade, 0.0, 1.0);
#else
	float fx_fade_width = min(depth_fade, 0.5 * depth_bias);
	if (fx_fade_width <= 0.0) {
		return 1.0;
	}
	float fx_gap = fx_scene_gap(view_position, screen_uv, inv_projection);
	return clamp((fx_gap + depth_bias) / fx_fade_width, 0.0, 1.0);
#endif
}
