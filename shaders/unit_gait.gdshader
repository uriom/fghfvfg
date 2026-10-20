shader_type canvas_item;

// Subtle alternating lower-body stride for the painted full-body mech sprites.
// The displacement is deliberately small: it animates the legs without
// tearing the detailed torso illustration apart at the game's 40px render size.
uniform float gait_speed = 7.0;
uniform float gait_amount = 0.035;
uniform float gait_phase = 0.0;
uniform float leg_start = 0.57;

void fragment() {
	vec2 uv = UV;
	float lower_body = smoothstep(leg_start, leg_start + 0.16, UV.y);
	float left_half = 1.0 - smoothstep(0.43, 0.57, UV.x);
	float side = mix(1.0, -1.0, left_half);
	float stride = sin(TIME * gait_speed + gait_phase) * side;
	uv.x += stride * gait_amount * lower_body;
	COLOR = texture(TEXTURE, uv) * COLOR;
}
