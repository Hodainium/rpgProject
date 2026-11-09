shader_type canvas_item;
render_mode blend_add;

// Vignette flash (spec vfx-framework): the edges of the screen flare in a colour and fade, with an optional wash over
// everything. Use it on a SCREEN effect for a reveal or a big hit.
// @uniform progress   0..1 over the layer (driven)
// @uniform time       seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform color      flash colour
// @uniform intensity  brightness
// @uniform inner      distance from the middle where the vignette starts (0..1.4)
// @uniform outer      distance where it is at full strength
// @uniform power      sharpness of the vignette
// @uniform wash       brightness of the flash over the whole screen
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec4 color : source_color = vec4(1.0);
uniform float intensity = 1.0;
uniform float inner = 0.35;
uniform float outer = 1.2;
uniform float power = 2.0;
uniform float wash = 0.12;

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float edge = pow(smoothstep(inner, outer, length(p)), power);
	float envelope = (1.0 - progress) * (1.0 - progress);
	COLOR = vec4((color.rgb * (edge + wash) * envelope * intensity) * fade, 1.0);
}
