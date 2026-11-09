shader_type canvas_item;
render_mode blend_add;

// Outline (spec vfx-framework): a bright pulsing line around a rounded rectangle, for hover and selection. Sizes are in
// pixels; the quad is the card plus `margin` pixels on every side (FxShaderQuadLayer.grow).
// @uniform progress      0..1 over the layer (driven)
// @uniform time          seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform rect_size     the quad's size in pixels (driven)
// @uniform margin        pixels between the quad's edge and the card's edge (driven from FxShaderQuadLayer.grow)
// @uniform color         the line colour
// @uniform intensity     brightness
// @uniform thickness     line width in pixels
// @uniform softness      how soft the line's edges are, in pixels
// @uniform corner        corner rounding of the card, in pixels
// @uniform pulse_speed   pulses per second
// @uniform pulse_amount  how much the brightness swings (0 = steady)
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec2 rect_size = vec2(300.0, 400.0);
uniform float margin = 8.0;
uniform vec4 color : source_color = vec4(1.0, 0.95, 0.7, 1.0);
uniform float intensity = 1.0;
uniform float thickness = 2.5;
uniform float softness = 2.0;
uniform float corner = 14.0;
uniform float pulse_speed = 1.2;
uniform float pulse_amount = 0.3;

float rounded_box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 p = (UV - vec2(0.5)) * rect_size;
	float d = rounded_box(p, rect_size * 0.5 - vec2(margin), corner);
	float line = 1.0 - smoothstep(thickness, thickness + softness, abs(d));
	float pulse = 1.0 + pulse_amount * sin(time * pulse_speed * 6.28318);
	COLOR = vec4((color.rgb * line * intensity * pulse) * fade, 1.0);
}
