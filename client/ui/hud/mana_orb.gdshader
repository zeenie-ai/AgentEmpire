shader_type canvas_item;
// The Mana orb: a glass globe of glowing liquid inside a gold rim. The surface sways in two
// waves, bubbles rise, and a highlight sits on the glass. `activity` 0 stills it (offline).

uniform float fill : hint_range(0.0, 1.0) = 0.55;
uniform float activity : hint_range(0.0, 1.0) = 1.0;
uniform vec4 liquid_top : source_color = vec4(0.66, 0.94, 0.82, 1.0);
uniform vec4 liquid_deep : source_color = vec4(0.10, 0.42, 0.50, 1.0);
uniform vec4 glass : source_color = vec4(0.05, 0.07, 0.19, 1.0);
uniform vec4 rim : source_color = vec4(0.88, 0.71, 0.38, 1.0);
uniform float glow = 0.6;

float hash(float n) {
	return fract(sin(n) * 43758.5453);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float aa = max(fwidth(r), 0.002);
	float inner_r = 0.8;
	float inside = 1.0 - smoothstep(inner_r - aa, inner_r + aa, r);
	float outer = 1.0 - smoothstep(0.97 - aa, 0.97 + aa, r);
	vec2 q = p / inner_r;
	float t = TIME * mix(0.2, 1.0, activity);
	float level = mix(0.92, -0.92, fill);
	float wave = (sin(q.x * 4.5 + t * 2.1) * 0.05 + sin(q.x * 9.0 - t * 3.3) * 0.022) * mix(0.25, 1.0, activity);
	float surface = level + wave;
	float liquid = smoothstep(surface - 0.03, surface + 0.03, q.y);
	float depth = clamp((q.y - surface) / 1.6, 0.0, 1.0);
	vec3 lq = mix(liquid_top.rgb, liquid_deep.rgb, depth);
	// Light swirls in the liquid.
	lq += liquid_top.rgb * 0.18 * sin(q.x * 6.0 + q.y * 4.0 + t * 1.3) * (1.0 - depth);
	// Bubbles rising from the bottom.
	for (int i = 0; i < 6; i++) {
		float fi = float(i);
		float bx = hash(fi * 7.13) * 1.3 - 0.65;
		float speed = 0.18 + hash(fi * 3.31) * 0.25;
		float by = 1.0 - fract(t * speed + hash(fi * 1.7)) * 2.0;
		float d = length(q - vec2(bx + sin(t * 1.7 + fi) * 0.05, by));
		float b = (1.0 - smoothstep(0.035, 0.07, d)) * step(surface + 0.05, by);
		lq += vec3(0.45) * b * activity;
	}
	vec3 col = mix(glass.rgb, lq, liquid);
	// A bright meniscus along the surface.
	col += liquid_top.rgb * (1.0 - smoothstep(0.0, 0.05, abs(q.y - surface))) * 0.6 * liquid_top.a;
	// Glass: darker toward the edge, a crescent highlight top-left, a small glint.
	col *= mix(1.0, 0.55, smoothstep(0.55, 1.0, length(q)));
	float hl = 1.0 - smoothstep(0.0, 0.32, length((q - vec2(-0.32, -0.46)) * vec2(1.0, 1.6)));
	col += vec3(0.5) * hl * 0.55;
	col += vec3(1.0) * (1.0 - smoothstep(0.0, 0.07, length(q - vec2(0.42, -0.5)))) * 0.5;
	// Gold rim with a bevel: lit from the top, darker below.
	float band = outer - inside;
	vec3 rim_col = rim.rgb * (0.7 + 0.55 * (0.5 - 0.5 * p.y));
	rim_col *= 0.8 + 0.4 * smoothstep(0.84, 0.9, r) * (1.0 - smoothstep(0.92, 0.97, r));
	vec3 c = mix(col, rim_col, band);
	// A soft glow outside the rim.
	float halo = (1.0 - smoothstep(0.97, 1.0, r)) * (1.0 - outer) * glow;
	COLOR = vec4(c + liquid_top.rgb * halo * 0.4, max(outer, halo * 0.5));
}
