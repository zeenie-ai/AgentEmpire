shader_type sky;
// A warm, soft sky: a clear zenith fading into a glowing peach horizon, a gentle sun halo, and
// stars at night. It also lights the town (ambient and reflections come from it).

uniform vec3 zenith : source_color = vec3(0.50, 0.66, 0.86);
uniform vec3 horizon : source_color = vec3(1.0, 0.85, 0.68);
uniform vec3 ground_color : source_color = vec3(0.47, 0.50, 0.36);
uniform vec3 halo : source_color = vec3(1.0, 0.80, 0.55);
uniform float horizon_blend = 4.0;
uniform float halo_power = 5.0;
uniform float halo_strength = 0.35;
uniform float sun_disk = 2.0;
uniform float stars = 0.0;
uniform float energy = 1.0;

float hash3(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

void sky() {
	vec3 d = EYEDIR;
	vec3 col;
	if (d.y >= 0.0) {
		float t = pow(1.0 - d.y, horizon_blend);
		col = mix(zenith, horizon, t);
	} else {
		col = mix(horizon, ground_color, smoothstep(0.0, 0.25, -d.y));
	}
	if (LIGHT0_ENABLED) {
		float s = max(dot(d, LIGHT0_DIRECTION), 0.0);
		col += halo * (pow(s, halo_power) * halo_strength);
		col += halo * pow(s, 900.0) * sun_disk;
	}
	if (stars > 0.0 && d.y > 0.0 && !AT_CUBEMAP_PASS) {
		vec3 cell = floor(d * 220.0);
		float h = hash3(cell);
		float star = step(0.9965, h) * smoothstep(0.02, 0.35, d.y) * (0.5 + 0.5 * hash3(cell + 7.0));
		col += vec3(0.85, 0.9, 1.0) * star * stars * 2.0;
	}
	COLOR = col * energy;
}
