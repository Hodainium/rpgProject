shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// Spec item-cards 2.2: the Legendary tier's rising ribbons (Risk of Rain 2's red items): thin luminous bands spiralling up an
// open cylinder around a floor pickup, brightest low, fading out at the top and bottom. On an FxMeshLayer's cylinder (UV.x around,
// UV.y down the side); the layer binds colour and strength.
// @uniform color      ribbon colour (the item's rarity)
// @uniform strength   0..1, the ribbons' brightness (0 hides them: lower tiers)
// @uniform intensity  brightness at full strength
// @uniform ribbons    how many ribbons go round
// @uniform twist      turns each ribbon makes from the bottom to the top
// @uniform speed      how fast they climb (cycles a second)
// @uniform thickness  a ribbon's width, as a fraction of the gap between two
uniform vec4 color : source_color = vec4(1.0, 0.75, 0.3, 1.0);
uniform float strength = 1.0;
uniform float intensity = 2.0;
uniform float ribbons = 3.0;
uniform float twist = 0.8;
uniform float speed = 0.35;
uniform float thickness = 0.08;

void fragment() {
	float height = 1.0 - UV.y;   // 0 at the bottom, 1 at the top
	float band = fract(UV.x * ribbons + height * twist * ribbons - TIME * speed);
	float line = 1.0 - smoothstep(thickness * 0.25, thickness * 0.5, abs(band - 0.5));
	float envelope = smoothstep(0.0, 0.15, height) * (1.0 - smoothstep(0.45, 1.0, height));
	float flicker = 0.8 + 0.2 * sin(TIME * 3.0 + UV.x * 12.0);
	ALBEDO = color.rgb * intensity;
	ALPHA = clamp(line * envelope * flicker * strength, 0.0, 1.0);
}
