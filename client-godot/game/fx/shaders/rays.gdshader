shader_type canvas_item;
render_mode blend_add;

// Rays (spec vfx-framework): god rays fanning out of the middle of the quad, with a bright core. Legendary reveals.
// @uniform progress   0..1 over the layer (driven)
// @uniform time       seconds since the layer started (driven)
// @uniform fade        1 = full strength; driven toward 0 while the effect is stopped (a fade out)
// @uniform color      ray colour
// @uniform intensity  brightness
// @uniform ray_count  number of rays
// @uniform spin       turns per second
// @uniform sharpness  how thin the rays are
// @uniform falloff    how fast the rays die away from the middle
// @uniform core       size of the bright core
// @uniform fade_out   fraction of the layer spent fading out
uniform float progress = 0.0;
uniform float time = 0.0;
uniform float fade = 1.0;
uniform vec4 color : source_color = vec4(1.0, 0.8, 0.3, 1.0);
uniform float intensity = 1.0;
uniform float ray_count = 14.0;
uniform float spin = 0.08;
uniform float sharpness = 3.0;
uniform float falloff = 1.8;
uniform float core = 0.12;
uniform float fade_out = 0.4;

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p);
	float angle = atan(p.y, p.x) + time * spin * 6.28318;
	float rays = pow(abs(sin(angle * ray_count * 0.5)), sharpness);
	float radial = exp(-r * falloff);
	float core_glow = exp(-(r * r) / (core * core));
	float cap = 1.0 - smoothstep(0.85, 1.0, r);
	float envelope = smoothstep(0.0, 0.08, progress) * (fade_out > 0.0 ? 1.0 - smoothstep(1.0 - fade_out, 1.0, progress) : 1.0);
	float a = (rays * radial + core_glow) * cap * intensity * envelope;
	COLOR = vec4((color.rgb * a) * fade, 1.0);
}
