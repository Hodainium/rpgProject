shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, shadows_disabled;

// Particle draw material, 3D (spec vfx-content-pass 3.6): what FxParticles3DLayer draws its quads with. Camera-facing
// particles (their rotation and scale kept), a sprite-sheet flipbook, the particle colour, additive or normal blending
// in one shader, and the depth bias that keeps a quad centred on a unit from being cut by that unit's mesh.
// @uniform albedo_texture the particle texture (a sheet when h_frames x v_frames is more than 1)
// @uniform h_frames       columns of the sheet
// @uniform v_frames       rows of the sheet
// @uniform additive       1 = adds light (fire, sparks, glows), 0 = normal alpha blending (smoke, shards)
// @uniform depth_bias     world units the depth test sees the particle closer to the camera
// @uniform depth_fade     world units before the depth cut over which a particle fades out where it passes into the scene (at most half the bias)
// @uniform fx_scene_depth the scene depth buffer, read for the soft and depth fades (filled by the engine)
// @uniform soft_distance  world units over which a particle fades out where it nears scene geometry (0 = off)
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform int h_frames = 1;
uniform int v_frames = 1;
uniform float additive = 1.0;
uniform float soft_distance = 0.0;

#include "res://game/fx/shaders/fx_depth_bias.gdshaderinc"

varying vec4 particle_color;
varying float particle_frame;

void vertex() {
	// Face the camera, keep the particle's own rotation (INSTANCE_CUSTOM.x) and scale.
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	mat4 world = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]), normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	world = world * mat4(
		vec4(cos(INSTANCE_CUSTOM.x), -sin(INSTANCE_CUSTOM.x), 0.0, 0.0),
		vec4(sin(INSTANCE_CUSTOM.x), cos(INSTANCE_CUSTOM.x), 0.0, 0.0),
		vec4(0.0, 0.0, 1.0, 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	VERTEX *= scale;
	MODELVIEW_MATRIX = VIEW_MATRIX * world;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	particle_color = COLOR;
	particle_frame = INSTANCE_CUSTOM.z;
}

void fragment() {
	float frames = float(h_frames * v_frames);
	float frame = floor(clamp(particle_frame, 0.0, 0.9999) * frames);
	float column = mod(frame, float(h_frames));
	float row = floor(frame / float(h_frames));
	vec2 uv = (UV + vec2(column, row)) / vec2(float(h_frames), float(v_frames));
	vec4 texel = texture(albedo_texture, uv);
	float alpha = texel.a * particle_color.a;
	if (soft_distance > 0.0) {
		// Soft particles: how far the scene is behind this particle (its depth with the bias applied), faded to 0 at contact.
		float gap = fx_scene_gap(VERTEX, SCREEN_UV, INV_PROJECTION_MATRIX) + depth_bias;
		alpha *= clamp(gap / soft_distance, 0.0, 1.0);
	}
	alpha *= fx_depth_fade(VERTEX, SCREEN_UV, INV_PROJECTION_MATRIX);
	// Premultiplied output: normal blending keeps its alpha, additive sets it to 0 so the light only adds.
	ALBEDO = texel.rgb * particle_color.rgb * alpha;
	ALPHA = alpha * (1.0 - additive);
	if (fx_depth_moved()) {
		DEPTH = fx_biased_depth(VERTEX, PROJECTION_MATRIX);
	}
}
