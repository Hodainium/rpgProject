// Depth bias (spec vfx-content-pass 3.6, Unreal's Pixel Depth Offset): the effect's depth, for the depth test only, is
// moved toward the camera by `depth_bias` world units, so a quad centred on a unit is not cut in half by the unit's own
// mesh, while a wall or a unit that really is in front still hides it. The picture on screen does not move.
// Depth fade (Unreal's DepthFade, playtest-fixes B14): past the bias the effect is not cut off at a hard line where it
// passes into the scene (a big camera-facing disc leaning into the floor); it fades out over `depth_fade` more world
// units. Nothing that shows at full strength without the fade (anything less than `depth_bias` behind the scene) is dimmed.
// Use in fragment():
//     if (fx_depth_moved()) { DEPTH = fx_biased_depth(VERTEX, PROJECTION_MATRIX); }
//     ... ALPHA = ...;
//     ALPHA *= fx_depth_fade(VERTEX, SCREEN_UV, INV_PROJECTION_MATRIX);
// (VERTEX is the fragment's view-space position there.) Documented in each including shader's header as
// `// @uniform depth_bias`, `// @uniform depth_fade` and `// @uniform fx_scene_depth`.
uniform float depth_bias = 0.0;
uniform float depth_fade = 0.8;
uniform sampler2D fx_scene_depth : hint_depth_texture, repeat_disable, filter_nearest;

bool fx_depth_moved() {
	return depth_bias != 0.0 || depth_fade > 0.0;
}

// The depth the test sees: the bias, plus the fade's reach (the fade itself hides that last stretch smoothly).
float fx_biased_depth(vec3 view_position, mat4 projection) {
	vec4 clip = projection * vec4(view_position + vec3(0.0, 0.0, depth_bias + max(depth_fade, 0.0)), 1.0);
	return clip.z / clip.w;
}

// How far the scene lies behind this fragment, in world units along the view (negative: the scene is in front of it).
float fx_scene_gap(vec3 view_position, vec2 screen_uv, mat4 inv_projection) {
	float scene_depth = texture(fx_scene_depth, screen_uv).x;
	vec4 scene_view = inv_projection * vec4(screen_uv * 2.0 - 1.0, scene_depth, 1.0);
	scene_view.xyz /= scene_view.w;
	return (-scene_view.z) - (-view_position.z);
}

// 1 while the scene is less than `depth_bias` in front of the fragment (as without the fade), falling to 0 over the next
// `depth_fade` units, where the depth test now cuts.
float fx_depth_fade(vec3 view_position, vec2 screen_uv, mat4 inv_projection) {
	if (depth_fade <= 0.0) {
		return 1.0;
	}
	float gap = fx_scene_gap(view_position, screen_uv, inv_projection);
	return clamp((gap + depth_bias + depth_fade) / depth_fade, 0.0, 1.0);
}
