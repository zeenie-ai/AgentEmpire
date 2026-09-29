shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;
// The ground: noise-patched grass with fine grain, darker forest floor under trees, worn dirt
// around buildings and along footpaths, cobbled paving around the Keep, and cloud shadows.
#include "res://world/terrain/terrain.gdshaderinc"

uniform float grain = 0.08;

varying vec3 v_world;

vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

// Cobbles: x is the distance to the nearest stone edge, y a per-stone random value.
vec2 cobbles(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float d1 = 8.0;
	float d2 = 8.0;
	vec2 id = vec2(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = hash2(i + g) * 0.8 + 0.1;
			float d = length(g + o - f);
			if (d < d1) {
				d2 = d1;
				d1 = d;
				id = i + g;
			} else if (d < d2) {
				d2 = d;
			}
		}
	}
	return vec2(d2 - d1, hash2(id).x);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = v_world.xz;
	vec3 m = terrain_mask_at(p);
	float fine = texture(world_noise, p * (1.0 / 1.7)).b;
	float edge = texture(world_noise, p * (1.0 / 4.0) + vec2(0.13, 0.29)).b;
	vec3 g = grass_color(p);
	g *= 1.0 - grain + 2.0 * grain * fine;
	float forest = m.y * (0.75 + 0.5 * edge);
	g = mix(g, forest_floor * (0.9 + 0.2 * fine), clamp(forest, 0.0, 0.85));
	float wear = smoothstep(0.34, 0.66, m.x + (edge - 0.5) * 0.5);
	float dn = texture(world_noise, p * (1.0 / 2.6) + vec2(0.7, 0.2)).r;
	vec3 dirt = mix(dirt_dark, dirt_light, smoothstep(0.25, 0.75, dn)) * (0.93 + 0.14 * fine);
	vec3 col = mix(g, dirt, wear);
	float pave = smoothstep(0.42, 0.58, m.z + (edge - 0.5) * 0.3);
	if (pave > 0.001) {
		vec2 cb = cobbles(p * 3.4);
		float body = smoothstep(0.02, 0.2, cb.x);
		vec3 stone = paving * (0.88 + 0.18 * cb.y) * (0.95 + 0.1 * fine) * (0.93 + 0.07 * body);
		vec3 joint = mix(paving * 0.66, dirt_dark, 0.25);
		stone = mix(joint, stone, smoothstep(0.012, 0.06, cb.x));
		col = mix(col, stone, pave);
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
	SPECULAR = 0.1;
}

void light() {
	float d = wrap_diffuse(NORMAL, LIGHT, 0.1);
	float sh = LIGHT_IS_DIRECTIONAL ? cloud_shadow(v_world.xz) : 1.0;
	DIFFUSE_LIGHT += d * ATTENUATION * sh * LIGHT_COLOR / PI;
}
