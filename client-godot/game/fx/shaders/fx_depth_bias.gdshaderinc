// Depth and stencil for the 3D effect shaders (spec vfx-stencil; the depth bias of vfx-content-pass 3.6 is gone, 2026-11-11).
// Stencil: an effect drawn over a battle unit is drawn in two passes, from in-memory copies FxStencilShaders makes by putting
// #define lines in front of the shader's code (Godot takes the stencil reference only as a literal, the probe's K5):
// FX_STENCIL_REF is the unit's stencil value, FX_STENCIL_COMPARE the pass's test, FX_STENCIL_OWN marks the OWN pass, which draws
// over its own unit's stamped pixels with no depth test; the OTHER pass draws everywhere else with the normal depth test. The
// shader file itself (no defines) is the plain one-pass shader with the normal depth test: an effect with no unit, a floor ring.
// Depth fade (classic soft particles, Unreal's DepthFade): where the effect passes into the scene (a big disc leaning into the
// floor, a glow touching a neighbouring unit) it fades out over `depth_fade` world units before the depth test cuts it, instead of
// a hard line. Over its own unit (the OWN pass) it keeps full strength.
// Use in fragment():
//     ... ALPHA = ...;
//     ALPHA *= fx_depth_fade(VERTEX, SCREEN_UV, INV_PROJECTION_MATRIX);
// (VERTEX is the fragment's view-space position there.) Documented in each including shader's header as `// @uniform depth_fade`
// and `// @uniform fx_scene_depth`. A shader that draws over units must include this file (FxStencilShaders.supports).
#ifdef FX_STENCIL_REF
stencil_mode read, FX_STENCIL_COMPARE, FX_STENCIL_REF;
#endif
#ifdef FX_STENCIL_OWN
render_mode depth_test_disabled;
#endif

uniform float depth_fade = 0.3;
uniform sampler2D fx_scene_depth : hint_depth_texture, repeat_disable, filter_nearest;

// How far the scene lies behind this fragment, in world units along the view (negative: the scene is in front of it).
float fx_scene_gap(vec3 view_position, vec2 screen_uv, mat4 inv_projection) {
	float scene_depth = texture(fx_scene_depth, screen_uv).x;
	vec4 scene_view = inv_projection * vec4(screen_uv * 2.0 - 1.0, scene_depth, 1.0);
	scene_view.xyz /= scene_view.w;
	return (-scene_view.z) - (-view_position.z);
}

// 1 over its own unit (the OWN pass); else 0 where the scene is at the fragment, rising to 1 over `depth_fade` in front of it.
float fx_depth_fade(vec3 view_position, vec2 screen_uv, mat4 inv_projection) {
#ifdef FX_STENCIL_OWN
	return 1.0;
#else
	if (depth_fade <= 0.0) {
		return 1.0;
	}
	return clamp(fx_scene_gap(view_position, screen_uv, inv_projection) / depth_fade, 0.0, 1.0);
#endif
}
