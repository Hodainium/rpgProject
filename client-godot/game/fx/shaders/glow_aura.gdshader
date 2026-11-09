shader_type canvas_item;
render_mode blend_add;

// Rarity glow (spec vfx-framework): a soft pulsing aura hugging a rounded rectangle, for cards. The quad is the card's
// rectangle plus `margin` pixels on every side (FxShaderQuadLayer.grow); sizes are in pixels.
// @uniform progress     0..1 over the layer (driven by FxShaderQuadLayer)
// @uniform time         seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform rect_size    the quad's size in pixels (driven)
// @uniform margin       pixels between the quad's edge and the card's edge (driven from FxShaderQuadLayer.grow)
// @uniform color        the glow colour
// @uniform intensity    brightness, 1 = normal, above 1 blooms
// @uniform corner       corner rounding of the card, in pixels
// @uniform falloff      how fast the glow dies away outside the card edge, per pixel
// @uniform inner_glow   strength of the faint glow inside the card edge
// @uniform pulse_speed  pulses per second
// @uniform pulse_amount how much the brightness swings (0 = steady)
// @uniform fade_in      fraction of the layer spent fading in (0 = none; use 0 for loops)
// @uniform fade_out     fraction of the layer spent fading out (0 = none)
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec2 rect_size = vec2(300.0, 400.0);
uniform float margin = 40.0;
uniform vec4 color : source_color = vec4(1.0, 0.8, 0.3, 1.0);
uniform float intensity = 1.0;
uniform float corner = 14.0;
uniform float falloff = 0.1;
uniform float inner_glow = 0.3;
uniform float pulse_speed = 1.5;
uniform float pulse_amount = 0.25;
uniform float fade_in = 0.0;
uniform float fade_out = 0.0;

float rounded_box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 p = (UV - vec2(0.5)) * rect_size;
	float d = rounded_box(p, rect_size * 0.5 - vec2(margin), corner);
	float outside = d >= 0.0 ? exp(-d * falloff) : 0.0;
	float inside = d < 0.0 ? inner_glow * smoothstep(-margin * 0.7, 0.0, d) : 0.0;
	float pulse = 1.0 + pulse_amount * sin(time * pulse_speed * 6.28318);
	float a = (outside + inside) * intensity * pulse;
	if (fade_in > 0.0) {
		a *= smoothstep(0.0, fade_in, progress);
	}
	if (fade_out > 0.0) {
		a *= 1.0 - smoothstep(1.0 - fade_out, 1.0, progress);
	}
	COLOR = vec4((color.rgb * a) * fade, 1.0);
}
