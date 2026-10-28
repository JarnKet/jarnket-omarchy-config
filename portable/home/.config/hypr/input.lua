-- Keep only your personal input overrides here. Uncommented settings below
-- replace Omarchy's defaults.

-- Keyboard layout and options.
-- See https://wiki.hypr.land/Configuring/Basics/Variables/#input
hl.config({
  input = {
    -- Use multiple keyboard layouts; Alt+Shift switches them (omalang_binds.lua).
    -- No grp:alts_toggle: in Lao, Right Alt is AltGr (AltGr + 1..0 = ໑..໐, as on Windows).
    -- "lao" = Lao (Windows) layout from ~/.config/xkb/symbols/lao (two-character keys via ~/.config/xkb/lao.XCompose).
    kb_layout = "us,lao",
    kb_options = "shift:both_capslock_cancel",

    -- Use a specific keyboard variant if needed (e.g. intl for international keyboards).
    -- kb_variant = "intl",

    -- Change speed of keyboard repeat.
    repeat_rate = 40,
    repeat_delay = 250,
    -- Start with numlock on by default.
    numlock_by_default = true,

    -- Increase sensitivity for mouse/trackpad (default: 0).
    sensitivity = 0.35,

    -- Turn off mouse acceleration (default: adaptive).
    accel_profile = "adaptive",

    touchpad = {
      -- Use natural (inverse) scrolling.
      natural_scroll = true,

      -- Use two-finger clicks for right-click instead of lower-right corner.
      clickfinger_behavior = true,

      -- Control the speed of your scrolling.
      scroll_factor = 0.4,

      -- Enable the touchpad while typing.
      disable_while_typing = false,

      -- Left-click-and-drag with FOUR fingers (2). With 3 fingers (1), libinput
      -- turns any 3-finger swipe that doesn't move 5 mm in its first 80 ms into
      -- a drag, which cancels slow workspace swipes halfway.
      drag_3fg = 2,
    },
  },
})

--App-specific touchpad scroll speeds.
o.window("(Alacritty|kitty|foot|org.omarchy.claude-history)", { scroll_touchpad = 1.5 })
o.window("com.mitchellh.ghostty", { scroll_touchpad = 0.2 })
-- Brave (and its web apps), VS Code, Obsidian: content follows the fingers
-- further and the fling glides longer (Chromium's glide scales with this).
o.window("(brave-.*|code|Code|obsidian)", { scroll_touchpad = 0.6 })

--Enable touchpad gestures for changing workspaces.
--See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Gestures/
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.config({
  gestures = {
    -- Commit to the next workspace after 30% of the swipe (default 50%),
    -- closer to macOS/GNOME. Quick flicks still switch regardless.
    workspace_swipe_cancel_ratio = 0.3,
  },
})
hl.gesture({ fingers = 3, direction = "up", action = function()
  os.execute("omarchy-shell expose open &")
end })
hl.gesture({ fingers = 3, direction = "down", action = function()
  os.execute("omarchy-shell expose close &")
end })

--Enable touchpad gestures for moving focus (helpful on scrolling layout).
--hl.gesture({ fingers = 3, direction = "left", action = function() hl.dispatch(hl.dsp.focus({ direction = "l" })) end })
--hl.gesture({ fingers = 3, direction = "right", action = function() hl.dispatch(hl.dsp.focus({ direction = "r" })) end })

-- [[ OMARCHY_MOUSE_SETTINGS_START ]]
hl.config({
  input = {
    sensitivity = 0.00,
    accel_profile = "adaptive",
    follow_mouse = 1,
    natural_scroll = false,
    touchpad = {
      natural_scroll = false,
    },
    left_handed = false,
    scroll_factor = 1.00,
    mouse_refocus = true,
  },
})
-- [[ OMARCHY_MOUSE_SETTINGS_END ]]

-- Pointer Feel preferences (managed by the bar panel).
dofile(os.getenv("HOME") .. "/.config/hypr/pointer-feel.lua")

-- Windows scales Enhance pointer precision by ONE system DPI on every monitor.
-- My Windows runs at 150% (registry AppliedDPI = 144), so pin the Win engine
-- to that; without it the MSI (scale 1) felt 1.5x slower than Windows.
-- system_dpi is a local patch in the vendored windows-pointer-linux plugin.cpp.
if hl.plugin.windows_pointer_linux then
  hl.config({ plugin = { windows_pointer_linux = { system_dpi = 144 } } })
end

-- Per-device split: mouse and touchpad get their own settings.
-- Device blocks override the shared input values above (and anything
-- Pointer Feel / OmaSettings write), so edit these to tune each device.
-- Device names come from `hyprctl devices`.

-- Built-in touchpad (pinned to the feel it had before the split).
hl.device({
  name = "elan0676:00-04f3:3195-touchpad",
  sensitivity = 0.0,
  accel_profile = "adaptive",
  natural_scroll = true,
  scroll_factor = 0.4,
  clickfinger_behavior = true,
  disable_while_typing = false,
  drag_3fg = 2, -- 4-finger drag, keeps 3 fingers free for workspace swipes
})

-- Bluetooth mouse. Pointer motion comes from Pointer Feel's Win engine;
-- sensitivity/accel_profile only apply if that engine isn't loaded.
hl.device({
  name = "bt4.0-mouse",
  sensitivity = 0.0,
  accel_profile = "adaptive",
  natural_scroll = false,
  scroll_factor = 1.0,
  left_handed = false,
})
