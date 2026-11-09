shader_type canvas_item;
render_mode blend_add;

// Foil shimmer (spec vfx-framework): a diagonal rainbow sheen sweeping across a rounded rectangle, the golden-card look.
// Put it on a quad exactly the card's size (no grow).
// @uniform progress   0..1 over the layer (driven)
// @uniform time       seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform rect_size  the quad's size in pixels (driven)
// @uniform margin     pixels between the quad's edge and the card's edge (driven from FxShaderQuadLayer.grow)
// @uniform tint       colour multiplied into the sheen
// @uniform strength   brightness of the sheen
// @uniform speed      sweeps per second
// @uniform band_width width of the bright band (fraction of the card)
// @uniform angle      direction of the sweep, radians
// @uniform rainbow    0 = a plain tinted band, 1 = a full rainbow
// @uniform corner     corner rounding of the card, in pixels
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec2 rect_size = vec2(300.0, 400.0);
uniform float margin = 0.0;
uniform vec4 tint : source_color = vec4(1.0);
uniform float strength = 0.55;
uniform float speed = 0.5;
uniform float band_width = 0.16;
uniform float angle = 0.6;
uniform float rainbow = 1.0;
uniform float corner = 14.0;

float rounded_box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

vec3 hue(float h) {
	vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
	vec3 p = abs(fract(h + k) * 6.0 - 3.0);
	return clamp(p - 1.0, 0.0, 1.0);
}

void fragment() {
	vec2 p = (UV - vec2(0.5)) * rect_size;
	float d = rounded_box(p, rect_size * 0.5 - vec2(margin), corner);
	float mask = 1.0 - smoothstep(-1.0, 1.0, d);
	vec2 dir = vec2(cos(angle), sin(angle));
	float across = dot(UV - vec2(0.5), dir) + 0.5;
	float sweep = fract(time * speed) * 1.6 - 0.3;
	float x = across - sweep;
	float band = exp(-(x * x) / (band_width * band_width));
	vec3 base = mix(vec3(1.0), hue(across * 1.5 + time * 0.2), rainbow);
	COLOR = vec4((base * tint.rgb * band * strength * mask) * fade, 1.0);
}
