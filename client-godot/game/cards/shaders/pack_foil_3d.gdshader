// The 3D pack's foil (CardPack3D): the pack's own picture as the base colour on a metallic surface that the scene's lights and
// sky reflect in, plus an angle-dependent rainbow (holographic foil) that shifts as the pack tilts.
// @uniform pack       the pack's picture (CardPackView rendered to a texture); its alpha cuts the crimped edges
// @uniform metal      how metallic the foil is
// @uniform rough      surface roughness (lower = sharper reflections)
// @uniform holo       strength of the angle-dependent rainbow (0 = plain metallic foil)
// @uniform holo_scale how many rainbow bands cross the pack
shader_type spatial;
render_mode cull_back;

uniform sampler2D pack : source_color, filter_linear_mipmap;
uniform float metal = 0.75;
uniform float rough = 0.25;
uniform float holo = 0.0;
uniform float holo_scale = 1.6;

vec3 rainbow(float t) {
	return 0.5 + 0.5 * cos(6.28318 * (t + vec3(0.0, 0.33, 0.67)));
}

void fragment() {
	vec4 base = texture(pack, UV);
	float facing = dot(NORMAL, VIEW);
	vec3 irid = rainbow(facing * holo_scale + UV.x * 0.7 + UV.y * 0.4);
	ALBEDO = mix(base.rgb, base.rgb * 0.55 + irid * 0.65, holo);
	METALLIC = metal;
	ROUGHNESS = rough;
	SPECULAR = 0.7;
	ALPHA = base.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
