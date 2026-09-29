shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;
// Grass tufts and flowers (MultiMesh). Tufts take the ground's colour at their root, darker at
// the base (vertex colour tints them, alpha 0); flower petals (vertex alpha 1) use the
// instance custom colour times the vertex colour. Tufts shrink away on worn dirt and paving,
// and sway in the wind.
#include "res://world/terrain/terrain.gdshaderinc"

global uniform float wind_time;
uniform float sway = 0.07;
// Tufts fade out between these camera distances (too small to see beyond, and cheaper).
uniform float fade_near = 46.0;
uniform float fade_far = 70.0;

varying vec3 v_world;
varying vec3 v_col;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 m = terrain_mask_at(origin.xz);
	float keep = 1.0 - smoothstep(0.3, 0.55, max(m.x, m.z));
	keep *= 1.0 - smoothstep(fade_near, fade_far, distance(CAMERA_POSITION_WORLD, origin));
	float h = UV.y;
	VERTEX *= keep;
	float t = wind_time * 1.6 + origin.x * 0.31 + origin.z * 0.17;
	float gust = 0.6 + 0.4 * sin(wind_time * 0.35 + origin.x * 0.05);
	VERTEX.x += sin(t) * sway * h * h * gust;
	VERTEX.z += cos(t * 0.8) * sway * 0.5 * h * h * gust;
	NORMAL = vec3(0.0, 1.0, 0.0);
	vec3 g = grass_color(origin.xz);
	g = mix(g, forest_floor, clamp(m.y, 0.0, 0.7));
	g *= mix(0.9, 1.2, h) * COLOR.rgb;
	v_col = mix(g, INSTANCE_CUSTOM.rgb * COLOR.rgb, COLOR.a);
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	ALBEDO = v_col;
	ROUGHNESS = 1.0;
	SPECULAR = 0.05;
}

void light() {
	float d = wrap_diffuse(NORMAL, LIGHT, 0.2);
	float sh = LIGHT_IS_DIRECTIONAL ? cloud_shadow(v_world.xz) : 1.0;
	DIFFUSE_LIGHT += d * ATTENUATION * sh * LIGHT_COLOR / PI;
}
