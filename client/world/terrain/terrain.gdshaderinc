// The stylised ground colour, shared by the ground and the grass so tufts match the soil they
// grow from. The masks cover mask_origin .. mask_origin + mask_size (world x, z):
//   static_mask.r: forest floor (tree density)   static_mask.g: paving around the Keep
//   wear_mask.r: worn dirt (buildings, the plaza edge, footpaths)
#include "res://art/shaders/lighting.gdshaderinc"

uniform sampler2D static_mask : filter_linear, repeat_disable;
uniform sampler2D wear_mask : filter_linear, repeat_disable;
uniform vec2 mask_origin = vec2(-32.0, -32.0);
uniform vec2 mask_size = vec2(192.0, 192.0);
uniform vec3 grass_lush : source_color = vec3(0.45, 0.62, 0.28);
uniform vec3 grass_warm : source_color = vec3(0.58, 0.63, 0.33);
uniform vec3 grass_cool : source_color = vec3(0.33, 0.52, 0.30);
uniform vec3 forest_floor : source_color = vec3(0.29, 0.39, 0.21);
uniform vec3 dirt_light : source_color = vec3(0.62, 0.49, 0.33);
uniform vec3 dirt_dark : source_color = vec3(0.45, 0.33, 0.22);
uniform vec3 paving : source_color = vec3(0.68, 0.62, 0.53);

// x: wear, y: forest floor, z: paving.
vec3 terrain_mask_at(vec2 p) {
	vec2 uv = (p - mask_origin) / mask_size;
	vec2 s = texture(static_mask, uv).rg;
	return vec3(texture(wear_mask, uv).r, s.x, s.y);
}

vec3 grass_color(vec2 p) {
	float big = texture(world_noise, p * (1.0 / 110.0)).r;
	float mid = texture(world_noise, p * (1.0 / 33.0) + vec2(0.31, 0.17)).r;
	float small = texture(world_noise, p * (1.0 / 7.5) + vec2(0.53, 0.71)).r;
	vec3 g = mix(grass_cool, grass_lush, smoothstep(0.28, 0.72, big));
	g = mix(g, grass_warm, smoothstep(0.52, 0.82, mid) * 0.42);
	g *= 0.9 + 0.2 * small;
	return g;
}
