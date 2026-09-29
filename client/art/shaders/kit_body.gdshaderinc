// Body of the kit material (kit.gdshader, kit_double.gdshader): imported GLB models keep their
// atlas texture and get the town's lighting (wrapped diffuse, drifting cloud shadows), a gentle
// saturation lift, an optional rim for readability and warm windows at night.
#include "res://art/shaders/lighting.gdshaderinc"

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable, hint_default_white;
uniform bool use_vertex_color = true;
// Procedural meshes store sRGB vertex colours; imported ones are linear.
uniform bool vertex_color_srgb = false;
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform float saturation = 1.06;
uniform float wrap = 0.18;
uniform float rim = 0.0;
// Atlas cells (u0, v0, u1, v1) that light up at night (windows). u0 < 0 disables.
uniform vec4 glow_cell_a = vec4(-1.0);
uniform vec4 glow_cell_b = vec4(-1.0);
uniform vec3 glow_color : source_color = vec3(1.0, 0.69, 0.29);
uniform float glow_energy = 2.4;
// 0..1 fade used by construction reveals and dimming.
uniform float emission_boost = 0.0;

varying vec3 v_world;

float in_cell(vec2 uv, vec4 cell) {
	if (cell.x < 0.0) {
		return 0.0;
	}
	vec2 a = step(cell.xy, uv);
	vec2 b = step(uv, cell.zw);
	return a.x * a.y * b.x * b.y;
}

vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 c = albedo.rgb * texture(albedo_tex, UV).rgb;
	if (use_vertex_color) {
		c *= vertex_color_srgb ? srgb_to_linear(COLOR.rgb) : COLOR.rgb;
	}
	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = max(mix(vec3(l), c, saturation), vec3(0.0));
	ALBEDO = c;
	ROUGHNESS = roughness;
	SPECULAR = 0.25;
	vec3 e = vec3(0.0);
	if (rim > 0.0) {
		float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
		e += c * f * rim * (1.0 - 0.6 * night_amount);
	}
	if (night_amount > 0.001) {
		float g = max(in_cell(UV, glow_cell_a), in_cell(UV, glow_cell_b));
		e += glow_color * g * glow_energy * smoothstep(0.15, 0.8, night_amount);
	}
	e += c * emission_boost;
	EMISSION = e;
}

void light() {
	float d = wrap_diffuse(NORMAL, LIGHT, wrap);
	float sh = LIGHT_IS_DIRECTIONAL ? cloud_shadow(v_world.xz) : 1.0;
	DIFFUSE_LIGHT += d * ATTENUATION * sh * LIGHT_COLOR / PI;
	vec3 h = normalize(VIEW + LIGHT);
	float s = pow(clamp(dot(NORMAL, h), 0.0, 1.0), mix(64.0, 6.0, ROUGHNESS));
	SPECULAR_LIGHT += s * (1.0 - ROUGHNESS) * 0.35 * ATTENUATION * sh * LIGHT_COLOR / PI;
}
