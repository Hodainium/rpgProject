// Depth bias (spec vfx-content-pass 3.6, Unreal's Pixel Depth Offset): the effect's depth, for the depth test only, is
// moved toward the camera by `depth_bias` world units, so a quad centred on a unit is not cut in half by the unit's own
// mesh, while a wall or a unit that really is in front still hides it. The picture on screen does not move.
// Use in fragment():  if (depth_bias != 0.0) { DEPTH = fx_biased_depth(VERTEX, PROJECTION_MATRIX); }
// (VERTEX is the fragment's view-space position there.) Documented in each including shader's header as
// `// @uniform depth_bias`.
uniform float depth_bias = 0.0;

float fx_biased_depth(vec3 view_position, mat4 projection) {
	vec4 clip = projection * vec4(view_position + vec3(0.0, 0.0, depth_bias), 1.0);
	return clip.z / clip.w;
}
