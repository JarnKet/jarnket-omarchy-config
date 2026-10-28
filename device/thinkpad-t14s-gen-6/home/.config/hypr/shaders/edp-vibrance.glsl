#version 300 es
// Vibrance for the ThinkPad's 45% NTSC panel (eDP-1) only.
// Boosts dull colors more than already-saturated ones, so skin tones and
// strong reds don't blow out. Other monitors pass through untouched.
precision highp float;

in vec2 v_texcoord;
uniform sampler2D tex;
uniform int wl_output;   // Hyprland monitor id; eDP-1 is 0

layout(location = 0) out vec4 fragColor;

const int   PANEL_ID  = 0;
const float VIBRANCE  = 0.25;   // 0.0 = off, ~0.15 subtle, ~0.35 punchy

void main() {
    vec4 c = texture(tex, v_texcoord);
    if (wl_output != PANEL_ID) {
        fragColor = c;
        return;
    }
    float luma = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
    float sat  = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
    vec3 rgb   = mix(vec3(luma), c.rgb, 1.0 + VIBRANCE * (1.0 - sat));
    fragColor  = vec4(clamp(rgb, 0.0, 1.0), c.a);
}
