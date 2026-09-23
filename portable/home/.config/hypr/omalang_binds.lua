-- Managed by Omalang — do not edit. Regenerated on shortcut/layout change.
-- Layout switching via Hyprland binds (BOTH press orders) instead of XKB grp:.
-- XKB grp:lalt_lshift_toggle / grp:ralt_rshift_toggle only fire Shift-first
-- (<LALT> L1 is NoSymbol, so Alt-first sets no Alt modifier and Shift resolves
-- to Shift_L instead of ISO_Next_Group). Each bind below is press-triggered
-- (no release bind), so one chord = exactly one switch, no double-toggle.
-- NOTE: Hyprland mods are side-agnostic, so "Left Alt + Shift" also fires for
-- Right-Alt-held + Left-Shift-pressed. Strict side matching is not possible
-- with mod+key binds; both-orders working was chosen over strict sides.
-- non_consuming: the full chord also reaches the app, so a lone-Alt
-- press+release never looks like an app-menu hotkey (no focus steal).

-- Big layout preview needs no window rule: it is a layer-shell
-- overlay (omarchy-omalang-preview) so it always floats centered.

local switcher = '/home/shadowone/.config/hypr/switch-keyboard-layout.sh'

o.bind("ALT + SHIFT_L", "Switch keyboard layout (grp:lalt_lshift_toggle)", switcher, { non_consuming = true })
o.bind("SHIFT + ALT_L", "Switch keyboard layout (grp:lalt_lshift_toggle)", switcher, { non_consuming = true })
