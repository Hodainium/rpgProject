// Spec card-ui 3.3: a card on the 3D stage (CardView3D). Draws the card's live face texture (its own SubViewport) unshaded, so
// the face keeps the approved colours, and adds the hover glare, the missing card's ghost and a short flash.
// The face viewport's alpha does not reach a 3D material (on the pinned 4.7.2 build it samples as 1 everywhere, though the 2D
// render is transparent), so the card's outline comes from its rounded rectangle here; around it, on the viewport's black clear,
// a glow the face draws there (a corrupted card's) keeps its brightness as its alpha.
// @uniform face_tex the face's SubViewport texture
// @uniform texture_size the texture's size in design pixels (the face plus its margin)
// @uniform card_box the card inside it: x, y, width, height in design pixels
// @uniform corner the card's corner radius in design pixels
// @uniform ghost 0..1: a missing card, greyed and tinted blue (the prototype's "ghosted" look)
// @uniform ghost_tint the ghost's tint
// @uniform glare_pos where the glare sits, in the texture's UV (follows the cursor)
// @uniform glare_strength 0..1: the glare's brightness (0 off)
// @uniform glare_radius the glare's radius in UV
// @uniform flash_color the flash's colour (a rarity's)
// @uniform flash 0..1: the flash's strength (a crafted card)
// @uniform face_baked spec item-cards: the face baked once into a mipmapped texture (a small floor card: no shimmer)
// @uniform use_baked 1 = draw face_baked instead of the live face_tex
// @uniform rim_color spec item-cards: an outline around the card in this colour (a floor card's rarity)
// @uniform rim_width the outline's width in design pixels, inside the margin (0 = none)
// @uniform rim_energy the outline's brightness (above 1 blooms with the room's glow)
shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_opaque, shadows_disabled;

uniform sampler2D face_tex : source_color, filter_linear;
uniform vec2 texture_size = vec2(360.0, 480.0);
uniform vec4 card_box = vec4(30.0, 30.0, 300.0, 420.0);
uniform float corner = 16.0;
uniform float ghost : hint_range(0.0, 1.0) = 0.0;
uniform vec3 ghost_tint : source_color = vec3(0.431, 0.667, 1.0);
uniform vec2 glare_pos = vec2(0.5, 0.3);
uniform float glare_strength : hint_range(0.0, 1.0) = 0.0;
uniform float glare_radius = 0.55;
uniform vec3 flash_color : source_color = vec3(1.0);
uniform float flash : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D face_baked : source_color, filter_linear_mipmap_anisotropic;
uniform float use_baked = 0.0;
uniform vec3 rim_color : source_color = vec3(1.0);
uniform float rim_width = 0.0;
uniform float rim_energy = 1.0;

float rounded_box(vec2 p, vec2 half_size, float radius) {
	vec2 q = abs(p) - half_size + vec2(radius);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

void fragment() {
	vec3 face = use_baked > 0.5 ? texture(face_baked, UV).rgb : texture(face_tex, UV).rgb;
	vec2 p = UV * texture_size - (card_box.xy + card_box.zw * 0.5);
	float d = rounded_box(p, card_box.zw * 0.5, corner);
	float px = max(fwidth(d), 0.0001);
	float inside = clamp(0.5 - d / px, 0.0, 1.0);
	float halo = max(face.r, max(face.g, face.b));   // a glow drawn on the black margin: its brightness is its alpha
	vec3 color = mix(halo > 0.0001 ? face / halo : vec3(0.0), face, inside);
	float alpha = mix(halo, 1.0, inside);
	float luma = dot(color, vec3(0.299, 0.587, 0.114));
	vec3 grey = clamp((vec3(luma) * 1.3 - 0.5) * 0.85 + 0.5, 0.0, 1.0);
	vec3 ghosted = mix(grey, grey * ghost_tint * 1.15, 0.45);
	color = mix(color, ghosted, ghost * inside);   // opaque: a see-through card shows the page behind it (the detail)
	float g = distance(UV * vec2(1.0, 1.4), glare_pos * vec2(1.0, 1.4));
	float glare = glare_strength * pow(clamp(1.0 - g / glare_radius, 0.0, 1.0), 2.0) * 0.45 * inside;
	color += vec3(glare);
	color = mix(color, flash_color, flash * 0.7 * inside);
	if (rim_width > 0.0) {   // spec item-cards: the rarity outline just outside the card's edge
		float rim = clamp(0.5 - (d - rim_width) / px, 0.0, 1.0) * (1.0 - inside);
		color = mix(color, rim_color * rim_energy, rim);
		alpha = max(alpha, rim);
	}
	ALBEDO = color;
	ALPHA = alpha;
}
