// Shared by every stylised AgentEmpire material (kit models, ground, grass).
// Global parameters are declared in project.godot [shader_globals] and driven by SkyEnvironment.
global uniform float night_amount;
global uniform vec2 cloud_offset;
global uniform float cloud_strength;
global uniform sampler2D world_noise : filter_linear_mipmap, repeat_enable;

// 1.0 in open sun, down to 1.0 - cloud_strength under a drifting cloud. World units.
float cloud_shadow(vec2 p) {
	if (cloud_strength <= 0.0) {
		return 1.0;
	}
	vec2 q = p + cloud_offset;
	float a = texture(world_noise, q * (1.0 / 96.0)).a;
	float b = texture(world_noise, q * (1.0 / 41.0) + vec2(0.37, 0.61)).a;
	float c = smoothstep(0.52, 0.76, a * 0.7 + b * 0.3);
	return 1.0 - c * cloud_strength;
}

// Wrapped Lambert: a soft terminator (wrap 0 is plain Lambert).
float wrap_diffuse(vec3 n, vec3 l, float wrap) {
	return clamp((dot(n, l) + wrap) / (1.0 + wrap), 0.0, 1.0);
}
